#!/usr/bin/env bash
# apply-odf-client-policy.sh
#
# Automates, on the ACM Hub, the ODF client setup described in sov-core-storage/docs:
#   - odf-client-install-policy.yaml           (Stage 1, generic)
#   - odf-client-config-policy-template.yaml   (Stage 2, per tenant, block/RBD only)
#
# Stage 1 - ODF operator install policy (always applied): install-odf-client
#   1. Namespace openshift-storage
#   2. OperatorGroup openshift-storage-operatorgroup
#   3. Subscription odf-operator (channel auto-detected from the ManagedCluster)
#   4. CSV status check (OpenShift Data Foundation = Succeeded)
#   Placement: PlacementRule selecting ManagedClusters labeled odf-client=true
#
# Stage 2 - Tenant ODF configure policy (applied when --tenant is given): <tenant>-odf-client-config
#   1.  rook-ceph-external-cluster-details Secret (from <tenant>-external-config.json)
#   2.  StorageCluster in external mode (block only; CephFS/RGW/NooBaa ignored)
#   3.  RBD CSI Driver (rbd.csi.ceph.com)
#   4.  StorageCluster Ready check
#   5.  Ensure externalStorage.enable=true (workaround for ACM merge limitation)
#   6.  Scale noobaa-operator to 0 replicas
#   6a. Verify tenant CSI secrets exist (rook-csi-rbd-provisioner/node-<tenant>-<pool>)
#   7.  Tenant StorageClass (<tenant>-rbd-storage, provisioner rbd.csi.ceph.com)
#   8.  Delete CephFS StorageClasses (file storage is not exposed to tenants)
#   9.  Delete unwanted ODF-created StorageClasses (ceph-rbd / ceph-rgw)
#   Placement: Placement + PlacementBinding selecting ManagedClusters labeled tenant=<tenant>
#
# What the script does:
#   1. Validates prerequisites on ACM Hub (oc CLI, cluster login, ManagedCluster status)
#   2. Detects the OpenShift minor version from ManagedCluster labels to derive the ODF channel
#   3. Ensures the policy namespace and ManagedClusterSetBinding exist
#   4. Applies Stage 1 and labels the ManagedCluster odf-client=true
#   5. If --tenant is given: applies Stage 2 and labels the ManagedCluster tenant=<tenant>
#   6. (Optional) Waits for policy compliance / verifies directly on the spoke
#
# Usage:
#   ./apply-odf-client-policy.sh <CLUSTER_NAME> [OPTIONS]
#
# Options:
#   --cluster <name>             ManagedCluster name on ACM Hub, i.e. the target spoke cluster (can also be 1st argument)
#   --tenant <tenant-name>       Tenant identifier (e.g. lnx-tenant1, platform); enables Stage 2
#   --external-config <path>     Path to <tenant>-external-config.json from setup-storage.sh
#                                (default: ./<tenant>-external-config.json or ~/<tenant>-external-config.json)
#   --storageclass-name <name>   StorageClass name (default: <tenant>-rbd-storage, or ceph-rbd if tenant=platform)
#   --pool-name <pool-name>      Ceph RBD pool name (default: <tenant>-rbd-pool)
#   --odf-version <version>      Optional StorageCluster spec.version (e.g. 4.20.0; omitted if unset)
#   --namespace <ns>             ACM policy namespace on Hub (default: acm-service-broker)
#   --channel <channel>          ODF operator channel (default: auto-detected, e.g. stable-4.20)
#   --source <catalog-source>    CatalogSource for subscription (default: redhat-operators)
#   --source-namespace <ns>      CatalogSource namespace (default: openshift-marketplace)
#   --wait                       Wait and poll for policy compliance
#   --timeout <sec>              Timeout in seconds per policy when --wait is specified (default: 300)
#   --spoke-kubeconfig <path>    Optional kubeconfig for the spoke cluster to verify directly
#   --dry-run                    Preview generated manifests without applying
#   -h, --help                   Show this help and exit
#
# Note: <CLUSTER_NAME> is the ManagedCluster name on the ACM Hub (the target spoke
# cluster, see 'oc get managedcluster'). --tenant is the tenant ID that owns the
# storage; it is not a cluster name.
#
# Examples:
#   # Install the ODF operator only (no --tenant given):
#   ./apply-odf-client-policy.sh claas-api-ocpz-cp4d4-std-tt-testing
#
#   # Install the ODF operator and configure storage for tenant lnx-tenant1
#   # on ManagedCluster claas-api-ocpz-cp4d4-std-tt-testing:
#   ./apply-odf-client-policy.sh claas-api-ocpz-cp4d4-std-tt-testing \
#       --tenant lnx-tenant1 \
#       --external-config ./lnx-tenant1-external-config.json \
#       --wait

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
TENANT_NAME=""
EXTERNAL_CONFIG_PATH=""
STORAGECLASS_NAME=""
POOL_NAME=""
ODF_VERSION=""
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
    --cluster)            CLUSTER_NAME="${2:?'--cluster requires a value'}"; shift 2 ;;
    --tenant)             TENANT_NAME="${2:?'--tenant requires a value'}"; shift 2 ;;
    --external-config)    EXTERNAL_CONFIG_PATH="${2:?'--external-config requires a path'}"; shift 2 ;;
    --storageclass-name)  STORAGECLASS_NAME="${2:?'--storageclass-name requires a value'}"; shift 2 ;;
    --pool-name)          POOL_NAME="${2:?'--pool-name requires a value'}"; shift 2 ;;
    --odf-version)        ODF_VERSION="${2:?'--odf-version requires a value'}"; shift 2 ;;
    --namespace)          POLICY_NAMESPACE="${2:?'--namespace requires a value'}"; shift 2 ;;
    --channel)            OCP_CHANNEL="${2:?'--channel requires a value'}"; shift 2 ;;
    --source)             CATALOG_SOURCE="${2:?'--source requires a value'}"; shift 2 ;;
    --source-namespace)   CATALOG_SOURCE_NS="${2:?'--source-namespace requires a value'}"; shift 2 ;;
    --wait)               WAIT_FOR_COMPLIANCE=true; shift 1 ;;
    --timeout)            WAIT_TIMEOUT="${2:?'--timeout requires a value'}"; shift 2 ;;
    --spoke-kubeconfig)   SPOKE_KUBECONFIG="${2:?'--spoke-kubeconfig requires a value'}"; shift 2 ;;
    --dry-run)            DRY_RUN=true; shift 1 ;;
    -h|--help)            usage ;;
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

