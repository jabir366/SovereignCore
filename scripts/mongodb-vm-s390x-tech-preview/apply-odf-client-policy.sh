#!/usr/bin/env bash
# apply-odf-client-policy.sh
#
# Automates the ACM policy application on the ACM Hub cluster to install
# OpenShift Data Foundation (ODF) client operator on an imported spoke/tenant cluster.
#
# What it does:
#   1. Validates prerequisites on ACM Hub (oc CLI, cluster login, ManagedCluster status)
#   2. Detects OpenShift minor version from ManagedCluster metadata to derive ODF channel (e.g., stable-4.16)
#   3. Ensures ManagedClusterSetBinding exists in the target policy namespace
#   4. Generates and applies ACM Policy (Namespace + OperatorGroup + Subscription for odf-operator)
#   5. Generates and applies PlacementRule and PlacementBinding
#   6. Labels the ManagedCluster with 'odf-client=true' to trigger policy propagation
#   7. Verifies PlacementRule decision and policy status
#   8. (Optional) Waits for policy compliance / ODF CSV installation on tenant
#
# Usage:
#   ./apply-odf-client-policy.sh <CLUSTER_NAME> [OPTIONS]
#
# Options:
#   --cluster <name>          ManagedCluster name on ACM Hub (can also be passed as 1st argument)
#   --namespace <ns>          ACM policy namespace on Hub (default: acm-service-broker)
#   --channel <channel>       ODF operator channel (default: auto-detected, e.g. stable-4.16)
#   --source <catalog-source> CatalogSource for subscription (default: redhat-operators)
#   --source-namespace <ns>   CatalogSource namespace (default: openshift-marketplace)
#   --wait                    Wait and poll for policy propagation and CSV status
#   --timeout <sec>           Timeout in seconds when --wait is specified (default: 300)
#   --spoke-kubeconfig <path> Optional kubeconfig for tenant cluster to verify CSV directly
#   --dry-run                 Preview generated manifests without applying
#   -h, --help                Show this help and exit
#
# Examples:
#   ./apply-odf-client-policy.sh tenant-a
#   ./apply-odf-client-policy.sh tenant-a --wait
#   ./apply-odf-client-policy.sh tenant-a --channel stable-4.16 --namespace acm-service-broker

set -euo pipefail

# ---------------------------------------------------------------------------
# Styling and Logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  C_RESET="$(tput sgr0)"
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
  C_CYAN="$(tput setaf 6)"
  C_BOLD="$(tput bold)"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
  C_BOLD=""
fi

log_info()  { echo "${C_BLUE}${C_BOLD}[INFO]${C_RESET}  $*"; }
log_ok()    { echo "${C_GREEN}${C_BOLD}[OK]${C_RESET}    $*"; }
log_warn()  { echo "${C_YELLOW}${C_BOLD}[WARN]${C_RESET}  $*"; }
log_err()   { echo "${C_RED}${C_BOLD}[ERROR]${C_RESET} $*" >&2; }
log_step()  { echo ""; echo "${C_CYAN}${C_BOLD}==> Step $1: $2${C_RESET}"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
CLUSTER_NAME=""
POLICY_NAMESPACE="${POLICY_NAMESPACE:-acm-service-broker}"
OCP_CHANNEL=""
CATALOG_SOURCE="redhat-operators"
CATALOG_SOURCE_NS="openshift-marketplace"
WAIT_FOR_COMPLIANCE=false
WAIT_TIMEOUT=300
SPOKE_KUBECONFIG=""
DRY_RUN=false

# ---------------------------------------------------------------------------
# Help / Usage
# ---------------------------------------------------------------------------
usage() {
  sed -n '/^# Usage:/,/^# Examples:/p' "$0" | sed 's/^# \{0,2\}//'
  exit 0
}

# ---------------------------------------------------------------------------
# Argument Parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)          CLUSTER_NAME="${2:?'--cluster requires a value'}"; shift 2 ;;
    --namespace)        POLICY_NAMESPACE="${2:?'--namespace requires a value'}"; shift 2 ;;
    --channel)          OCP_CHANNEL="${2:?'--channel requires a value'}"; shift 2 ;;
    --source)           CATALOG_SOURCE="${2:?'--source requires a value'}"; shift 2 ;;
    --source-namespace) CATALOG_SOURCE_NS="${2:?'--source-namespace requires a value'}"; shift 2 ;;
    --wait)             WAIT_FOR_COMPLIANCE=true; shift 1 ;;
    --timeout)          WAIT_TIMEOUT="${2:?'--timeout requires a value'}"; shift 2 ;;
    --spoke-kubeconfig) SPOKE_KUBECONFIG="${2:?'--spoke-kubeconfig requires a value'}"; shift 2 ;;
    --dry-run)          DRY_RUN=true; shift 1 ;;
    -h|--help)          usage ;;
    *)
      if [[ -z "$CLUSTER_NAME" && "$1" != -* ]]; then
        CLUSTER_NAME="$1"
        shift 1
      else
        log_err "Unknown argument: $1"
        usage
      fi
      ;;
  esac
