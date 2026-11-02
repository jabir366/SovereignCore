#!/usr/bin/env bash
# =============================================================================
# build.sh — bootc image build pipeline (Mode A: Containerfile + BIB → qcow2)
# =============================================================================
#
# Branch: bootc-approach
# Toolchain: podman build (Containerfile) → bootc-image-builder (BIB) → qcow2
#
# Run this script on lpar3 (b39-cp4d3.pok.stglabs.ibm.com) as root.
# Run setup-lpar3.sh once first to bootstrap podman and pull BIB.
#
# Version
# ───────
# IMAGE_TAG is auto-incremented from the VERSION file on every podman build invocation.
# Step 2 (image) and the combined (all) step bump the patch digit in VERSION and write
# the new version back before calling podman build.  Steps 'check' and 'qcow2' do NOT
# modify VERSION.
#
# Override for a one-off run (VERSION is NOT written):
#   IMAGE_TAG=8.4.0 BUILD_STEP=image ./build.sh
#
# Manually set a new base version:
#   make version-bump VERSION_NEW=8.4.0   (from local Mac / CI)
#   # The next build will auto-increment to 8.4.1.
#
# What it does
# ─────────────
#   Step 1  Validate prerequisites (root, s390x, /dev/kvm, disk space,
#           registry.redhat.io auth, BIB image present, COPY sources present)
#   Step 2  podman build → OCI container image (localhost/mongodb-ea-bootc:<tag>)
#           Containerfile applies:
#             • DISA STIG for RHEL 9 (oscap --remediate profile_stig)
#             • FIPS 140-3 (fips-mode-setup --enable + update-crypto-policies FIPS)
#             • MongoDB EA packages, first-boot scripts, systemd unit, cloud-init
#   Step 3  bootc-image-builder → qcow2 disk image
#   Step 4  (default) Wrap qcow2 as ContainerDisk OCI image + push to registry
#   Step 4b (optional) Also push the raw bootc OCI build image to registry
#   Step 5  (optional) Upload qcow2 directly to OCP as a CDI DataVolume PVC
#
# Usage
# ─────
#   ./build.sh
#   IMAGE_TAG=8.4.0 OUTPUT_DIR=/mnt/build ./build.sh
#   PUSH_CONTAINERDISK=true REGISTRY=my-registry.example.com ./build.sh
#   PUSH_OCI=true REGISTRY=my-registry.example.com ./build.sh
#   PUSH_PVC=true ./build.sh            # upload qcow2 to OCP PVC via upload.sh
#   SKIP_BUILD=true ./build.sh          # reuse cached OCI image, re-run BIB only
#
# Environment variables (all optional — defaults shown)
# ──────────────────────────────────────────────────────
#   IMAGE_TAG            auto-incremented from VERSION on every build-image run;
#                        override by setting IMAGE_TAG=x.y.z in the environment
#                        (VERSION file is NOT modified when overriding)
#   IMAGE_NAME           mongodb-ea-bootc
#   REGISTRY             ""         required for ContainerDisk / OCI push
#   REGISTRY_NAMESPACE   byop
#   OUTPUT_DIR           /data/securedimage/output
#   BIB_IMAGE            registry.redhat.io/rhel9/bootc-image-builder:latest
#   PUSH_CONTAINERDISK   true       Step 4  — ContainerDisk push (always on by default)
#   PUSH_OCI             true       Step 4b — raw bootc OCI push  (always on by default)
#   PUSH_PVC             false      Step 5  — upload qcow2 to OCP via CDI / virtctl
#                                            set PUSH_PVC=true only when needed
#   SKIP_BUILD           false      reuse cached local OCI image, skip podman build
#   PLATFORM             linux/s390x
#
# PVC-specific env vars (Step 5 — passed through to upload.sh):
#   NAMESPACE            mongodb-vm-test
#   PVC_NAME             mongodb-ea-disk-<IMAGE_TAG>  (auto-versioned)
#   DISK_SIZE            25Gi
#   STORAGE_CLASS        ocs-storagecluster-ceph-rbd-virtualization
#   UPLOAD_PROXY_URL     auto-detected via oc get route -n openshift-cnv
#   INSECURE             true
# =============================================================================
#
# BUILD_STEP (set by Makefile step targets, default: all)
# ────────────────────────────────────────────────────────
#   check   — Step 1 only: validate prerequisites, exit 0 if all OK
#   image   — Step 2 only: podman build → OCI image (skips check + BIB)
#   qcow2   — Step 3 only: BIB → qcow2 (skips check + podman build)
#   all     — Steps 1 + 2 + 3 + 4 + 4b + 5 per PUSH_* flags (default)

