#!/usr/bin/env bash
# create-tenant-isolation.sh
#
# Minimal tenant isolation (see minimal-tenant-isolation.md). Once per tenant.
#
# Where it runs: from the landing zone, against the CONTROL PLANE cluster (the ACM hub). The
# control plane and platform clusters are both reachable only from the landing zone. This script
# talks to the control plane only; ACM delivers the objects to the platform cluster.
#
# Creates one ACM Policy (+ Placement + PlacementBinding + ManagedClusterSetBinding) in the control
# plane namespace sov-core-storage (same as deliver-tenant-storageclass.sh). The Placement selects
# only the target cluster. Do NOT use the per-cluster namespace: ACM reserves it for replicated
# policies and deletes root policies created there.
#
# Safety checks before anything is applied (--context is required; the current context is never used):
#   - the context must be an ACM hub (ManagedCluster 'local-cluster' exists)
#   - --cluster must be a ManagedCluster labelled sovereign.cloud.ibm.com/account-id=platform
#     and be Available
#   - the control plane API server, user and target cluster are printed before the apply
#
# The policy creates on the target cluster, in namespace <tenant-id>:
#   - Namespace labelled sovereign.cloud.ibm.com/account-id=<tenant-id>
#   - RoleBinding tenant-admin: ClusterRole vm-admin for groups tenant-<id>-owner and tenant-<id>-admin
#   - RoleBinding tenant-user:  ClusterRole view     for group  tenant-<id>-user
#
# Nothing else: no NetworkPolicy, quota or admission policy (later phase).
#
# These RoleBindings limit only subjects that call the platform cluster API as those groups.
# They do not limit ArgoCD, which deploys with its own cluster credential. See
# minimal-tenant-isolation.md, "How RBAC applies when ArgoCD deploys", for the tests.
#
# The policy never deletes anything (no prune): --remove deletes only the hub objects, because
# pruning would delete the namespace and the VMs in it.
#
# Usage:
#   create-tenant-isolation.sh --context <ctx> --tenant-id <id> --cluster <managedcluster> [--dry-run]
#   create-tenant-isolation.sh --context <ctx> --tenant-id <id> --cluster <managedcluster> --remove
#
# Options:
#   --context <ctx>             Kubeconfig context of the control plane cluster (required;
#                               list with: oc config get-contexts)
#   --tenant-id <id>            Tenant/Account ID; also the namespace name (required, lowercase
#                               alphanumerics and '-', at most 63 characters)
#   --cluster <managedcluster>  Target platform ManagedCluster (required)
#   --dry-run                   Run the checks and print the manifests; apply nothing
#   --remove                    Delete the control plane Policy, Placement and PlacementBinding
#   -h, --help                  Show this help and exit
#
# Example (from the landing zone; the context names the control plane cluster):
#   ./create-tenant-isolation.sh \
#       --context sovcore-control-plane \
#       --tenant-id bd301ac3-f0f6-4c08-9a0c-ba76d785604d \
#       --cluster claas-api-ocpz-cp4d4-std-tt-testing \
#       --dry-run
set -euo pipefail

ID=""
CLUSTER=""
CTX=""
DRY=0
REMOVE=0

usage() {
  sed -n '/^# Usage:/,/^# Example:/p' "$0" | sed 's/^# \{0,2\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tenant-id) ID="$2"; shift 2 ;;
    --cluster)   CLUSTER="$2"; shift 2 ;;
    --context)   CTX="$2"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    --remove)    REMOVE=1; shift ;;
    -h|--help)   usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$CTX" ] && [ -n "$ID" ] && [ -n "$CLUSTER" ] \
  || { echo "ERROR: --context, --tenant-id and --cluster are required" >&2; exit 2; }

oc_() { oc --context "$CTX" "$@"; }

die() {
  echo "ERROR: $*" >&2
  exit 1
}

printf '%s' "$ID" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' || die "--tenant-id must be lowercase alphanumerics and '-'"
[ "${#ID}" -le 63 ] || die "--tenant-id is ${#ID} characters; namespace names and label values are limited to 63"

HUB_NS="sov-core-storage" # control plane namespace that holds the policies

# Short fixed-length object names: the placement controller labels "<name>-decision-N" (max 63).
POL="tenant-iso-$(printf '%s' "$ID" | shasum | cut -c1-10)"

# ---------------------------------------------------------------------------
# Intended-cluster checks
# ---------------------------------------------------------------------------
oc config get-contexts -o name 2>/dev/null | grep -qx "$CTX" || die "context '$CTX' not found in kubeconfig"
SERVER=$(oc_ whoami --show-server 2>/dev/null) || die "cannot reach the cluster of context '$CTX' (log in first)"
USER_=$(oc_ whoami 2>/dev/null) || die "context '$CTX' is not logged in"
oc_ get managedcluster local-cluster >/dev/null 2>&1 \
  || die "context '$CTX' ($SERVER) is not an ACM hub: ManagedCluster 'local-cluster' not found. Wrong cluster?"