if [[ -n "$EXTERNAL_CONFIG_PATH" && -z "$TENANT_NAME" ]]; then
  log_err "--external-config requires --tenant."
  exit 1
fi

if [[ -n "$TENANT_NAME" ]]; then
  # Auto-locate external config if not passed
  if [[ -z "$EXTERNAL_CONFIG_PATH" ]]; then
    if [[ -f "${TENANT_NAME}-external-config.json" ]]; then
      EXTERNAL_CONFIG_PATH="${TENANT_NAME}-external-config.json"
      log_info "Auto-detected external config file: ${EXTERNAL_CONFIG_PATH}"
    elif [[ -f "${HOME}/${TENANT_NAME}-external-config.json" ]]; then
      EXTERNAL_CONFIG_PATH="${HOME}/${TENANT_NAME}-external-config.json"
      log_info "Auto-detected external config file: ${EXTERNAL_CONFIG_PATH}"
    else
      log_err "No external config found for tenant '${TENANT_NAME}'. Pass --external-config <path> (or place ${TENANT_NAME}-external-config.json in the current dir or \$HOME)."
      exit 1
    fi
  fi
  if [[ ! -f "$EXTERNAL_CONFIG_PATH" ]]; then
    log_err "External config file '${EXTERNAL_CONFIG_PATH}' not found."
    exit 1
  fi

  # Derive default pool and storageclass names
  [[ -z "$POOL_NAME" ]] && POOL_NAME="${TENANT_NAME}-rbd-pool"
  if [[ -z "$STORAGECLASS_NAME" ]]; then
    if [[ "$TENANT_NAME" == "platform" ]]; then
      STORAGECLASS_NAME="ceph-rbd"
    else
      STORAGECLASS_NAME="${TENANT_NAME}-rbd-storage"
    fi
  fi
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
    OCP_CHANNEL="stable-4.20"
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
# STAGE 1: ODF Operator Install Policy
# ---------------------------------------------------------------------------
log_step "4" "STAGE 1: Applying ODF operator install policy"

