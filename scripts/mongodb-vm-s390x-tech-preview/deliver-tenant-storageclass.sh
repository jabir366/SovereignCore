#!/usr/bin/env bash
# deliver-tenant-storageclass.sh
#
# Run against the HUB. Delivers a tenant's StorageClass (and its two CSI secrets) to ONE extra
# managed cluster, together with the tenant-isolation admission rule, using ACM policies:
#
#   1. Placement + PlacementBinding for the tenant's existing "storage-class-<tenant>" policy
#      (secret values are hub templates, so no keys are copied).
#   2. The shared policy "tenant-storageclass-isolation" (ValidatingAdmissionPolicy + binding),
#      created once on the hub and placed on the same cluster. The rule is tenant-agnostic:
#      in a namespace labelled sovereign.cloud.ibm.com/account-id=<tenant>, a PVC naming a
#      ceph-rbd-* class must name exactly ceph-rbd-<tenant>. Unlabelled namespaces and other
#      classes are not restricted.
#
# Storage architecture on the target spoke cluster (e.g. standard4):
#   Both pools live on the SAME Ceph cluster (sc-x86).
#   Standard4 already has ONE connection to it:
#     - StorageCluster: ocs-ext-sc-platform (external, Ready)
#     - CephCluster:    ocs-ext-sc-platform-cephcluster (Connected, HEALTH_OK)
#     - CSI Driver:     rbd.csi.ceph.com Driver
#
#   A storage class needs only three things to use that connection:
#     1. pool name           -> in the StorageClass (ceph-rbd-<tenant>)
#     2. a Ceph user + key   -> in the 2 CSI secrets (rook-csi-rbd-node-<id>, rook-csi-rbd-provisioner-<id>)
#     3. clusterID           -> "openshift-storage" = the existing connection
#
#   So delivering to tenant = 1 StorageClass + 2 Secrets + 1 ValidatingAdmissionPolicy. Nothing else.
#
# Usage:
#   deliver-tenant-storageclass.sh --tenant <account> --cluster <managedcluster> [OPTIONS]
#
# Options:
#   --tenant, --tenant-id <account>   Account/Tenant ID (StorageDeliveryRequest .spec.toAccount),
#                                     e.g. platform or bd301ac3-f0f6-4c08-9a0c-ba76d785604d
#   --tenant-name <name>              Optional tenant display/short name
#   --cluster <managedcluster>        Target ManagedCluster name, e.g. claas-api-ocpz-cp4d4-std-tt-testing
#   --namespace, -n <ns>              ACM policy namespace on Hub (default: sov-core-storage)
#   --context <ctx>                   Kubeconfig context to use for oc commands
#   --no-isolation                    Deliver the storage class only, without the admission policy rule
#   --wait                            Wait/poll until policies become Compliant on target cluster
#   --timeout <sec>                   Timeout in seconds when --wait is specified (default: 300)
#   --dry-run                         Preview generated manifests without applying
#   --remove                          Delete the extra Placement/PlacementBindings for this cluster.
#                                     The isolation placement is removed only when no other extra
#                                     class remains on that cluster.
#   -h, --help                        Show this help and exit
#
# Examples:
#   # Deliver storage class for tenant to platform cluster
#   ./deliver-tenant-storageclass.sh \
#       --tenant bd301ac3-f0f6-4c08-9a0c-ba76d785604d \
#       --cluster claas-api-ocpz-cp4d4-std-tt-testing \
#       --wait
#
#   # Remove extra placement for tenant from cluster
#   ./deliver-tenant-storageclass.sh \
#       --tenant bd301ac3-f0f6-4c08-9a0c-ba76d785604d \
#       --cluster claas-api-ocpz-cp4d4-std-tt-testing \
#       --remove
set -euo pipefail

NS="sov-core-storage"
ISO_POLICY="tenant-storageclass-isolation"
TENANT=""
TENANT_NAME=""
CLUSTER=""
CTX=""
DRY=0
WAIT=0
REMOVE=0
ISOLATION=1
TIMEOUT=300

