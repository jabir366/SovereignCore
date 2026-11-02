#!/usr/bin/env bash
# =============================================================================
# upload.sh — Upload the bootc-built qcow2 to OCP as a CDI DataVolume source PVC
# =============================================================================
#
# Run this script on lpar3 (b39-cp4d3.pok.stglabs.ibm.com) as root,
# after build.sh has produced the qcow2.
#
# Version
# ───────
# PVC_NAME defaults to mongodb-ea-disk-<IMAGE_TAG> so every build version
# gets its own PVC and nothing is silently overwritten.
# IMAGE_TAG is read from the VERSION file next to this script.
#
# What it does
# ─────────────
#   Step 1  Validate prerequisites (oc, virtctl, oc login)
#   Step 2  Ensure target namespace exists
#   Step 3  Discover CDI upload proxy URL from the cluster
#   Step 4  virtctl image-upload → PVC  (mongodb-ea-disk-<tag> in namespace)
#   Step 5  Print the values override needed for the Helm chart
#
# Usage
# ─────
#   # Minimal — uploads the latest qcow2 and creates a versioned PVC
#   ./upload.sh
#
#   # Explicit qcow2 path
#   ./upload.sh --qcow2 /data/securedimage/output/qcow2/rhel9-mongodb-ea-8.3.10-s390x.qcow2
#
#   # Override cluster / namespace / PVC name
#   NAMESPACE=mongodb-vm-images PVC_NAME=mongodb-ea-disk ./upload.sh
#
# Environment variables (all optional — defaults shown)
# ──────────────────────────────────────────────────────
#   IMAGE_TAG         read from VERSION file (e.g. 8.3.10)
#   QCOW2_PATH        auto-detected from OUTPUT_DIR (latest *.qcow2)
#   OUTPUT_DIR        /data/securedimage/output/qcow2
#   NAMESPACE         mongodb-vm-test
#   PVC_NAME          mongodb-ea-disk-<IMAGE_TAG>   (versioned — auto)
#   DISK_SIZE         25Gi        (CDI DataVolume capacity)
#   STORAGE_CLASS     ocs-storagecluster-ceph-rbd-virtualization
#   UPLOAD_PROXY_URL  auto-detected via oc get route -n cdi
#   INSECURE          true        (set false if CDI proxy has a trusted cert)
#   FORCE_BIND        true        (immediately bind the PVC — needed for CDI import)
# =============================================================================

set -euo pipefail

# ── Parse --qcow2 flag ───────────────────────────────────────────────────────
QCOW2_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --qcow2) QCOW2_ARG="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Resolve IMAGE_TAG from VERSION file (allow env override) ─────────────────
SCRIPT_DIR_UPLOAD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VERSION_FILE_UPLOAD="${SCRIPT_DIR_UPLOAD}/VERSION"
if [ -z "${IMAGE_TAG:-}" ]; then
  if [ -f "${_VERSION_FILE_UPLOAD}" ]; then
    IMAGE_TAG="$(tr -d '[:space:]' < "${_VERSION_FILE_UPLOAD}")"
  else
    IMAGE_TAG="unknown"
  fi
fi

# ── Configurable defaults ────────────────────────────────────────────────────
OUTPUT_DIR="${OUTPUT_DIR:-/data/securedimage/output/qcow2}"
NAMESPACE="${NAMESPACE:-mongodb-vm-test}"
# PVC name is versioned: each IMAGE_TAG gets its own PVC so old disks are
# preserved until explicitly deleted.  Override with PVC_NAME=... if needed.
PVC_NAME="${PVC_NAME:-mongodb-ea-disk-${IMAGE_TAG}}"
DISK_SIZE="${DISK_SIZE:-25Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd-virtualization}"
# CDI uploadproxy is in openshift-cnv on this cluster (ocpz-standard-1)
UPLOAD_PROXY_URL="${UPLOAD_PROXY_URL:-https://cdi-uploadproxy-openshift-cnv.apps.ocpz-standard-1.tt.testing}"
INSECURE="${INSECURE:-true}"
FORCE_BIND="${FORCE_BIND:-true}"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[upload]${NC} $*"; }
ok()    { echo -e "${GREEN}[upload] ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}[upload] ⚠${NC} $*"; }
error() { echo -e "${RED}[upload] ✗${NC} $*" >&2; exit 1; }

# =============================================================================
# STEP 1 — Prerequisites
# =============================================================================
info "=== Step 1: Validating prerequisites ==="

# oc CLI
if ! command -v oc &>/dev/null; then
  error "oc not found. Install the OpenShift CLI and add it to PATH."
fi
ok "oc: $(oc version --client 2>/dev/null | head -1)"

# virtctl
if ! command -v virtctl &>/dev/null; then
  error "virtctl not found. Extract from OCP release: oc adm release extract --tools --to=/usr/local/bin"
fi
ok "virtctl: $(virtctl version --client 2>/dev/null | grep GitVersion | head -1)"

# oc must be logged in
if ! oc whoami &>/dev/null; then
  error "Not logged in to OpenShift. Run: oc login <cluster-api-url> -u <user> -p <pass>"
fi
OC_USER=$(oc whoami)
OC_SERVER=$(oc whoami --show-server)
ok "oc logged in as: ${OC_USER} → ${OC_SERVER}"