done

if [[ -z "$CLUSTER_NAME" ]]; then
  log_err "ManagedCluster name is required."
  echo "Usage: $0 <CLUSTER_NAME> [OPTIONS]"
  exit 1
fi

# ---------------------------------------------------------------------------
# Pre-flight Checks
# ---------------------------------------------------------------------------
log_step "1" "Pre-flight checks on ACM Hub"

command -v oc &>/dev/null || { log_err "'oc' CLI is not installed or not in PATH"; exit 1; }

# Verify access to cluster
if ! oc whoami &>/dev/null; then
  log_err "Not logged into OpenShift/ACM Hub. Run 'oc login' or configure KUBECONFIG first."
  exit 1
fi

HUB_USER=$(oc whoami 2>/dev/null || echo "unknown")
HUB_API=$(oc whoami --show-server 2>/dev/null || echo "unknown")
log_info "Connected to ACM Hub as: ${C_BOLD}${HUB_USER}${C_RESET} (${HUB_API})"

# Verify ManagedCluster exists
log_info "Checking ManagedCluster '${CLUSTER_NAME}'..."
if ! oc get managedcluster "${CLUSTER_NAME}" &>/dev/null; then
  log_err "ManagedCluster '${CLUSTER_NAME}' not found on Hub. Verify cluster import first."
  exit 1
fi

# Check JOINED and AVAILABLE status
JOINED_STATUS=$(oc get managedcluster "${CLUSTER_NAME}" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}' 2>/dev/null || echo "Unknown")
AVAILABLE_STATUS=$(oc get managedcluster "${CLUSTER_NAME}" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || echo "Unknown")

if [[ "${JOINED_STATUS}" != "True" || "${AVAILABLE_STATUS}" != "True" ]]; then
  log_warn "ManagedCluster '${CLUSTER_NAME}' is not fully ready (Joined=${JOINED_STATUS}, Available=${AVAILABLE_STATUS})."
  log_warn "Policy may not propagate until the cluster reaches Available=True."
else
  log_ok "ManagedCluster '${CLUSTER_NAME}' is Ready (Joined=True, Available=True)"
fi

# ---------------------------------------------------------------------------
# Derive or Validate ODF Channel
# ---------------------------------------------------------------------------
log_step "2" "Determining ODF operator channel"

if [[ -z "${OCP_CHANNEL}" ]]; then
  OCP_VER=$(oc get managedcluster "${CLUSTER_NAME}" -o jsonpath='{.metadata.labels.openshiftVersion-major-minor}' 2>/dev/null || true)
  if [[ -n "${OCP_VER}" ]]; then
    OCP_CHANNEL="stable-${OCP_VER}"
    log_info "Auto-detected OpenShift version '${OCP_VER}' -> Channel: ${C_BOLD}${OCP_CHANNEL}${C_RESET}"
  else
    OCP_CHANNEL="stable-4.16"
    log_warn "Could not auto-detect openshiftVersion-major-minor label from ManagedCluster. Defaulting channel to '${OCP_CHANNEL}'"
  fi
else
  log_info "Using specified channel: ${C_BOLD}${OCP_CHANNEL}${C_RESET}"
fi

# ---------------------------------------------------------------------------
# Verify or Ensure ManagedClusterSetBinding
# ---------------------------------------------------------------------------
log_step "3" "Checking ManagedClusterSetBinding in '${POLICY_NAMESPACE}'"

# Ensure target namespace exists
if ! oc get namespace "${POLICY_NAMESPACE}" &>/dev/null; then
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would create namespace '${POLICY_NAMESPACE}'"
  else
    log_info "Creating namespace '${POLICY_NAMESPACE}'..."
    oc create namespace "${POLICY_NAMESPACE}"
  fi
fi

CLUSTERSET=$(oc get managedcluster "${CLUSTER_NAME}" -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}' 2>/dev/null || true)
[[ -z "${CLUSTERSET}" ]] && CLUSTERSET="default"

log_info "Cluster belongs to clusterset: '${CLUSTERSET}'"

if oc get managedclustersetbinding "${CLUSTERSET}" -n "${POLICY_NAMESPACE}" &>/dev/null; then
  log_ok "ManagedClusterSetBinding '${CLUSTERSET}' exists in namespace '${POLICY_NAMESPACE}'"
