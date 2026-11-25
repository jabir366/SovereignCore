#!/usr/bin/env bash
# deliver-tenant-storageclass.sh
#
# Run against the HUB, once per tenant. Makes the tenant's StorageClass (ceph-rbd-<tenant-id>)
# available on the PLATFORM cluster, so tenant MongoDB VMs can use the tenant's storage pool
# while running on the shared platform cluster.
#
# Target: only the ManagedCluster labelled sovereign.cloud.ibm.com/account-id=platform. The script
# never places anything on any other cluster. If --cluster is omitted it is resolved from that label.
#
# Ownership: the tenant's StorageRegistration (spec.ofAccount=<tenant>) is the source of truth. Its
# Ready StorageDeliveryRequest reports the StorageClass policy (status.policyLevels, level
# StorageClass). The controller creates that policy and places it on the tenant's own cluster.
# This script adds a placement so the same policy is also delivered to the platform cluster.
#
# Steps (each step is skipped when its objects already exist, so re-runs are safe):
#   1. Resolve the platform ManagedCluster and check it is Available and bound in the namespace.
#   2. Wait for the tenant's StorageRegistration, then for its Ready StorageDeliveryRequest.
#   3. Check the StorageClass in that policy is named ceph-rbd-<tenant-id> (the isolation rule
#      requires this exact name).
#   4. Placement + PlacementBinding for that policy on the platform cluster. Applied only if the
#      placement does not already select the cluster.
#   5. Shared isolation policy tenant-storageclass-isolation (ValidatingAdmissionPolicy + binding),
#      created only if it does not exist. It is never overwritten, because it is shared by all
#      tenants. Its placement on the platform cluster is applied only if missing.
#   6. Wait until the StorageClass and isolation policies are Compliant on the platform cluster.
#
# Preflight warnings (do not stop the run): ODF client policies not Compliant on the platform
# cluster, and the config-policy-controller addon not healthy (policies cannot be enforced then).
#
# Usage:
#   deliver-tenant-storageclass.sh --tenant-id <account-id> [OPTIONS]
#   deliver-tenant-storageclass.sh --tenant-id <account-id> --remove [OPTIONS]
#
# Options:
#   --tenant, --tenant-id <id>  Tenant/Account ID (required), e.g. bd301ac3-f0f6-4c08-9a0c-ba76d785604d
#   --cluster <managedcluster>  Platform ManagedCluster (optional; must carry account-id=platform).
#                               Default: resolved from the label.
#   --namespace, -n <ns>        ACM policy namespace on hub (default: sov-core-storage)
#   --context <ctx>             Kubeconfig context to use for oc commands
#   --no-isolation              Deliver the StorageClass only, without the isolation policy
#   --timeout <sec>             Max wait for each object to appear or become Compliant (default: 900)
#   --dry-run                   Show what would be applied; apply nothing and do not wait
#   --remove                    Remove this tenant's StorageClass placement from the platform
#                               cluster. Isolation placement is removed only when no other tenant
#                               StorageClass remains there. The isolation policy itself is kept.
#   -h, --help                  Show this help and exit
#
# Examples:
#   ./deliver-tenant-storageclass.sh --tenant-id bd301ac3-f0f6-4c08-9a0c-ba76d785604d
#   ./deliver-tenant-storageclass.sh --tenant-id bd301ac3-f0f6-4c08-9a0c-ba76d785604d --dry-run
set -euo pipefail

NS="sov-core-storage"
ISO_POLICY="tenant-storageclass-isolation"
PLATFORM_ACCOUNT="platform"
TENANT=""
CLUSTER=""
CTX=""
DRY=0
REMOVE=0
ISOLATION=1
TIMEOUT=900
POLL=10

usage() {
  sed -n '/^# Usage:/,/^# Examples:/p' "$0" | sed 's/^# \{0,2\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tenant|--tenant-id) TENANT="$2"; shift 2 ;;
    --cluster)            CLUSTER="$2"; shift 2 ;;
    --namespace|-n)       NS="$2"; shift 2 ;;
    --context)            CTX="$2"; shift 2 ;;
    --no-isolation)       ISOLATION=0; shift ;;
    --timeout)            TIMEOUT="$2"; shift 2 ;;
    --dry-run)            DRY=1; shift ;;
    --remove)             REMOVE=1; shift ;;
    -h|--help)            usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$TENANT" ] || { echo "ERROR: --tenant-id is required" >&2; exit 2; }

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

step() { echo; echo "==> $*"; }