# Resolve qcow2 path
if [ -n "${QCOW2_ARG}" ]; then
  QCOW2_PATH="${QCOW2_ARG}"
else
  # Auto-detect latest *.qcow2 in OUTPUT_DIR
  QCOW2_PATH=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "*.qcow2" | sort | tail -1)
  if [ -z "${QCOW2_PATH}" ]; then
    error "No qcow2 found in ${OUTPUT_DIR}. Run build.sh first, or pass --qcow2 <path>."
  fi
fi

if [ ! -f "${QCOW2_PATH}" ]; then
  error "qcow2 not found: ${QCOW2_PATH}"
fi

QCOW2_SIZE=$(du -sh "${QCOW2_PATH}" | awk '{print $1}')
ok "qcow2: ${QCOW2_PATH} (${QCOW2_SIZE})"

# =============================================================================
# STEP 2 — Ensure target namespace exists
# =============================================================================
info ""
info "=== Step 2: Ensuring namespace '${NAMESPACE}' exists ==="

if oc get namespace "${NAMESPACE}" &>/dev/null; then
  ok "Namespace ${NAMESPACE} already exists"
else
  info "Creating namespace ${NAMESPACE} ..."
  oc create namespace "${NAMESPACE}"
  ok "Namespace ${NAMESPACE} created"
fi

# =============================================================================
# STEP 3 — Discover CDI upload proxy URL
# =============================================================================
info ""
info "=== Step 3: Discovering CDI upload proxy URL ==="

if [ -z "${UPLOAD_PROXY_URL}" ]; then
  # Try the CDI uploadproxy route (created by CDI operator)
  UPLOAD_PROXY_URL=$(oc get route cdi-uploadproxy -n cdi \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)

  if [ -z "${UPLOAD_PROXY_URL}" ]; then
    # Fallback: try openshift-cnv namespace (OCP Virt bundle)
    UPLOAD_PROXY_URL=$(oc get route cdi-uploadproxy -n openshift-cnv \
      -o jsonpath='{.spec.host}' 2>/dev/null || true)
  fi

  if [ -z "${UPLOAD_PROXY_URL}" ]; then
    error "Could not auto-detect CDI upload proxy URL.
Set it manually: UPLOAD_PROXY_URL=https://cdi-uploadproxy-<cluster>.apps.<domain> ./upload.sh"
  fi

  # Prepend https:// if not already present
  [[ "${UPLOAD_PROXY_URL}" == https://* ]] || UPLOAD_PROXY_URL="https://${UPLOAD_PROXY_URL}"
fi
ok "CDI upload proxy: ${UPLOAD_PROXY_URL}"

# =============================================================================
# STEP 4 — virtctl image-upload
# =============================================================================
info ""
info "=== Step 4: Uploading qcow2 to PVC ==="
info "  Namespace     : ${NAMESPACE}"
info "  PVC name      : ${PVC_NAME}"
info "  PVC size      : ${DISK_SIZE}"
info "  Storage class : ${STORAGE_CLASS}"
info "  Upload proxy  : ${UPLOAD_PROXY_URL}"

# Warn if PVC already exists — virtctl will overwrite it
if oc get pvc "${PVC_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  warn "PVC ${PVC_NAME} already exists in ${NAMESPACE} — it will be overwritten."
fi

# Build virtctl flags
VIRTCTL_FLAGS=(
  --image-path="${QCOW2_PATH}"
  --pvc-name="${PVC_NAME}"
  --pvc-size="${DISK_SIZE}"
  --storage-class="${STORAGE_CLASS}"
  --uploadproxy-url="${UPLOAD_PROXY_URL}"
  --namespace="${NAMESPACE}"
)
[ "${FORCE_BIND}" = "true" ] && VIRTCTL_FLAGS+=(--force-bind)
[ "${INSECURE}"   = "true" ] && VIRTCTL_FLAGS+=(--insecure)

virtctl image-upload "${VIRTCTL_FLAGS[@]}" \
|| error "virtctl image-upload failed"

ok "Upload complete: PVC ${PVC_NAME} in namespace ${NAMESPACE}"

# Verify PVC is Bound
info "Waiting for PVC ${PVC_NAME} to be Bound..."
for i in $(seq 1 30); do
  PVC_PHASE=$(oc get pvc "${PVC_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [ "${PVC_PHASE}" = "Succeeded" ] || [ "${PVC_PHASE}" = "Bound" ]; then
    ok "PVC ${PVC_NAME} is ${PVC_PHASE}"
    break
  fi
  echo "  PVC phase: ${PVC_PHASE} (${i}/30) — waiting..."
  sleep 5
done

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} Upload complete${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  PVC ready: ${PVC_NAME} / ${NAMESPACE}"
echo ""
echo "  Use this in Helm values (services/mongodb-vm/v1/chart/values.yaml):"
echo ""
echo "    diskImage:"
echo "      sourcePVCName:      ${PVC_NAME}"
echo "      sourcePVCNamespace: ${NAMESPACE}"
echo ""
echo "  Or as a helm --set override:"
echo "    --set diskImage.sourcePVCName=${PVC_NAME}"
echo "    --set diskImage.sourcePVCNamespace=${NAMESPACE}"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