else
  log_warn "ManagedClusterSetBinding '${CLUSTERSET}' not found in '${POLICY_NAMESPACE}'"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would create ManagedClusterSetBinding '${CLUSTERSET}'"
  else
    log_info "Creating ManagedClusterSetBinding '${CLUSTERSET}' in '${POLICY_NAMESPACE}'..."
    cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${CLUSTERSET}
  namespace: ${POLICY_NAMESPACE}
spec:
  clusterSet: ${CLUSTERSET}
EOF
    log_ok "ManagedClusterSetBinding '${CLUSTERSET}' created in '${POLICY_NAMESPACE}'"
  fi
fi

# ---------------------------------------------------------------------------
# Generate ACM Policy Manifests
# ---------------------------------------------------------------------------
log_step "4" "Generating and applying ACM ODF client policy"

POLICY_NAME="install-odf-client"
PLACEMENT_RULE_NAME="placement-odf-tenant-${CLUSTER_NAME}"
PLACEMENT_BINDING_NAME="binding-install-odf-${CLUSTER_NAME}"

MANIFEST=$(cat <<EOF
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: ${POLICY_NAME}
  namespace: ${POLICY_NAMESPACE}
  annotations:
    policy.open-cluster-management.io/standards: NIST SP 800-53
    policy.open-cluster-management.io/categories: CM Configuration Management
    policy.open-cluster-management.io/controls: CM-2 Baseline Configuration
spec:
  remediationAction: enforce
  disabled: false
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: odf-client-namespace
        spec:
          remediationAction: enforce
          severity: high
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Namespace
                metadata:
                  name: openshift-storage
                  labels:
                    openshift.io/cluster-monitoring: "true"
                    pod-security.kubernetes.io/enforce: privileged
                    pod-security.kubernetes.io/audit: privileged
                    pod-security.kubernetes.io/warn: privileged
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: odf-client-operatorgroup
        spec:
          remediationAction: enforce
          severity: high
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: operators.coreos.com/v1
                kind: OperatorGroup
                metadata:
                  name: openshift-storage-operatorgroup
                  namespace: openshift-storage
                spec:
                  targetNamespaces:
                    - openshift-storage
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: odf-client-subscription
        spec:
          remediationAction: enforce
          severity: high
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: operators.coreos.com/v1alpha1
                kind: Subscription
                metadata:
                  name: odf-operator
                  namespace: openshift-storage
                spec:
                  channel: ${OCP_CHANNEL}
                  installPlanApproval: Automatic
                  name: odf-operator
                  source: ${CATALOG_SOURCE}
                  sourceNamespace: ${CATALOG_SOURCE_NS}
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: odf-client-csv-status
        spec:
          remediationAction: inform
          severity: high
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: operators.coreos.com/v1alpha1
                kind: ClusterServiceVersion
                metadata:
                  namespace: openshift-storage
                spec:
                  displayName: OpenShift Data Foundation
                status:
                  phase: Succeeded
---
apiVersion: apps.open-cluster-management.io/v1
kind: PlacementRule
metadata:
  name: ${PLACEMENT_RULE_NAME}
  namespace: ${POLICY_NAMESPACE}
spec:
  clusterSelector:
    matchLabels:
      odf-client: "true"
  clusterConditions:
    - type: ManagedClusterConditionAvailable
      status: "True"
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: ${PLACEMENT_BINDING_NAME}
  namespace: ${POLICY_NAMESPACE}
placementRef:
  name: ${PLACEMENT_RULE_NAME}
  kind: PlacementRule
  apiGroup: apps.open-cluster-management.io
subjects:
  - name: ${POLICY_NAME}
  kind: Policy
  apiGroup: policy.open-cluster-management.io
EOF
)

if [[ "$DRY_RUN" == "true" ]]; then
  echo "-------------------- MANIFEST PREVIEW --------------------"
  echo "$MANIFEST"
  echo "----------------------------------------------------------"
  log_info "[DRY-RUN] Manifest generated. Exiting without applying."
  exit 0
fi

log_info "Applying Policy, PlacementRule, and PlacementBinding..."
echo "$MANIFEST" | oc apply -f -
log_ok "ACM Policy resources applied in namespace '${POLICY_NAMESPACE}'"

# ---------------------------------------------------------------------------
# Label ManagedCluster
# ---------------------------------------------------------------------------
log_step "5" "Labeling ManagedCluster '${CLUSTER_NAME}' with odf-client=true"

oc label managedcluster "${CLUSTER_NAME}" odf-client=true --overwrite
log_ok "ManagedCluster '${CLUSTER_NAME}' labeled with 'odf-client=true'"

# ---------------------------------------------------------------------------
# Verify PlacementRule & Policy Propagation
# ---------------------------------------------------------------------------
log_step "6" "Verifying policy placement and propagation"