set -euo pipefail

# ── Resolve SCRIPT_DIR first (needed for VERSION lookup below) ───────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Version management — auto-increment patch on every build ─────────────────
#
# Strategy
# ────────
# VERSION file contains the LAST SUCCESSFULLY STARTED build version, e.g. "8.3.11".
# Every time a podman build (Steps 2 / image / all) is started, build.sh:
#   1. Reads the current version from VERSION.
#   2. Splits it into MAJOR.MINOR.PATCH components.
#   3. Increments PATCH by 1.
#   4. Writes the new version back to VERSION immediately (before podman build).
#   5. Passes the new version to the Containerfile via --build-arg IMAGE_TAG=<new>.
#
# If the caller passes IMAGE_TAG= explicitly on the environment, that value is
# used as-is and VERSION is NOT modified (caller takes full responsibility for
# the version string).
#
# Build steps that do NOT run podman build (check, qcow2) never modify VERSION.
# This means 'make build-qcow2' can be re-run safely without bumping the version.
#
# VERSION file format: a single line "MAJOR.MINOR.PATCH" where each component
# is a non-negative integer.  Any trailing whitespace is stripped on read.
# Dotted components beyond PATCH (e.g. "8.3.2.11") have the last component
# incremented; all others are preserved unchanged.
#
# Example: "8.3.11" → "8.3.12"; "8.3.2.11" → "8.3.2.12"; "8.4.0" → "8.4.1"
#
_VERSION_FILE="${SCRIPT_DIR}/VERSION"