INSTALL_POLICY_NAME="install-odf-client"
INSTALL_PLACEMENT_RULE="placement-odf-tenant-${CLUSTER_NAME}"
INSTALL_PLACEMENT_BINDING="binding-install-odf-${CLUSTER_NAME}"

INSTALL_MANIFEST=$(cat <<EOF
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: ${INSTALL_POLICY_NAME}
  namespace: ${POLICY_NAMESPACE}
  annotations:
    policy.open-cluster-management.io/standards: NIST SP 800-53
    policy.open-cluster-management.io/categories: CM Configuration Management
    policy.open-cluster-management.io/controls: CM-2 Baseline Configuration
spec:
  remediationAction: enforce
  disabled: false
  policy-templates:
    # -- 1. Namespace ---------------------------------------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: odf-namespace
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
    # -- 2. OperatorGroup -----------------------------------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: odf-operatorgroup
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
    # -- 3. Subscription ------------------------------------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: odf-subscription
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
    # -- 4. CSV Status Verification -------------------------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: odf-csv-status
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
  name: ${INSTALL_PLACEMENT_RULE}
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
  name: ${INSTALL_PLACEMENT_BINDING}
  namespace: ${POLICY_NAMESPACE}
placementRef:
  name: ${INSTALL_PLACEMENT_RULE}
  kind: PlacementRule
  apiGroup: apps.open-cluster-management.io
subjects:
  - name: ${INSTALL_POLICY_NAME}
    kind: Policy
    apiGroup: policy.open-cluster-management.io
EOF
)

if [[ "$DRY_RUN" == "true" ]]; then
  echo "-------------------- STAGE 1 MANIFEST PREVIEW --------------------"
  echo "$INSTALL_MANIFEST"
  echo "------------------------------------------------------------------"
else
  log_info "Applying ODF install Policy, PlacementRule, and PlacementBinding..."
  echo "$INSTALL_MANIFEST" | oc apply -f -
  log_ok "Stage 1: ODF install Policy applied in namespace '${POLICY_NAMESPACE}'"
  oc label managedcluster "${CLUSTER_NAME}" odf-client=true --overwrite
  log_ok "Labeled ManagedCluster '${CLUSTER_NAME}' with odf-client=true"
fi