sleep 3
DECISIONS=$(oc get placementrule "${PLACEMENT_RULE_NAME}" -n "${POLICY_NAMESPACE}" -o jsonpath='{.status.decisions[*].clusterName}' 2>/dev/null || echo "")

if [[ "$DECISIONS" =~ (^|[[:space:]])"${CLUSTER_NAME}"($|[[:space:]]) ]]; then
  log_ok "PlacementRule '${PLACEMENT_RULE_NAME}' selected cluster '${CLUSTER_NAME}'"
else
  log_warn "Cluster '${CLUSTER_NAME}' not yet visible in PlacementRule decisions (found: '${DECISIONS:-none}')."
  log_warn "ACM controller will update decisions in a few seconds."
fi

log_info "Checking propagated policy in cluster namespace '${CLUSTER_NAME}' on Hub..."
if oc get policy "${POLICY_NAMESPACE}.${POLICY_NAME}" -n "${CLUSTER_NAME}" &>/dev/null; then
  log_ok "Policy '${POLICY_NAMESPACE}.${POLICY_NAME}' propagated to namespace '${CLUSTER_NAME}'"
else
  log_info "Policy propagation in progress (ManagedCluster namespace: '${CLUSTER_NAME}')"
fi

# ---------------------------------------------------------------------------
# Optional: Wait / Verification Loop
# ---------------------------------------------------------------------------
if [[ "$WAIT_FOR_COMPLIANCE" == "true" ]]; then
  log_step "7" "Waiting for policy compliance / operator installation (timeout: ${WAIT_TIMEOUT}s)"
  
  ELAPSED=0
  POLL_INTERVAL=10
  COMPLIANT=false
  
  while [[ $ELAPSED -lt $WAIT_TIMEOUT ]]; do
    STATUS=$(oc get policy "${POLICY_NAME}" -n "${POLICY_NAMESPACE}" -o jsonpath='{.status.status[?(@.clustername=="'${CLUSTER_NAME}'")].compliant}' 2>/dev/null || echo "")
    
    if [[ "$STATUS" == "Compliant" ]]; then
      log_ok "Policy '${POLICY_NAME}' is now Compliant on cluster '${CLUSTER_NAME}'!"
      COMPLIANT=true
      break
    fi
    
    echo -n "."
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
  done
  echo ""

  if [[ "$COMPLIANT" != "true" ]]; then
    log_warn "Timed out waiting for policy compliance. Current status: ${STATUS:-Pending/NonCompliant}"
    log_info "You can monitor compliance with:"
    log_info "  oc get policy ${POLICY_NAME} -n ${POLICY_NAMESPACE}"
  fi

  # If spoke kubeconfig was provided, check CSV directly on tenant
  if [[ -n "$SPOKE_KUBECONFIG" && -f "$SPOKE_KUBECONFIG" ]]; then
    log_info "Checking ODF operator CSV on tenant cluster..."
    if oc --kubeconfig="$SPOKE_KUBECONFIG" get csv -n openshift-storage 2>/dev/null | grep -q "odf-operator"; then
      CSV_STATUS=$(oc --kubeconfig="$SPOKE_KUBECONFIG" get csv -n openshift-storage -o jsonpath='{.items[?(@.metadata.name=~"odf-operator.*")].status.phase}' 2>/dev/null || echo "Unknown")
      log_ok "Tenant cluster odf-operator CSV status: ${CSV_STATUS}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================================="
echo "${C_GREEN}${C_BOLD} ODF Client ACM Policy Application Completed Successfully!${C_RESET}"
echo "=========================================================================="
echo "  Target Cluster     : ${CLUSTER_NAME}"
echo "  Policy Namespace   : ${POLICY_NAMESPACE}"
echo "  Policy Name        : ${POLICY_NAME}"
echo "  ODF Channel        : ${OCP_CHANNEL}"
echo "  PlacementRule      : ${PLACEMENT_RULE_NAME}"
echo "  PlacementBinding   : ${PLACEMENT_BINDING_NAME}"
echo "=========================================================================="
echo ""
echo "Verification commands (from ACM Hub):"
echo "  oc get policy -n ${POLICY_NAMESPACE}"
echo "  oc get placementrule ${PLACEMENT_RULE_NAME} -n ${POLICY_NAMESPACE}"
echo "  oc get policy -n ${CLUSTER_NAME}"
echo ""
echo "Verification commands (from Tenant Cluster):"
echo "  oc get csv -n openshift-storage"
echo "  oc get pods -n openshift-storage"
echo "  oc get storagecluster -n openshift-storage"
echo "  oc get sc"
echo "=========================================================================="