# _bump_version <version-string>  →  prints the incremented version
_bump_version() {
  local ver="$1"
  # Split on dots into an array
  IFS='.' read -r -a parts <<< "${ver}"
  local last_idx=$(( ${#parts[@]} - 1 ))
  # Increment the last numeric component
  parts[${last_idx}]=$(( parts[${last_idx}] + 1 ))
  # Re-join with dots
  local IFS='.'
  echo "${parts[*]}"
}

# Resolve IMAGE_TAG:
#   - If caller supplied IMAGE_TAG in the environment, use it verbatim.
#   - Otherwise read from VERSION, bump the patch, write back, and use the new value.
_CALLER_SUPPLIED_TAG="${IMAGE_TAG:-}"

if [ -n "${_CALLER_SUPPLIED_TAG}" ]; then
  # Caller override — use as-is, do not write VERSION
  IMAGE_TAG="${_CALLER_SUPPLIED_TAG}"
  echo "[build] Using caller-supplied IMAGE_TAG=${IMAGE_TAG} (VERSION file not modified)."
else
  # Auto-increment path
  if [ -f "${_VERSION_FILE}" ]; then
    _CURRENT_VER="$(tr -d '[:space:]' < "${_VERSION_FILE}")"
    if [ -z "${_CURRENT_VER}" ]; then
      echo "[build] WARNING: VERSION file is empty; defaulting to 0.0.1" >&2
      _CURRENT_VER="0.0.0"
    fi
  else
    echo "[build] WARNING: VERSION file not found at ${_VERSION_FILE}; defaulting to 0.0.1" >&2
    _CURRENT_VER="0.0.0"
  fi

  # Only increment when a build step that runs podman build is active.
  # Steps 'check' and 'qcow2' do not call podman build — do not bump.
  # Build steps that DO call podman build: image, all (default).
  _WILL_BUILD=false
  case "${BUILD_STEP:-all}" in
    image|all) _WILL_BUILD=true ;;
    *) _WILL_BUILD=false ;;
  esac

  if [ "${_WILL_BUILD}" = "true" ]; then
    IMAGE_TAG="$(_bump_version "${_CURRENT_VER}")"
    echo "${IMAGE_TAG}" > "${_VERSION_FILE}"
    echo "[build] Auto-incremented version: ${_CURRENT_VER} → ${IMAGE_TAG}"
    echo "[build] VERSION file updated: ${_VERSION_FILE}"
  else
    # check / qcow2 — use the current version without bumping
    IMAGE_TAG="${_CURRENT_VER}"
    echo "[build] Using current version ${IMAGE_TAG} (no build step → VERSION not modified)."
  fi
fi

# ── Configurable defaults ────────────────────────────────────────────────────
IMAGE_TAG="${IMAGE_TAG}"
IMAGE_NAME="${IMAGE_NAME:-mongodb-ea-bootc}"
REGISTRY="${REGISTRY:-}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-byop}"
OUTPUT_DIR="${OUTPUT_DIR:-/data/securedimage/output}"
BIB_IMAGE="${BIB_IMAGE:-registry.redhat.io/rhel9/bootc-image-builder:latest}"
# Both ContainerDisk and OCI image are pushed by default.
# Set PUSH_CONTAINERDISK=false or PUSH_OCI=false to suppress either.
# Set both to false to produce a local qcow2 only, with no registry push.
PUSH_CONTAINERDISK="${PUSH_CONTAINERDISK:-true}"
PUSH_OCI="${PUSH_OCI:-true}"
# PVC upload is OFF by default — only enable explicitly when needed.
# Set PUSH_PVC=true (or use: make push-pvc) to upload to OCP via virtctl.
PUSH_PVC="${PUSH_PVC:-false}"
SKIP_BUILD="${SKIP_BUILD:-false}"
PLATFORM="${PLATFORM:-linux/s390x}"
BUILD_STEP="${BUILD_STEP:-all}"

LOCAL_IMAGE="localhost/${IMAGE_NAME}:${IMAGE_TAG}"
QCOW2_PATH="${OUTPUT_DIR}/qcow2/disk.qcow2"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[build]${NC} $*"; }
ok()    { echo -e "${GREEN}[build] ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}[build] ⚠${NC} $*"; }
error() { echo -e "${RED}[build] ✗${NC} $*" >&2; exit 1; }

# =============================================================================
# STEP 1 — Prerequisites
# =============================================================================
if [ "${BUILD_STEP}" = "check" ] || [ "${BUILD_STEP}" = "all" ]; then

info "=== Step 1: Validating prerequisites ==="

if [ "$(id -u)" -ne 0 ]; then
  error "Must run as root. Use: sudo ./build.sh"
fi

ARCH=$(uname -m)
if [ "${ARCH}" != "s390x" ]; then
  error "Must run on s390x hardware. Detected: ${ARCH}"
fi
ok "Architecture: ${ARCH}"

if ! command -v podman &>/dev/null; then
  error "podman not found. Install: dnf install -y podman"
fi
ok "Podman: $(podman --version | awk '{print $3}')"

if [ ! -c /dev/kvm ]; then
  error "/dev/kvm not present. KVM is required by bootc-image-builder on s390x."
fi
ok "/dev/kvm present"

if ! podman login --get-login registry.redhat.io &>/dev/null; then
  error "Not logged in to registry.redhat.io. Run: podman login registry.redhat.io"
fi
ok "registry.redhat.io auth: $(podman login --get-login registry.redhat.io 2>/dev/null)"

if ! podman image exists "${BIB_IMAGE}" 2>/dev/null; then
  info "BIB image not found locally — pulling ${BIB_IMAGE} ..."
  podman pull "${BIB_IMAGE}" || error "Failed to pull BIB image: ${BIB_IMAGE}"
fi
ok "BIB image: ${BIB_IMAGE}"

for f in scripts/mongo-first-boot.sh scripts/mongo-rs-init.sh units/mongodb-first-boot.service; do
  if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
    error "Required file missing: ${SCRIPT_DIR}/${f}"
  fi
done
ok "All Containerfile COPY sources present"

mkdir -p "${OUTPUT_DIR}/qcow2"
AVAIL_KB=$(df --output=avail -k "${OUTPUT_DIR}" | tail -1)
AVAIL_GIB=$(( AVAIL_KB / 1024 / 1024 ))
if [ "${AVAIL_GIB}" -lt 10 ]; then
  error "Insufficient disk space in ${OUTPUT_DIR}: ${AVAIL_GIB} GiB free, need at least 10 GiB."
fi
ok "Disk space: ${AVAIL_GIB} GiB free in ${OUTPUT_DIR}"

info "Build configuration:"
info "  Image     : ${LOCAL_IMAGE}"
info "  Platform  : ${PLATFORM}"
info "  BIB image : ${BIB_IMAGE}"
info "  Output    : ${OUTPUT_DIR}"
info "  STIG      : xccdf_org.ssgproject.content_profile_stig (DISA STIG RHEL 9)"
info "  FIPS      : 140-3 (fips-mode-setup + crypto-policies FIPS)"
info "Deploy flags:"
info "  PUSH_CONTAINERDISK : ${PUSH_CONTAINERDISK}  (default deploy path)"
info "  PUSH_OCI           : ${PUSH_OCI}  (push raw bootc OCI build image)"
info "  PUSH_PVC           : ${PUSH_PVC}  (upload qcow2 to OCP PVC)"

if [ "${BUILD_STEP}" = "check" ]; then
  ok "Prerequisites check passed — system is ready to build."
  exit 0
fi

fi  # end BUILD_STEP check/all

# =============================================================================
# STEP 2 — podman build: Containerfile → OCI container image
# =============================================================================
if [ "${BUILD_STEP}" = "image" ] || [ "${BUILD_STEP}" = "all" ]; then

info ""
info "=== Step 2: Building OCI container image ==="
info "  Compliance: DISA STIG RHEL 9 (profile_stig) + FIPS 140-3"

if [ "${SKIP_BUILD}" = "true" ]; then
  if ! podman image exists "${LOCAL_IMAGE}" 2>/dev/null; then
    error "SKIP_BUILD=true but image ${LOCAL_IMAGE} not found locally."
  fi
  warn "SKIP_BUILD=true — reusing cached image ${LOCAL_IMAGE}"
else
  podman build \
    --platform "${PLATFORM}" \
    --tag "${LOCAL_IMAGE}" \
    --build-arg "IMAGE_TAG=${IMAGE_TAG}" \
    --file "${SCRIPT_DIR}/Containerfile" \
    "${SCRIPT_DIR}" \
  || error "podman build failed"
  ok "OCI image built: ${LOCAL_IMAGE}"

  # ── Quay Clair label validation ─────────────────────────────────────────────
  # Verify that the version label was expanded to the concrete version string
  # and not left as the unexpanded ARG sentinel "${IMAGE_TAG}" or "0.0.0".
  # An unexpanded label causes Clair index cache collisions and silent scan
  # failures in Quay — catch it here before the image is ever pushed.
  _BUILT_VERSION="$(podman inspect --format '{{index .Labels "org.opencontainers.image.version"}}' "${LOCAL_IMAGE}" 2>/dev/null || true)"
  if [[ "${_BUILT_VERSION}" == *'${'* ]]; then
    error "LABEL org.opencontainers.image.version was NOT expanded by podman build.
  Got: '${_BUILT_VERSION}'
  Expected: '${IMAGE_TAG}'
  This means --build-arg IMAGE_TAG was not passed or was ignored.
  Quay Clair scanning will be broken if this image is pushed.
  Fix: ensure build.sh is used directly (not a bare 'podman build') or supply --build-arg IMAGE_TAG=${IMAGE_TAG}."
  fi
  if [ "${_BUILT_VERSION}" = "0.0.0" ]; then
    error "LABEL org.opencontainers.image.version is the sentinel '0.0.0'.
  This means IMAGE_TAG was not supplied via --build-arg and the Containerfile
  ARG default was used.  Check that build.sh auto-increment logic ran correctly
  and that the VERSION file at ${_VERSION_FILE} is readable."
  fi
  if [ "${_BUILT_VERSION}" != "${IMAGE_TAG}" ]; then
    warn "LABEL version mismatch: expected '${IMAGE_TAG}', got '${_BUILT_VERSION}'.
  This is unusual — the image was built but the label does not match IMAGE_TAG.
  Verify the image is correct before pushing to Quay."
  else
    ok "Label verified: org.opencontainers.image.version=${_BUILT_VERSION}"
  fi
fi

fi  # end BUILD_STEP image/all

# =============================================================================
# STEP 3 — bootc-image-builder: OCI image → qcow2
# =============================================================================
if [ "${BUILD_STEP}" = "qcow2" ] || [ "${BUILD_STEP}" = "all" ]; then

# For build-qcow2 (standalone), verify the OCI image exists before proceeding.
if [ "${BUILD_STEP}" = "qcow2" ]; then
  if ! podman image exists "${LOCAL_IMAGE}" 2>/dev/null; then
    error "OCI image '${LOCAL_IMAGE}' not found in podman storage.
  Run 'make build-image' first to build it."
  fi
  ok "OCI image found: ${LOCAL_IMAGE}"
fi

# BIB 9.8 strategy: use the default podman storage (/var/lib/containers/storage).
# The image was built by Step 2 as "localhost/mongodb-ea-bootc:<tag>".
#
# BIB 9.8 reference format (verified by direct testing):
#   CORRECT:   "localhost/<name>:<tag>"   — bare image name, no transport prefix
#   WRONG:     "containers-storage:localhost/..."  — BIB rejects the transport prefix
#   WRONG:     "containers-storage:<name>:<tag>"   — podman normalises back to localhost/
#
# BIB 9.8 also removed the --config flag. Disk partitioning (root fs type) is
# now embedded in the bootc image at /usr/lib/bootc/install/10-disk-layout.toml
# (see Containerfile SECTION 9a) — BIB reads it via bootc install print-configuration.

BIB_IMAGE_REF="${LOCAL_IMAGE}"   # bare "localhost/name:tag" — no transport prefix
ok "BIB image reference: ${BIB_IMAGE_REF}"

info ""
info "=== Step 3: Converting OCI image → qcow2 with bootc-image-builder ==="
info "  BIB image : ${BIB_IMAGE}"
info "  Output    : ${OUTPUT_DIR}"
info "  BIB ref   : ${BIB_IMAGE_REF}"
info "  Disk cfg  : embedded in image at /usr/lib/bootc/install/10-disk-layout.toml"

# Clean previous qcow2 output so BIB does not fail on existing files
rm -rf "${OUTPUT_DIR}/qcow2"
mkdir -p "${OUTPUT_DIR}/qcow2"

# Purge any stale podman containers and volumes before launching BIB.
# BIB's internal podman shares /var/lib/containers/storage via bind-mount.
# Stale containers/volumes from previous runs hold DB locks (lock files in
# the overlay store) that BIB's inner podman cannot acquire, causing:
#   "acquiring lock N for container/volume ...: file exists"
# Removing them here releases the locks before BIB starts.
info "  Pruning stale containers/volumes to release storage locks ..."
# shellcheck disable=SC2046
podman rm -f $(podman ps -aq 2>/dev/null) 2>/dev/null || true
podman volume prune -f 2>/dev/null || true

# BIB invocation.
# - /var/lib/containers/storage bind-mounted rw so BIB finds the pre-loaded image
# - /run/containers/storage bind-mounted for the run-time podman DB
# - No --config flag (removed in BIB 9.8; disk layout is embedded in the image)
mkdir -p /run/containers/storage
podman run \
  --rm \
  --privileged \
  -v "${OUTPUT_DIR}:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v /run/containers/storage:/run/containers/storage \
  -v /dev/kvm:/dev/kvm \
  "${BIB_IMAGE}" \
    build \
    --type qcow2 \
    "${BIB_IMAGE_REF}" \
|| error "bootc-image-builder failed"

if [ ! -f "${QCOW2_PATH}" ]; then
  error "Expected qcow2 not found at ${QCOW2_PATH} — check BIB output above."
fi

QCOW2_SIZE=$(du -sh "${QCOW2_PATH}" | awk '{print $1}')
ok "qcow2 produced: ${QCOW2_PATH} (${QCOW2_SIZE})"

VERSIONED_QCOW2="${OUTPUT_DIR}/qcow2/rhel9-mongodb-ea-${IMAGE_TAG}-s390x.qcow2"
mv "${QCOW2_PATH}" "${VERSIONED_QCOW2}"
ok "Renamed → ${VERSIONED_QCOW2}"

fi  # end BUILD_STEP qcow2/all

# =============================================================================
# STEP 4 — Wrap qcow2 as a ContainerDisk OCI image + push  (DEFAULT)
# =============================================================================
# A ContainerDisk is a scratch OCI image containing the qcow2 at /disk/disk.img.
# OCP Virt / CDI uses it directly as a DataVolume source — no PVC upload needed.
#
# This is the default deploy path. Set PUSH_CONTAINERDISK=false to skip.
#
# Tag format: <registry>/<namespace>/<image-name>-containerdisk:<tag>-s390x
# Example:    quay.io/byop/mongodb-ea-bootc-containerdisk:8.3.10-s390x
#
# The "-containerdisk" suffix in the image NAME (not just the tag) makes it
# immediately clear in any registry view that this is a ContainerDisk wrapper,
# not the bootc OCI build image.
#
# NOTE: The ContainerDisk image (FROM scratch + qcow2 blob) has NO RPM database
# and therefore produces no CVE scan result in Quay/Clair — this is expected and
# by design.  Use PUSH_OCI=true to also push the bootc OCI image if you need
# registry-side CVE scanning.

CONTAINERDISK_TAG=""
if [ "${PUSH_CONTAINERDISK}" = "true" ] && \
   { [ "${BUILD_STEP}" = "qcow2" ] || [ "${BUILD_STEP}" = "all" ]; }; then
  if [ -z "${REGISTRY}" ]; then
    error "PUSH_CONTAINERDISK=true but REGISTRY is not set.
  Set it via:  REGISTRY=quay.io/yourorg ./build.sh
  Or via make: make push REGISTRY=quay.io/yourorg"
  fi

  info ""
  info "=== Step 4: Wrapping qcow2 as ContainerDisk and pushing ==="

  # Image name includes "-containerdisk" so registry listings are unambiguous.
  CONTAINERDISK_IMAGE_NAME="${IMAGE_NAME}-containerdisk"
  CONTAINERDISK_TAG="${REGISTRY}/${REGISTRY_NAMESPACE}/${CONTAINERDISK_IMAGE_NAME}:${IMAGE_TAG}-s390x"

  # CDI virt-cdi-importer scans /disk/ for files named "disk.img" or "disk.qcow2".
  # A versioned filename (rhel9-mongodb-ea-8.x.y-s390x.qcow2) is NOT matched.
  # Rename to disk.img (canonical CDI ContainerDisk convention) at ADD time.
  cat > "${OUTPUT_DIR}/Containerfile.disk" <<DISKEOF
FROM scratch
ADD qcow2/rhel9-mongodb-ea-${IMAGE_TAG}-s390x.qcow2 /disk/disk.img
DISKEOF

  podman build \
    --platform "${PLATFORM}" \
    --tag "${CONTAINERDISK_TAG}" \
    --file "${OUTPUT_DIR}/Containerfile.disk" \
    "${OUTPUT_DIR}" \
  || error "ContainerDisk build failed"
  ok "ContainerDisk built: ${CONTAINERDISK_TAG}"

  podman push --format v2s2 --tls-verify=false "${CONTAINERDISK_TAG}" || error "podman push failed for ${CONTAINERDISK_TAG}"
  ok "ContainerDisk pushed: ${CONTAINERDISK_TAG}"
else
  info ""
  info "=== Step 4: Skipped (PUSH_CONTAINERDISK=false or no REGISTRY set) ==="
  info "  To push:  PUSH_CONTAINERDISK=true REGISTRY=quay.io/yourorg ./build.sh"
  info "  Or:       make push REGISTRY=quay.io/yourorg"
  info "  qcow2 is at: ${OUTPUT_DIR}/qcow2/"
fi

# =============================================================================
# STEP 4b — (optional) Push the raw bootc OCI build image
# =============================================================================
# The bootc OCI image (localhost/mongodb-ea-bootc:<tag>) contains the full RPM
# database and is the ONLY image that Quay / Clair / scanners can analyse for
# CVEs.  The ContainerDisk image (FROM scratch + qcow2 blob) has no RPM DB and
# produces no CVE scan — that is expected and by design.
#
# Push the OCI build image when you want:
#   - Registry-side CVE scanning (Quay, Clair, etc.)
#   - Image promotion / signing / SBOM workflows
#   - The image available in the registry for future BIB re-runs without
#     rebuilding from the Containerfile
#
# Tag format: <registry>/<namespace>/<image-name>:<tag>-s390x
# Example:    quay.io/byop/mongodb-ea-bootc:8.3.10-s390x
#
# Enable with: PUSH_OCI=true REGISTRY=quay.io/yourorg ./build.sh
# Or via make: make push-oci REGISTRY=quay.io/yourorg

OCI_PUSH_TAG=""
if [ "${PUSH_OCI}" = "true" ] && \
   { [ "${BUILD_STEP}" = "image" ] || [ "${BUILD_STEP}" = "qcow2" ] || [ "${BUILD_STEP}" = "all" ]; }; then
  if [ -z "${REGISTRY}" ]; then
    error "PUSH_OCI=true but REGISTRY is not set.
  Set it via: PUSH_OCI=true REGISTRY=quay.io/yourorg ./build.sh"
  fi

  if ! podman image exists "${LOCAL_IMAGE}" 2>/dev/null; then
    error "PUSH_OCI=true but local image ${LOCAL_IMAGE} not found.
  Run 'make build-image' first, or set BUILD_STEP=all."
  fi

  info ""
  info "=== Step 4b: Pushing bootc OCI build image ==="

  OCI_PUSH_TAG="${REGISTRY}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}:${IMAGE_TAG}-s390x"

  # Tag the local image with the registry destination, then push.
  podman tag "${LOCAL_IMAGE}" "${OCI_PUSH_TAG}" \
    || error "podman tag failed for ${OCI_PUSH_TAG}"
  podman push --format v2s2 --tls-verify=false "${OCI_PUSH_TAG}" \
    || error "podman push failed for ${OCI_PUSH_TAG}"
  ok "OCI build image pushed: ${OCI_PUSH_TAG}"
fi

# =============================================================================
# STEP 5 — (optional) Upload qcow2 to OCP as a CDI DataVolume PVC
# =============================================================================
# Requires: oc + virtctl on PATH and logged in to the target OCP cluster.
# Enable with: PUSH_PVC=true ./build.sh
# Or via make: make push-pvc REGISTRY=quay.io/yourorg (REGISTRY not needed here)
#              make push-pvc   (if already built)
#
# All upload.sh env vars are respected:
#   NAMESPACE, PVC_NAME, DISK_SIZE, STORAGE_CLASS,
#   UPLOAD_PROXY_URL, INSECURE, FORCE_BIND
#
# PVC_NAME defaults to mongodb-ea-disk-<IMAGE_TAG> so each image version gets
# its own PVC and nothing is silently overwritten.
#
# You can also run upload.sh directly at any time after build.sh has produced
# the qcow2:
#   ./upload.sh
#   ./upload.sh --qcow2 /data/securedimage/output/qcow2/rhel9-mongodb-ea-8.3.10-s390x.qcow2

if [ "${PUSH_PVC}" = "true" ] && \
   { [ "${BUILD_STEP}" = "qcow2" ] || [ "${BUILD_STEP}" = "all" ]; }; then

  UPLOAD_SH="${SCRIPT_DIR}/upload.sh"
  if [ ! -f "${UPLOAD_SH}" ]; then
    error "PUSH_PVC=true but upload.sh not found at ${UPLOAD_SH}"
  fi

  info ""
  info "=== Step 5: Uploading qcow2 to OCP PVC via CDI / virtctl ==="

  VERSIONED_QCOW2_PVC="${OUTPUT_DIR}/qcow2/rhel9-mongodb-ea-${IMAGE_TAG}-s390x.qcow2"
  if [ ! -f "${VERSIONED_QCOW2_PVC}" ]; then
    error "qcow2 not found at ${VERSIONED_QCOW2_PVC} — run Step 3 first."
  fi

  # Pass IMAGE_TAG so upload.sh auto-names the PVC mongodb-ea-disk-<tag>.
  # Pass OUTPUT_DIR pointing at the qcow2 subdirectory for auto-detection.
  IMAGE_TAG="${IMAGE_TAG}" \
  OUTPUT_DIR="${OUTPUT_DIR}/qcow2" \
  bash "${UPLOAD_SH}" --qcow2 "${VERSIONED_QCOW2_PVC}" \
  || error "upload.sh failed — see output above."

else
  if [ "${BUILD_STEP}" = "qcow2" ] || [ "${BUILD_STEP}" = "all" ]; then
    info ""
    info "=== Step 5: Skipped (PUSH_PVC=false) ==="
    info "  To upload to OCP PVC: PUSH_PVC=true ./build.sh"
    info "  Or run directly:      ./upload.sh"
  fi
fi

# =============================================================================
# Summary  (only printed when step 3 ran)
# =============================================================================
if [ "${BUILD_STEP}" = "qcow2" ] || [ "${BUILD_STEP}" = "all" ]; then
  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN} Build complete${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
  echo -e "  qcow2        : ${VERSIONED_QCOW2}"
  echo -e "  Compliance   : DISA STIG RHEL 9 (profile_stig) + FIPS 140-3"
  if [ -n "${CONTAINERDISK_TAG}" ]; then
    echo -e "  ContainerDisk: ${CONTAINERDISK_TAG}"
    echo ""
    echo -e "  Helm value (ContainerDisk — default deploy):"
    echo -e "    diskImage.sourceContainerDisk: ${CONTAINERDISK_TAG}"
  else
    echo ""
    echo -e "  ContainerDisk push skipped."
    echo -e "    To push: PUSH_CONTAINERDISK=true REGISTRY=quay.io/yourorg ./build.sh"
    echo -e "    Or:      make push REGISTRY=quay.io/yourorg"
  fi
  if [ -n "${OCI_PUSH_TAG}" ]; then
    echo -e "  OCI image    : ${OCI_PUSH_TAG}"
    echo -e "    (Quay / Clair will scan this image for CVEs)"
  fi
  if [ "${PUSH_PVC}" = "true" ]; then
    echo -e "  PVC upload   : see upload.sh output above"
    echo -e "  Helm value (PVC deploy):"
    echo -e "    diskImage.sourcePVCName: ${PVC_NAME:-mongodb-ea-disk-${IMAGE_TAG}}"
  fi
  echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
fi