echo "Control plane: context=$CTX server=$SERVER user=$USER_"

if [ "$REMOVE" = 1 ]; then
  echo "Removing control plane objects for tenant $ID in $HUB_NS (the namespace and RoleBindings stay on the cluster)"
  oc_ -n "$HUB_NS" delete placementbinding "$POL" --ignore-not-found
  oc_ -n "$HUB_NS" delete placement "$POL" --ignore-not-found
  oc_ -n "$HUB_NS" delete policy "$POL" --ignore-not-found
  exit 0
fi

oc_ get managedcluster "$CLUSTER" >/dev/null 2>&1 || die "ManagedCluster '$CLUSTER' not found on $SERVER"
ACCOUNT_LABEL=$(oc_ get managedcluster "$CLUSTER" -o jsonpath='{.metadata.labels.sovereign\.cloud\.ibm\.com/account-id}')
[ "$ACCOUNT_LABEL" = "platform" ] \
  || die "ManagedCluster '$CLUSTER' has account-id='${ACCOUNT_LABEL}'; this script only targets account-id=platform"
AVAILABLE=$(oc_ get managedcluster "$CLUSTER" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}')
[ "$AVAILABLE" = "True" ] || die "ManagedCluster '$CLUSTER' is not Available (status: ${AVAILABLE:-unknown})"
oc_ get namespace "$HUB_NS" >/dev/null 2>&1 || die "namespace '$HUB_NS' not found on the control plane"

SET=$(oc_ get managedcluster "$CLUSTER" -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}' 2>/dev/null || true)
[ -n "$SET" ] || die "ManagedCluster '$CLUSTER' has no cluster.open-cluster-management.io/clusterset label"

MANIFEST=$(cat <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${SET}
  namespace: ${HUB_NS}
spec:
  clusterSet: ${SET}
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: ${POL}
  namespace: ${HUB_NS}
  annotations:
    sovereign.cloud.ibm.com/account-id: "${ID}"
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
  name: ${POL}
  namespace: ${HUB_NS}
placementRef: {apiGroup: cluster.open-cluster-management.io, kind: Placement, name: ${POL}}
subjects:
- {apiGroup: policy.open-cluster-management.io, kind: Policy, name: ${POL}}
---
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: ${POL}
  namespace: ${HUB_NS}
  annotations:
    sovereign.cloud.ibm.com/account-id: "${ID}"
spec:
  remediationAction: enforce
  disabled: false
  policy-templates:
  - objectDefinition:
      apiVersion: policy.open-cluster-management.io/v1
      kind: ConfigurationPolicy
      metadata:
        name: ${POL}
      spec:
        remediationAction: enforce
        severity: high
        object-templates:
        - complianceType: musthave
          objectDefinition:
            apiVersion: v1
            kind: Namespace
            metadata:
              name: ${ID}
              labels:
                sovereign.cloud.ibm.com/account-id: "${ID}"
        - complianceType: musthave
          objectDefinition:
            apiVersion: rbac.authorization.k8s.io/v1
            kind: RoleBinding
            metadata: {name: tenant-admin, namespace: ${ID}}
            roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: vm-admin}
            subjects:
            - {apiGroup: rbac.authorization.k8s.io, kind: Group, name: "tenant-${ID}-owner"}
            - {apiGroup: rbac.authorization.k8s.io, kind: Group, name: "tenant-${ID}-admin"}
        - complianceType: musthave
          objectDefinition:
            apiVersion: rbac.authorization.k8s.io/v1
            kind: RoleBinding
            metadata: {name: tenant-user, namespace: ${ID}}
            roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: view}
            subjects:
            - {apiGroup: rbac.authorization.k8s.io, kind: Group, name: "tenant-${ID}-user"}
EOF
)

echo "Target:        ManagedCluster=$CLUSTER (account-id=platform, Available)"
echo "Tenant:        namespace $ID; policy ${HUB_NS}/${POL} on ManagedClusterSet ${SET}"
if [ "$DRY" = 1 ]; then
  printf '%s\n' "$MANIFEST"
  exit 0
fi

printf '%s\n' "$MANIFEST" | oc_ apply -f -

echo "Waiting for ${POL} to become Compliant (max 5 min)..."
for _ in $(seq 1 30); do
  S=$(oc_ -n "$HUB_NS" get policy "$POL" -o jsonpath='{.status.compliant}' 2>/dev/null || true)
  echo "  ${POL}: ${S:-pending}"
  [ "$S" = "Compliant" ] && exit 0
  sleep 10
done
die "timed out; check: oc -n $HUB_NS get policy $POL -o yaml"