# ---------------------------------------------------------------------------
# STAGE 2: Tenant ODF Configure Policy
# ---------------------------------------------------------------------------
CONFIG_POLICY_NAME=""
if [[ -n "$TENANT_NAME" ]]; then
  log_step "5" "STAGE 2: Applying tenant storage configuration policy for '${TENANT_NAME}'"

  log_info "Reading external config: ${EXTERNAL_CONFIG_PATH}"
  CONFIG_BASE64=$(base64 < "$EXTERNAL_CONFIG_PATH" | tr -d '\n')

  CONFIG_POLICY_NAME="${TENANT_NAME}-odf-client-config"
  CONFIG_PLACEMENT="${TENANT_NAME}-odf-client-placement"
  CONFIG_PLACEMENT_BINDING="${TENANT_NAME}-odf-client-config-binding"

  # Optional spec.version line for the StorageCluster (only when --odf-version is given)
  STORAGECLUSTER_VERSION_LINE=""
  [[ -n "$ODF_VERSION" ]] && STORAGECLUSTER_VERSION_LINE="                  version: ${ODF_VERSION}"

  CONFIG_MANIFEST=$(cat <<EOF
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: ${CONFIG_POLICY_NAME}
  namespace: ${POLICY_NAMESPACE}
  annotations:
    policy.open-cluster-management.io/description: "Configure ODF external storage for ${TENANT_NAME} - Block storage only (NO file storage)"
    policy.open-cluster-management.io/standards: "NIST SP 800-53"
    policy.open-cluster-management.io/categories: "CM Configuration Management"
    policy.open-cluster-management.io/controls: "CM-2 Baseline Configuration"
spec:
  disabled: false
  remediationAction: enforce
  policy-templates:
    # -- 1. External Cluster Credentials Secret (RBD only, no CephFS) ---------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: ${TENANT_NAME}-external-cluster-secret
        spec:
          remediationAction: enforce
          severity: high
          namespaceSelector:
            include:
              - openshift-storage
          object-templates:
            - complianceType: musthave
              metadataComplianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Secret
                metadata:
                  name: rook-ceph-external-cluster-details
                  namespace: openshift-storage
                  labels:
                    tenant: ${TENANT_NAME}
                type: Opaque
                data:
                  external_cluster_details: ${CONFIG_BASE64}
    # -- 2. StorageCluster in External Mode (block only) ----------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: ${TENANT_NAME}-storage-cluster
        spec:
          remediationAction: enforce
          severity: high
          namespaceSelector:
            include:
              - openshift-storage
          object-templates:
            - complianceType: musthave
              metadataComplianceType: musthave
              objectDefinition:
                apiVersion: ocs.openshift.io/v1
                kind: StorageCluster
                metadata:
                  name: ocs-external-storagecluster
                  namespace: openshift-storage
                  labels:
                    tenant: ${TENANT_NAME}
                  annotations:
                    uninstall.ocs.openshift.io/cleanup-policy: delete
                    uninstall.ocs.openshift.io/mode: graceful
                spec:
                  arbiter: {}
                  encryption:
                    keyRotation:
                      schedule: '@weekly'
                    kms: {}
                  externalStorage:
                    enable: true
                  labelSelector: {}
                  multiCloudGateway:
                    reconcileStrategy: ignore
                  managedResources:
                    cephBlockPools:
                      defaultStorageClass: false
                      reconcileStrategy: manage
                    cephCluster:
                      reconcileStrategy: ignore
                    cephConfig:
                      reconcileStrategy: manage
                    cephDashboard:
                      reconcileStrategy: manage
                    cephFilesystems:
                      reconcileStrategy: ignore
                    cephNonResilientPools:
                      reconcileStrategy: manage
                    cephObjectStoreUsers:
                      reconcileStrategy: ignore
                    cephObjectStores:
                      reconcileStrategy: ignore
                    cephRBDMirror:
                      reconcileStrategy: manage
                    cephToolbox:
                      reconcileStrategy: manage
                    snapshotClasses:
                      reconcileStrategy: manage
                    storageClasses:
                      reconcileStrategy: ignore
                  network:
                    multiClusterService: {}
${STORAGECLUSTER_VERSION_LINE}
    # -- 3. RBD CSI Driver ----------------------------------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: ${TENANT_NAME}-rbd-csi-driver
        spec:
          remediationAction: enforce
          severity: high
          namespaceSelector:
            include:
              - openshift-storage
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: csi.ceph.io/v1
                kind: Driver
                metadata:
                  name: rbd.csi.ceph.com
                  namespace: openshift-storage
                spec:
                  attachRequired: true
                  fsGroupPolicy: File
                  clusterName: openshift-storage
    # -- 4. Verify StorageCluster Ready ---------------------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: ${TENANT_NAME}-storage-cluster-status
        spec:
          remediationAction: inform
          severity: high
          namespaceSelector:
            include:
              - openshift-storage
          object-templates:
            - complianceType: musthave
              metadataComplianceType: musthave
              objectDefinition:
                apiVersion: ocs.openshift.io/v1
                kind: StorageCluster
                metadata:
                  name: ocs-external-storagecluster
                  namespace: openshift-storage
                status:
                  phase: Ready
    # -- 5. Ensure External Storage Enabled (ACM merge workaround) ------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: ${TENANT_NAME}-ensure-external-storage-enabled
        spec:
          remediationAction: enforce
          severity: high
          namespaceSelector:
            include:
              - openshift-storage
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: ocs.openshift.io/v1
                kind: StorageCluster
                metadata:
                  name: ocs-external-storagecluster
                  namespace: openshift-storage
                spec:
                  externalStorage:
                    enable: true
    # -- 6. Disable NooBaa Operator -------------------------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: ${TENANT_NAME}-disable-noobaa
        spec:
          remediationAction: enforce
          severity: low
          namespaceSelector:
            include:
              - openshift-storage
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: apps/v1
                kind: Deployment
                metadata:
                  name: noobaa-operator
                  namespace: openshift-storage
                spec:
                  replicas: 0
    # -- 6a. Verify CSI Secrets Exist (dependency check) ----------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: ${TENANT_NAME}-verify-csi-secrets
        spec:
          remediationAction: inform
          severity: high
          namespaceSelector:
            include:
              - openshift-storage
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Secret
                metadata:
                  name: rook-csi-rbd-provisioner-${TENANT_NAME}-${POOL_NAME}
                  namespace: openshift-storage
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Secret
                metadata:
                  name: rook-csi-rbd-node-${TENANT_NAME}-${POOL_NAME}
                  namespace: openshift-storage
    # -- 7. Tenant RBD StorageClass (block storage) ---------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: ${TENANT_NAME}-create-rbd-storageclass
        spec:
          remediationAction: enforce
          severity: high
          namespaceSelector:
            exclude:
              - kube-*
            include:
              - '*'
          object-templates:
            # Prerequisite check: CSI secrets must exist
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Secret
                metadata:
                  name: rook-csi-rbd-provisioner-${TENANT_NAME}-${POOL_NAME}
                  namespace: openshift-storage
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Secret
                metadata:
                  name: rook-csi-rbd-node-${TENANT_NAME}-${POOL_NAME}
                  namespace: openshift-storage
            # The StorageClass itself
            - complianceType: musthave
              metadataComplianceType: musthave
              objectDefinition:
                apiVersion: storage.k8s.io/v1
                kind: StorageClass
                metadata:
                  name: ${STORAGECLASS_NAME}
                  labels:
                    tenant: ${TENANT_NAME}
                    storage-type: block
                  annotations:
                    description: "Tenant-scoped RBD block storage for ${TENANT_NAME}"
                provisioner: rbd.csi.ceph.com
                parameters:
                  clusterID: openshift-storage
                  pool: ${POOL_NAME}
                  imageFeatures: layering
                  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner-${TENANT_NAME}-${POOL_NAME}
                  csi.storage.k8s.io/provisioner-secret-namespace: openshift-storage
                  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner-${TENANT_NAME}-${POOL_NAME}
                  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-storage
                  csi.storage.k8s.io/controller-publish-secret-name: rook-csi-rbd-node-${TENANT_NAME}-${POOL_NAME}
                  csi.storage.k8s.io/controller-publish-secret-namespace: openshift-storage
                  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node-${TENANT_NAME}-${POOL_NAME}
                  csi.storage.k8s.io/node-stage-secret-namespace: openshift-storage
                  csi.storage.k8s.io/fstype: ext4
                reclaimPolicy: Delete
                allowVolumeExpansion: true
                volumeBindingMode: Immediate
    # -- 8. Delete CephFS StorageClasses (security enforcement) ---------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: ${TENANT_NAME}-delete-cephfs-storageclass
        spec:
          remediationAction: enforce
          severity: high
          namespaceSelector:
            exclude:
              - kube-*
            include:
              - '*'
          object-templates:
            - complianceType: mustnothave
              objectDefinition:
                apiVersion: storage.k8s.io/v1
                kind: StorageClass
                metadata:
                  name: ocs-external-storagecluster-cephfs
            - complianceType: mustnothave
              objectDefinition:
                apiVersion: storage.k8s.io/v1
                kind: StorageClass
                metadata:
                  name: ${TENANT_NAME}-cephfs-storage
    # -- 9. Remove unwanted ODF-created StorageClasses ------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: ${TENANT_NAME}-block-unwanted-odf-storageclasses
        spec:
          remediationAction: enforce
          severity: high
          namespaceSelector:
            exclude:
              - kube-*
            include:
              - '*'
          object-templates:
            - complianceType: mustnothave
              objectDefinition:
                apiVersion: storage.k8s.io/v1
                kind: StorageClass
                metadata:
                  name: ocs-external-storagecluster-ceph-rbd
            - complianceType: mustnothave
              objectDefinition:
                apiVersion: storage.k8s.io/v1
                kind: StorageClass
                metadata:
                  name: ocs-external-storagecluster-ceph-rgw
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: ${CONFIG_PLACEMENT_BINDING}
  namespace: ${POLICY_NAMESPACE}
placementRef:
  name: ${CONFIG_PLACEMENT}
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
subjects:
  - name: ${CONFIG_POLICY_NAME}
    apiGroup: policy.open-cluster-management.io
    kind: Policy
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: ${CONFIG_PLACEMENT}
  namespace: ${POLICY_NAMESPACE}
spec:
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchExpressions:
            - key: tenant
              operator: In
              values:
                - ${TENANT_NAME}
EOF
)

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "-------------------- STAGE 2 MANIFEST PREVIEW --------------------"
    echo "$CONFIG_MANIFEST"
    echo "------------------------------------------------------------------"
  else
    log_info "Applying tenant ODF configuration Policy, Placement, and PlacementBinding..."
    echo "$CONFIG_MANIFEST" | oc apply -f -
    log_ok "Stage 2: Tenant ODF configuration Policy applied"
    oc label managedcluster "${CLUSTER_NAME}" tenant="${TENANT_NAME}" --overwrite
    log_ok "Labeled ManagedCluster '${CLUSTER_NAME}' with tenant=${TENANT_NAME}"
  fi