# Wait until the command succeeds. Usage: wait_for "<description>" <command> [args...]
wait_for() {
  local desc="$1"; shift
  local waited=0
  if [ "$DRY" = 1 ]; then
    "$@" && return 0
    echo "  [dry-run] would wait for $desc"
    return 0
  fi
  until "$@"; do
    [ "$waited" -lt "$TIMEOUT" ] || die "timed out after ${TIMEOUT}s waiting for $desc"
    echo "  waiting for $desc (${waited}s)"
    sleep "$POLL"
    waited=$((waited + POLL))
  done
  echo "  ready: $desc"
}

apply_manifest() { # $1 description, $2 manifest
  if [ "$DRY" = 1 ]; then
    echo "  [dry-run] would apply $1:"
    printf '%s\n' "$2" | sed 's/^/    /'
  else
    printf '%s\n' "$2" | oc_ apply -f - >/dev/null
    echo "  applied $1"
  fi
}

DNS_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
printf '%s' "$TENANT" | grep -Eq "$DNS_RE" || die "--tenant-id must be lowercase alphanumerics and '-'"

# ---------------------------------------------------------------------------
# Platform cluster: only the ManagedCluster labelled account-id=platform
# ---------------------------------------------------------------------------
step "1. Resolving platform ManagedCluster"

PLATFORM_CLUSTERS=$(oc_ get managedcluster -l "sovereign.cloud.ibm.com/account-id=${PLATFORM_ACCOUNT}" \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

if [ -z "$CLUSTER" ]; then
  [ -n "$PLATFORM_CLUSTERS" ] || die "no ManagedCluster labelled sovereign.cloud.ibm.com/account-id=${PLATFORM_ACCOUNT}"
  case "$PLATFORM_CLUSTERS" in
    *" "*) die "more than one platform ManagedCluster ($PLATFORM_CLUSTERS); pass --cluster" ;;
  esac
  CLUSTER="$PLATFORM_CLUSTERS"
fi

ACCOUNT_LABEL=$(oc_ get managedcluster "$CLUSTER" -o jsonpath='{.metadata.labels.sovereign\.cloud\.ibm\.com/account-id}' 2>/dev/null || true)
[ -n "$ACCOUNT_LABEL" ] || die "ManagedCluster '$CLUSTER' not found"
[ "$ACCOUNT_LABEL" = "$PLATFORM_ACCOUNT" ] \
  || die "ManagedCluster '$CLUSTER' has account-id='$ACCOUNT_LABEL'; this script only targets account-id=${PLATFORM_ACCOUNT}"

AVAILABLE=$(oc_ get managedcluster "$CLUSTER" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || true)
[ "$AVAILABLE" = "True" ] || die "ManagedCluster '$CLUSTER' is not Available (status: ${AVAILABLE:-unknown})"

SET=$(oc_ get managedcluster "$CLUSTER" -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}' 2>/dev/null || true)
[ -n "$SET" ] || die "ManagedCluster '$CLUSTER' has no clusterset label"
oc_ -n "$NS" get managedclustersetbinding "$SET" >/dev/null 2>&1 \
  || die "ManagedClusterSet '$SET' is not bound in '$NS' (cannot place policies there)"

echo "Platform cluster: $CLUSTER (set: $SET)"

ADDON=$(oc_ get managedcluster "$CLUSTER" -o jsonpath='{.metadata.labels.feature\.open-cluster-management\.io/addon-config-policy-controller}' 2>/dev/null || true)
if [ "$ADDON" != "available" ]; then
  echo "WARNING: config-policy-controller addon is '${ADDON:-unknown}' on $CLUSTER; policies cannot be enforced until it is available" >&2
fi

# ---------------------------------------------------------------------------
# Tenant StorageRegistration -> Ready StorageDeliveryRequest -> StorageClass policy
# ---------------------------------------------------------------------------
find_registration() {
  oc_ -n "$NS" get storageregistrations.storage.sovereign.cloud.ibm.com -o json 2>/dev/null | python3 -c '
import sys, json
t = sys.argv[1]
for i in json.load(sys.stdin).get("items", []):
    if i.get("spec", {}).get("ofAccount") == t:
        print(i["metadata"]["name"])
        break
' "$TENANT" || true
}

find_storage_class_policy() { # $1 registration name
  oc_ -n "$NS" get storagedeliveryrequests.storage.sovereign.cloud.ibm.com -o json 2>/dev/null | python3 -c '
import sys, json
r = sys.argv[1]
for i in json.load(sys.stdin).get("items", []):
    if i.get("spec", {}).get("storageRegistrationRef", {}).get("name") != r:
        continue
    if i.get("status", {}).get("phase") != "Ready":
        continue
    for l in i.get("status", {}).get("policyLevels", []):
        if l.get("level") == "StorageClass" and l.get("policyName"):
            print(l["policyName"])
            sys.exit(0)
' "$1" || true
}