usage() {
  sed -n '/^# Usage:/,/^# Examples:/p' "$0" | sed 's/^# \{0,2\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tenant|--tenant-id) TENANT="$2"; shift 2 ;;
    --tenant-name)        TENANT_NAME="$2"; shift 2 ;;
    --cluster)            CLUSTER="$2"; shift 2 ;;
    --namespace|-n)       NS="$2"; shift 2 ;;
    --context)            CTX="$2"; shift 2 ;;
    --no-isolation)       ISOLATION=0; shift ;;
    --dry-run)            DRY=1; shift ;;
    --wait)               WAIT=1; shift ;;
    --timeout)            TIMEOUT="$2"; shift 2 ;;
    --remove)             REMOVE=1; shift ;;
    -h|--help)            usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$TENANT" ] && [ -n "$CLUSTER" ] || { echo "ERROR: --tenant and --cluster are required" >&2; exit 2; }

oc_() {
  if [ -n "$CTX" ]; then
    oc --context "$CTX" "$@"
  else
    oc "$@"
  fi
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# [1] Look up the tenant's StorageDeliveryRequest on the hub
# ---------------------------------------------------------------------------
echo "==> [1/4] Looking up StorageDeliveryRequest for tenant '${TENANT}' in '${NS}'..."

SDR_JSON=$(oc_ -n "$NS" get storagedeliveryrequest -o json 2>/dev/null || true)
POLICY=""

if [ -n "$SDR_JSON" ]; then
  POLICY=$(printf '%s' "$SDR_JSON" | python3 -c '
import sys, json
t = sys.argv[1]
for i in json.load(sys.stdin).get("items", []):
    if i.get("spec", {}).get("toAccount") == t or i.get("metadata", {}).get("name") == t:
        for l in i.get("status", {}).get("policyLevels", []):
            if l.get("level") == "StorageClass":
                print(l.get("policyName", ""))
                sys.exit(0)
' "$TENANT")
fi

# Fallback: if not found via SDR status, check if policy storage-class-<tenant> exists directly
if [ -z "$POLICY" ]; then
  if oc_ -n "$NS" get policy "storage-class-${TENANT}" >/dev/null 2>&1; then
    POLICY="storage-class-${TENANT}"
  fi
fi

[ -n "$POLICY" ] || die "no StorageDeliveryRequest with a StorageClass policy found for tenant '$TENANT' in namespace '$NS'"
oc_ -n "$NS" get policy "$POLICY" >/dev/null 2>&1 || die "policy '$POLICY' not found in namespace '$NS'"

echo "Found StorageClass policy: ${POLICY}"

# ---------------------------------------------------------------------------
# [2] Check the target ManagedCluster
# ---------------------------------------------------------------------------
echo "==> [2/4] Checking target ManagedCluster '${CLUSTER}'..."
oc_ get managedcluster "$CLUSTER" >/dev/null 2>&1 || die "ManagedCluster '$CLUSTER' not found"

SET=$(oc_ get managedcluster "$CLUSTER" -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}' 2>/dev/null || true)
[ -n "$SET" ] || die "ManagedCluster '$CLUSTER' has no cluster.open-cluster-management.io/clusterset label"

oc_ -n "$NS" get managedclustersetbinding "$SET" >/dev/null 2>&1 \
  || die "ManagedClusterSet '$SET' is not bound in '$NS' (cannot place policies there)"

# Placement names must stay short: the placement controller labels "<name>-decision-N" and
# label values are limited to 63 characters. Use a hash of the cluster name for a fixed length.
CH=$(printf '%s' "$CLUSTER" | shasum | cut -c1-10)
PL="${POLICY}-on-${CH}"
ISO_PL="tsc-isolation-on-${CH}"

# ---------------------------------------------------------------------------
# Removal path
# ---------------------------------------------------------------------------
if [ "$REMOVE" = 1 ]; then
  echo "Removing extra delivery of $POLICY to $CLUSTER..."
  if [ "$DRY" = 1 ]; then
    echo "[DRY-RUN] Would delete placementbinding $PL and placement $PL in $NS"
  else
    oc_ -n "$NS" delete placementbinding "$PL" --ignore-not-found
    oc_ -n "$NS" delete placement "$PL" --ignore-not-found
  fi

  LEFT=$(oc_ -n "$NS" get placement -l sovereign.cloud.ibm.com/extra-delivery-kind=storageclass -o json 2>/dev/null \
    | python3 -c '
import sys, json
c = sys.argv[1]
try:
    items = json.load(sys.stdin).get("items", [])
    print(sum(1 for i in items
              if i.get("metadata", {}).get("annotations", {}).get("sovereign.cloud.ibm.com/target-cluster") == c))
except Exception:
    print(0)
' "$CLUSTER")

  if [ "$LEFT" -le 1 ]; then
    echo "No other extra class on $CLUSTER; removing the isolation placement ($ISO_PL)..."
    if [ "$DRY" = 1 ]; then
      echo "[DRY-RUN] Would delete placementbinding $ISO_PL and placement $ISO_PL in $NS"
    else
      oc_ -n "$NS" delete placementbinding "$ISO_PL" --ignore-not-found
      oc_ -n "$NS" delete placement "$ISO_PL" --ignore-not-found
    fi
  else
    echo "$((LEFT - 1)) other extra class(es) still on $CLUSTER; keeping isolation placement ($ISO_PL)."
  fi
  echo "Done. Objects already delivered stay on $CLUSTER until deleted there."
  exit 0
fi

# ---------------------------------------------------------------------------
# Check ODF client side compliance
# ---------------------------------------------------------------------------
compliance() { # $1=policy $2=cluster
  oc_ -n "$NS" get policy "$1" -o json 2>/dev/null | python3 -c '
import sys, json
c = sys.argv[1]
try:
    for s in json.load(sys.stdin).get("status", {}).get("status", []):
        if s.get("clustername") == c:
            print(s.get("compliant", ""))
            break
except Exception:
    pass
' "$2"
}

ODF=$(compliance install-odf-operator "$CLUSTER")
if [ -z "$ODF" ]; then
  ODF=$(compliance install-odf-client "$CLUSTER")
fi

if [ "$ODF" != "Compliant" ]; then
  echo "WARNING: ODF operator policy is '${ODF:-not placed}' on $CLUSTER; target cluster requires rbd.csi.ceph.com Driver" >&2
else
  echo "ODF client operator is Compliant on $CLUSTER"
fi

# ---------------------------------------------------------------------------
# [3] & [4] Manifest Generation
# ---------------------------------------------------------------------------
echo "==> [3/4] Preparing Placement and PlacementBinding manifests..."

placement_yaml() { # $1=name $2=policy $3=kind
cat <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: $1
  namespace: ${NS}
  labels:
    sovereign.cloud.ibm.com/extra-delivery: "true"
    sovereign.cloud.ibm.com/extra-delivery-kind: "$3"
  annotations:
    sovereign.cloud.ibm.com/tenant: "${TENANT}"
    sovereign.cloud.ibm.com/target-cluster: "${CLUSTER}"
spec:
  clusterSets: ["${SET}"]
  predicates:
  - requiredClusterSelector:
      labelSelector:
        matchLabels:
          name: "${CLUSTER}"
  tolerations:
  - {key: cluster.open-cluster-management.io/unreachable, operator: Exists}
  - {key: cluster.open-cluster-management.io/unavailable, operator: Exists}
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: $1
  namespace: ${NS}
  labels:
    sovereign.cloud.ibm.com/extra-delivery: "true"
    sovereign.cloud.ibm.com/extra-delivery-kind: "$3"
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: $1
subjects:
- apiGroup: policy.open-cluster-management.io
  kind: Policy
  name: $2
EOF
}

# Shared, tenant-agnostic isolation policy (created once on the hub).
isolation_policy_yaml() {
cat <<'EOF'
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: tenant-storageclass-isolation
  namespace: sov-core-storage
spec:
  remediationAction: enforce
  disabled: false
  policy-templates:
  - objectDefinition:
      apiVersion: policy.open-cluster-management.io/v1
      kind: ConfigurationPolicy
      metadata:
        name: tenant-storageclass-isolation
      spec:
        remediationAction: enforce
        severity: high
        object-templates:
        - complianceType: musthave
          objectDefinition:
            apiVersion: admissionregistration.k8s.io/v1
            kind: ValidatingAdmissionPolicy
            metadata:
              name: tenant-storageclass-isolation
            spec:
              failurePolicy: Fail
              matchConstraints:
                resourceRules:
                - apiGroups: [""]
                  apiVersions: ["v1"]
                  operations: ["CREATE", "UPDATE"]
                  resources: ["persistentvolumeclaims"]
              validations:
              - expression: >-
                  !has(object.spec.storageClassName) ||
                  !('sovereign.cloud.ibm.com/account-id' in namespaceObject.metadata.labels) ||
                  !object.spec.storageClassName.startsWith('ceph-rbd-') ||
                  object.spec.storageClassName ==
                    'ceph-rbd-' + namespaceObject.metadata.labels['sovereign.cloud.ibm.com/account-id']
                messageExpression: >-
                  'StorageClass ' + object.spec.storageClassName + ' is not allowed in namespace ' +
                  namespaceObject.metadata.name + ': tenant ' +
                  namespaceObject.metadata.labels['sovereign.cloud.ibm.com/account-id'] +
                  ' may only use ceph-rbd-' + namespaceObject.metadata.labels['sovereign.cloud.ibm.com/account-id']
                reason: Forbidden
        - complianceType: musthave
          objectDefinition:
            apiVersion: admissionregistration.k8s.io/v1
            kind: ValidatingAdmissionPolicyBinding
            metadata:
              name: tenant-storageclass-isolation
            spec:
              policyName: tenant-storageclass-isolation
              validationActions: ["Deny"]
EOF
}

MANIFEST=$(placement_yaml "$PL" "$POLICY" storageclass)
if [ "$ISOLATION" = 1 ]; then
  MANIFEST="$MANIFEST
---
$(isolation_policy_yaml)
---
$(placement_yaml "$ISO_PL" "$ISO_POLICY" isolation)"
fi

echo ""
echo "Delivery Summary:"
echo "  Tenant:     $TENANT ${TENANT_NAME:+(name: $TENANT_NAME)}"
echo "  Policy:     $POLICY (in $NS)"
[ "$ISOLATION" = 1 ] && echo "  Isolation:  $ISO_POLICY" || echo "  Isolation:  skipped (--no-isolation)"
echo "  Target:     $CLUSTER (ClusterSet: $SET)"
echo ""

if [ "$DRY" = 1 ]; then
  echo "-------------------- MANIFEST PREVIEW (DRY-RUN) --------------------"
  printf '%s\n' "$MANIFEST"
  echo "--------------------------------------------------------------------"
  exit 0
fi

echo "==> [4/4] Applying manifests to hub cluster..."
printf '%s\n' "$MANIFEST" | oc_ apply -f -
echo "Placement and policy manifests applied successfully."

# ---------------------------------------------------------------------------
# Wait / Polling Loop
# ---------------------------------------------------------------------------
if [ "$WAIT" = 1 ]; then
  WANT="$POLICY"
  [ "$ISOLATION" = 1 ] && WANT="$POLICY $ISO_POLICY"
  echo ""
  echo "Waiting for [$WANT] to become Compliant on $CLUSTER (timeout: ${TIMEOUT}s)..."
  ELAPSED=0
  POLL_INTERVAL=10
  while [ $ELAPSED -lt $TIMEOUT ]; do
    ALL=1
    for p in $WANT; do
      S=$(compliance "$p" "$CLUSTER")
      echo "  [$ELAPSED s] $p: ${S:-pending}"
      [ "$S" = "Compliant" ] || ALL=0
    done
    if [ "$ALL" = 1 ]; then
      echo "All policies are Compliant on $CLUSTER!"
      exit 0
    fi
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
  done
  die "timed out after ${TIMEOUT}s; check status with: oc -n $CLUSTER get policy ${NS}.<policy> -o yaml"
fi