else
  log_info "Stage 2 skipped: no --tenant provided. Run with --tenant <name> [--external-config <file>] to configure tenant storage."
fi

# ---------------------------------------------------------------------------
# Verify Placement & Policy Propagation
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" != "true" ]]; then
  log_step "6" "Verifying policy placement and propagation"

  sleep 3
  DECISIONS=$(oc get placementrule "${INSTALL_PLACEMENT_RULE}" -n "${POLICY_NAMESPACE}" -o jsonpath='{.status.decisions[*].clusterName}' 2>/dev/null || echo "")
  if [[ "$DECISIONS" =~ (^|[[:space:]])"${CLUSTER_NAME}"($|[[:space:]]) ]]; then
    log_ok "PlacementRule '${INSTALL_PLACEMENT_RULE}' selected cluster '${CLUSTER_NAME}'"
  else
    log_warn "Cluster '${CLUSTER_NAME}' not yet visible in PlacementRule decisions (found: '${DECISIONS:-none}')."
    log_warn "ACM controller will update decisions in a few seconds."
  fi

  if [[ -n "$TENANT_NAME" ]]; then
    TENANT_DECISIONS=$(oc get placementdecision -n "${POLICY_NAMESPACE}" \
      -l cluster.open-cluster-management.io/placement="${CONFIG_PLACEMENT}" \
      -o jsonpath='{.items[*].status.decisions[*].clusterName}' 2>/dev/null || echo "")
    if [[ "$TENANT_DECISIONS" =~ (^|[[:space:]])"${CLUSTER_NAME}"($|[[:space:]]) ]]; then
      log_ok "Placement '${CONFIG_PLACEMENT}' selected cluster '${CLUSTER_NAME}'"
    else
      log_warn "Cluster '${CLUSTER_NAME}' not yet visible in Placement '${CONFIG_PLACEMENT}' decisions (found: '${TENANT_DECISIONS:-none}')."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Optional: Wait / Verification Loop