step "2. Waiting for the tenant StorageRegistration and its StorageClass policy"

REG=""
reg_found() { REG=$(find_registration); [ -n "$REG" ]; }
wait_for "StorageRegistration with ofAccount=$TENANT" reg_found
[ -n "$REG" ] || die "no StorageRegistration with ofAccount=$TENANT"
echo "  StorageRegistration: $REG"

SC_POLICY=""
sc_policy_found() { SC_POLICY=$(find_storage_class_policy "$REG"); [ -n "$SC_POLICY" ]; }
wait_for "Ready StorageDeliveryRequest with StorageClass policy for $REG" sc_policy_found
[ -n "$SC_POLICY" ] || die "no Ready StorageDeliveryRequest with a StorageClass policy for $REG"
echo "  StorageClass policy: $SC_POLICY"

[ "$DRY" = 1 ] || oc_ -n "$NS" get policy "$SC_POLICY" >/dev/null 2>&1 \
  || die "policy '$SC_POLICY' reported by the SDR does not exist in '$NS'"

# ---------------------------------------------------------------------------
# Check the StorageClass name required by the isolation rule
# ---------------------------------------------------------------------------
step "3. Checking StorageClass name in $SC_POLICY"

EXPECTED_SC="ceph-rbd-${TENANT}"
if [ "$DRY" = 1 ] && ! oc_ -n "$NS" get policy "$SC_POLICY" >/dev/null 2>&1; then
  echo "  [dry-run] policy not available to inspect; expected StorageClass: $EXPECTED_SC"
else
  SC_NAMES=$(oc_ -n "$NS" get policy "$SC_POLICY" -o json | python3 -c '
import sys, json
for t in json.load(sys.stdin)["spec"]["policy-templates"]:
    for o in t["objectDefinition"]["spec"].get("object-templates", []):
        od = o.get("objectDefinition", {})
        if od.get("kind") == "StorageClass":
            print(od["metadata"]["name"])
')
  echo "  StorageClasses in policy: ${SC_NAMES:-none}"
  printf '%s\n' "$SC_NAMES" | grep -qx "$EXPECTED_SC" \
    || die "policy $SC_POLICY does not define StorageClass '$EXPECTED_SC' (found: ${SC_NAMES:-none}); the isolation rule would block its PVCs"
  echo "  OK: StorageClass $EXPECTED_SC"
fi

# ---------------------------------------------------------------------------
# Name length: placement controller labels "<name>-decision-N" (max 63 chars)
# ---------------------------------------------------------------------------
hash_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  elif command -v sha1sum >/dev/null 2>&1; then
    sha1sum
  elif command -v shasum >/dev/null 2>&1; then
    shasum
  else
    md5sum
  fi
}
CH=$(printf '%s' "$CLUSTER" | hash_cmd | cut -c1-10)
PL="${SC_POLICY}-on-${CH}"
ISO_PL="tsc-isolation-on-${CH}"
[ $(( ${#PL} + 9 )) -le 63 ] || die "placement name '$PL' is too long (limit 63 with '-decision-N')"

# ---------------------------------------------------------------------------
# Helpers for existence and state checks
# ---------------------------------------------------------------------------
placement_selects() { # $1 placement name
  local d
  d=$(oc_ -n "$NS" get placementdecisions.cluster.open-cluster-management.io \
      -l "cluster.open-cluster-management.io/placement=$1" \
      -o jsonpath='{.items[*].status.decisions[*].clusterName}' 2>/dev/null || true)
  case " $d " in *" $CLUSTER "*) return 0 ;; *) return 1 ;; esac
}

compliance() { # $1 policy name
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
' "$CLUSTER" || true
}

is_compliant() { [ "$(compliance "$1")" = "Compliant" ]; }

policy_exists() { oc_ -n "$NS" get policy "$1" >/dev/null 2>&1; }

placement_yaml() { # $1 name $2 policy $3 kind
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

# Shared isolation policy: tenant-agnostic. Applied only when missing; never overwritten.
isolation_policy_yaml() {
  cat <<EOF
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: ${ISO_POLICY}
  namespace: ${NS}
spec:
  remediationAction: enforce
  disabled: false
  policy-templates:
  - objectDefinition:
      apiVersion: policy.open-cluster-management.io/v1
      kind: ConfigurationPolicy
      metadata:
        name: ${ISO_POLICY}
      spec:
        remediationAction: enforce
        severity: high
        object-templates:
        - complianceType: musthave
          objectDefinition:
            apiVersion: admissionregistration.k8s.io/v1
            kind: ValidatingAdmissionPolicy
            metadata:
              name: ${ISO_POLICY}
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
              name: ${ISO_POLICY}
            spec:
              policyName: ${ISO_POLICY}
              validationActions: ["Deny"]
EOF
}

# ---------------------------------------------------------------------------
# Removal path
# ---------------------------------------------------------------------------
if [ "$REMOVE" = 1 ]; then
  step "Removing StorageClass delivery of tenant $TENANT from $CLUSTER"
  REG=$(find_registration)
  [ -n "$REG" ] || die "no StorageRegistration with ofAccount=$TENANT"
  SC_POLICY=$(find_storage_class_policy "$REG")
  [ -n "$SC_POLICY" ] || die "no Ready StorageDeliveryRequest with a StorageClass policy for $REG"
  PL="${SC_POLICY}-on-${CH}"

  if [ "$DRY" = 1 ]; then
    echo "  [dry-run] would delete placementbinding and placement $PL in $NS"
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

  if [ "$LEFT" -eq 0 ]; then
    echo "  no other tenant StorageClass on $CLUSTER; removing isolation placement $ISO_PL (policy $ISO_POLICY is kept)"
    if [ "$DRY" = 1 ]; then
      echo "  [dry-run] would delete placementbinding and placement $ISO_PL"
    else
      oc_ -n "$NS" delete placementbinding "$ISO_PL" --ignore-not-found
      oc_ -n "$NS" delete placement "$ISO_PL" --ignore-not-found
    fi
  else
    echo "  $LEFT other tenant StorageClass(es) still on $CLUSTER; keeping isolation placement"
  fi
  echo "Done. Objects already delivered stay on $CLUSTER until deleted there."
  exit 0
fi

# ---------------------------------------------------------------------------
# Deliver: StorageClass placement (skip if the cluster is already selected)
# ---------------------------------------------------------------------------
step "4. StorageClass placement for $SC_POLICY on $CLUSTER"

if placement_selects "$PL"; then
  echo "  already present: placement $PL selects $CLUSTER (skipped)"
else
  apply_manifest "placement $PL" "$(placement_yaml "$PL" "$SC_POLICY" storageclass)"
  wait_for "placement $PL to select $CLUSTER" placement_selects "$PL"
fi

# ---------------------------------------------------------------------------
# Isolation: policy only if missing, placement only if not selecting the cluster
# ---------------------------------------------------------------------------
if [ "$ISOLATION" = 1 ]; then
  step "5. Isolation policy $ISO_POLICY on $CLUSTER"

  if policy_exists "$ISO_POLICY"; then
    echo "  already present: $ISO_POLICY (shared, not modified)"
  else
    apply_manifest "policy $ISO_POLICY" "$(isolation_policy_yaml)"
  fi

  if placement_selects "$ISO_PL"; then
    echo "  already present: placement $ISO_PL selects $CLUSTER (skipped)"
  else
    apply_manifest "placement $ISO_PL" "$(placement_yaml "$ISO_PL" "$ISO_POLICY" isolation)"
    wait_for "placement $ISO_PL to select $CLUSTER" placement_selects "$ISO_PL"
  fi
else
  step "5. Isolation skipped (--no-isolation)"
fi

# ---------------------------------------------------------------------------
# Compliance on the platform cluster
# ---------------------------------------------------------------------------
step "6. Waiting for compliance on $CLUSTER"

WANT="$SC_POLICY"
[ "$ISOLATION" = 1 ] && WANT="$SC_POLICY $ISO_POLICY"
for p in $WANT; do
  if [ "$DRY" = 1 ]; then
    echo "  [dry-run] would wait for $p to be Compliant on $CLUSTER"
  else
    wait_for "$p Compliant on $CLUSTER" is_compliant "$p"
  fi
done

# ODF health is reported, not enforced here: the StorageClass needs these on the platform cluster.
for p in install-odf-operator cluster-ext-odf-platform; do
  S=$(compliance "$p")
  if [ "$S" != "Compliant" ]; then
    echo "WARNING: $p is '${S:-not placed}' on $CLUSTER; the platform cluster may not reach the Ceph pool" >&2
  fi
done

echo
echo "Delivered: StorageClass ceph-rbd-${TENANT} (policy $SC_POLICY) to $CLUSTER"
[ "$ISOLATION" = 1 ] && echo "Isolation: $ISO_POLICY enforced on $CLUSTER"
exit 0