# ---------------------------------------------------------------------------
if [[ "$WAIT_FOR_COMPLIANCE" == "true" && "$DRY_RUN" != "true" ]]; then
  log_step "7" "Waiting for policy compliance (timeout: ${WAIT_TIMEOUT}s per policy)"

  POLL_INTERVAL=10
  POLICIES_TO_CHECK=("${INSTALL_POLICY_NAME}")
  [[ -n "${CONFIG_POLICY_NAME}" ]] && POLICIES_TO_CHECK+=("${CONFIG_POLICY_NAME}")

  for POL in "${POLICIES_TO_CHECK[@]}"; do
    log_info "Polling compliance for Policy '${POL}'..."
    COMPLIANT=false
    STATUS=""
    ELAPSED=0
    while [[ $ELAPSED -lt $WAIT_TIMEOUT ]]; do
      STATUS=$(oc get policy "${POL}" -n "${POLICY_NAMESPACE}" -o jsonpath='{.status.status[?(@.clustername=="'"${CLUSTER_NAME}"'")].compliant}' 2>/dev/null || echo "")
      if [[ "$STATUS" == "Compliant" ]]; then
        log_ok "Policy '${POL}' is Compliant on cluster '${CLUSTER_NAME}'!"
        COMPLIANT=true
        break
      fi
      echo -n "."
      sleep $POLL_INTERVAL
      ELAPSED=$((ELAPSED + POLL_INTERVAL))
    done
    echo ""
    if [[ "$COMPLIANT" != "true" ]]; then
      log_warn "Timed out waiting for Policy '${POL}'. Current status: ${STATUS:-Pending/NonCompliant}"
      log_info "  oc get policy ${POL} -n ${POLICY_NAMESPACE}"
    fi
  done

  # If spoke kubeconfig was provided, check directly on the spoke cluster
  if [[ -n "$SPOKE_KUBECONFIG" && -f "$SPOKE_KUBECONFIG" ]]; then
    log_info "Checking ODF operator CSV on spoke cluster..."
    CSV_LINE=$(oc --kubeconfig="$SPOKE_KUBECONFIG" get csv -n openshift-storage --no-headers 2>/dev/null | grep "odf-operator" || true)
    if [[ -n "$CSV_LINE" ]]; then
      log_ok "Spoke CSV: ${CSV_LINE}"
    else
      log_warn "odf-operator CSV not found yet on spoke cluster"
    fi
    if [[ -n "$TENANT_NAME" ]]; then
      if oc --kubeconfig="$SPOKE_KUBECONFIG" get storageclass "${STORAGECLASS_NAME}" &>/dev/null; then
        log_ok "Spoke StorageClass '${STORAGECLASS_NAME}' exists"
      else
        log_warn "Spoke StorageClass '${STORAGECLASS_NAME}' not found yet"
      fi
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
echo "  Stage 1 (Install)  : ${INSTALL_POLICY_NAME} (channel ${OCP_CHANNEL})"
if [[ -n "$TENANT_NAME" ]]; then
  echo "  Stage 2 (Config)   : ${CONFIG_POLICY_NAME}"
  echo "  Tenant Name        : ${TENANT_NAME}"
  echo "  StorageClass       : ${STORAGECLASS_NAME}"
  echo "  RBD Pool           : ${POOL_NAME}"
fi
echo "=========================================================================="
echo ""
echo "Verification commands (from ACM Hub):"
echo "  oc get policy -n ${POLICY_NAMESPACE}"
echo "  oc get policy -n ${CLUSTER_NAME}"
echo "  oc get placementrule ${INSTALL_PLACEMENT_RULE} -n ${POLICY_NAMESPACE}"
echo ""
echo "Verification commands (from Tenant Cluster):"
echo "  oc get csv -n openshift-storage"
echo "  oc get pods -n openshift-storage"
echo "  oc get storagecluster -n openshift-storage"
echo "  oc get sc"
echo "=========================================================================="
