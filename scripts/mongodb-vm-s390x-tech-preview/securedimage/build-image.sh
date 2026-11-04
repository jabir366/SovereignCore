#!/usr/bin/env bash
# =============================================================================
# build-image.sh — build the secured MongoDB bootc image and convert it to qcow2
# =============================================================================
#
# Pipeline: podman build (Containerfile) -> bootc-image-builder (BIB) -> qcow2
#
# Usage:  sudo ./build-image.sh [STEP]
#
# Steps:
#   check   Validate prerequisites (root, s390x, podman, /dev/kvm, registry
#           login, BIB image, required source files, free disk space)
#   image   podman build the Containerfile into a local OCI image
#   qcow2   Convert the local OCI image to a qcow2 disk with BIB
#   push    Push the qcow2 (as a ContainerDisk image) and/or the OCI image
#           to REGISTRY (requires REGISTRY)
#   all     check + image + qcow2   (default)
#   clean   Remove OUTPUT_DIR/qcow2, OUTPUT_DIR/logs and generated files
#
# Configuration (environment variables or config.env; the environment wins)
#   IMAGE_NAME            mongodb-bootc
#   IMAGE_TAG             contents of the VERSION file
#   BASE_IMAGE            registry.redhat.io/rhel9/rhel-bootc:9.6
#   BIB_IMAGE             registry.redhat.io/rhel9/bootc-image-builder:latest
#   MONGODB_VERSION       8.0
#   MONGODB_REPO_BASEURL  (empty) override the MongoDB yum repository URL
#   MONGODB_GPG_KEY_URL   (empty) override the MongoDB GPG key URL
#   OUTPUT_DIR            <repo>/output
#   LOG_DIR               <OUTPUT_DIR>/logs
#   PLATFORM              linux/s390x
#   MIN_FREE_GIB          10
#   SKIP_BUILD            false   reuse an existing local image in step 'image'
#   PRUNE_STALE           false   remove ALL stopped podman containers and
#                                 unused volumes before running BIB
#   REGISTRY              (empty) registry host[:port] for the push step
#   REGISTRY_NAMESPACE    (empty) optional namespace/organisation in REGISTRY
#   PUSH_CONTAINERDISK    true    push the qcow2 wrapped as a ContainerDisk
#   PUSH_OCI              true    push the bootc OCI image
#   PUSH_TLS_VERIFY       true    verify registry TLS certificates on push
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="build-image"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  awk 'NR<5{next} /^# ====/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
}

STEP="${1:-all}"
case "${STEP}" in
  check|image|qcow2|push|all|clean) ;;
  -h|--help|help) usage; exit 0 ;;
  *) echo "Unknown step: ${STEP}" >&2; usage >&2; exit 1 ;;
esac

load_config

# ── Configuration ────────────────────────────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-mongodb-bootc}"
if [ -z "${IMAGE_TAG:-}" ]; then
  [ -f "${SCRIPT_DIR}/VERSION" ] || error "IMAGE_TAG is not set and ${SCRIPT_DIR}/VERSION does not exist."
  IMAGE_TAG="$(tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION")"
fi
BASE_IMAGE="${BASE_IMAGE:-registry.redhat.io/rhel9/rhel-bootc:9.6}"
BIB_IMAGE="${BIB_IMAGE:-registry.redhat.io/rhel9/bootc-image-builder:latest}"
MONGODB_VERSION="${MONGODB_VERSION:-8.0}"
MONGODB_REPO_BASEURL="${MONGODB_REPO_BASEURL:-}"
MONGODB_GPG_KEY_URL="${MONGODB_GPG_KEY_URL:-}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
PLATFORM="${PLATFORM:-linux/s390x}"
MIN_FREE_GIB="${MIN_FREE_GIB:-10}"
SKIP_BUILD="${SKIP_BUILD:-false}"
PRUNE_STALE="${PRUNE_STALE:-false}"
REGISTRY="${REGISTRY:-}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-}"
PUSH_CONTAINERDISK="${PUSH_CONTAINERDISK:-true}"
PUSH_OCI="${PUSH_OCI:-true}"
PUSH_TLS_VERIFY="${PUSH_TLS_VERIFY:-true}"

[[ "${IMAGE_NAME}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
  || error "IMAGE_NAME '${IMAGE_NAME}' is invalid (lower-case letters, digits, '.', '_', '-')."
[[ "${IMAGE_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] \
  || error "IMAGE_TAG '${IMAGE_TAG}' is invalid (letters, digits, '.', '_', '-')."
case "${OUTPUT_DIR}" in
  /*) ;;
  *) OUTPUT_DIR="$(pwd)/${OUTPUT_DIR}" ;;
esac
[ "${OUTPUT_DIR}" != "/" ] || error "OUTPUT_DIR must not be '/'."
LOG_DIR="${LOG_DIR:-${OUTPUT_DIR}/logs}"

LOCAL_IMAGE="localhost/${IMAGE_NAME}:${IMAGE_TAG}"
QCOW2_PATH="${OUTPUT_DIR}/qcow2/disk.qcow2"
VERSIONED_QCOW2="${OUTPUT_DIR}/qcow2/${IMAGE_NAME}-${IMAGE_TAG}-s390x.qcow2"

# registry_ref <image-name> — <registry>[/<namespace>]/<image-name>:<tag>-s390x
registry_ref() {
  local prefix="${REGISTRY}"
  [ -z "${REGISTRY_NAMESPACE}" ] || prefix="${prefix}/${REGISTRY_NAMESPACE}"
  echo "${prefix}/$1:${IMAGE_TAG}-s390x"
}

# ── clean (no root, no logging) ──────────────────────────────────────────────
if [ "${STEP}" = "clean" ]; then
  info "Removing ${OUTPUT_DIR}/qcow2, ${LOG_DIR} and ${OUTPUT_DIR}/Containerfile.disk ..."
  rm -rf -- "${OUTPUT_DIR}/qcow2" "${LOG_DIR}" "${OUTPUT_DIR}/Containerfile.disk" \
    || error "Could not remove build outputs. Files created by root need: sudo make clean"
  ok "Clean complete."
  exit 0
fi

# ── Log everything to a file as well as the terminal ─────────────────────────
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/build-image.log"
exec > >(tee -a "${LOG_FILE}") 2>&1
info "Step: ${STEP}   (log: ${LOG_FILE})"

# =============================================================================
# check — prerequisites
# =============================================================================
step_check() {
  info "=== Validating prerequisites ==="

  require_root "${STEP}"
  require_s390x
  require_cmd podman "Install it with: sudo dnf install -y podman   (or run: sudo make setup)"
  require_cmd awk "Install it with: sudo dnf install -y gawk"
  ok "podman: $(podman --version | awk '{print $3}')"

  if [ ! -c /dev/kvm ]; then
    error "/dev/kvm not present. bootc-image-builder needs KVM; enable virtualization (nested virtualization on a VM) and load the 'kvm' kernel module."
  fi
  ok "/dev/kvm present"

  local image host
  for image in "${BASE_IMAGE}" "${BIB_IMAGE}"; do
    host="${image%%/*}"
    if [ "${host}" = "registry.redhat.io" ]; then
      if ! podman login --get-login registry.redhat.io >/dev/null 2>&1; then
        error "Not logged in to registry.redhat.io as root. Run: sudo podman login registry.redhat.io   (Red Hat account or registry service account)"
      fi
      ok "registry.redhat.io login: $(podman login --get-login registry.redhat.io)"
      break
    fi
  done

  if ! podman image exists "${BIB_IMAGE}" 2>/dev/null; then
    info "bootc-image-builder image not found locally - pulling ${BIB_IMAGE} ..."
    podman pull "${BIB_IMAGE}" || error "Failed to pull ${BIB_IMAGE}. Check network access and registry login."
  fi
  ok "bootc-image-builder image: ${BIB_IMAGE}"

  local f
  while read -r f; do
    [ -f "${SCRIPT_DIR}/${f}" ] || error "Required file missing: ${SCRIPT_DIR}/${f}"
  done < <(awk '/^COPY /{print $2}' "${SCRIPT_DIR}/Containerfile")
  ok "All Containerfile COPY sources present"

  require_free_space "${OUTPUT_DIR}" "${MIN_FREE_GIB}"

  info "Build configuration:"
  info "  Image       : ${LOCAL_IMAGE}"
  info "  Base image  : ${BASE_IMAGE}"
  info "  BIB image   : ${BIB_IMAGE}"
  info "  Platform    : ${PLATFORM}"
  info "  MongoDB     : ${MONGODB_VERSION}"
  info "  Output      : ${OUTPUT_DIR}"
  ok "Prerequisites check passed."
}

# =============================================================================
# image — podman build: Containerfile -> OCI image
# =============================================================================
step_image() {
  info "=== Building OCI image ${LOCAL_IMAGE} ==="

  if [ "${SKIP_BUILD}" = "true" ]; then
    podman image exists "${LOCAL_IMAGE}" 2>/dev/null \
      || error "SKIP_BUILD=true but image ${LOCAL_IMAGE} not found locally."
    warn "SKIP_BUILD=true - reusing existing image ${LOCAL_IMAGE}"
    return 0
  fi

  podman build \
    --platform "${PLATFORM}" \
    --tag "${LOCAL_IMAGE}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "IMAGE_TAG=${IMAGE_TAG}" \
    --build-arg "MONGODB_VERSION=${MONGODB_VERSION}" \
    --build-arg "MONGODB_REPO_BASEURL=${MONGODB_REPO_BASEURL}" \
    --build-arg "MONGODB_GPG_KEY_URL=${MONGODB_GPG_KEY_URL}" \
    --file "${SCRIPT_DIR}/Containerfile" \
    "${SCRIPT_DIR}" \
  || error "podman build failed. See ${LOG_FILE}"
  ok "OCI image built: ${LOCAL_IMAGE}"

  # The version label must contain the concrete tag, not an unexpanded token or
  # the '0.0.0' sentinel; scanners and registries key their caches on it.
  local built
  built="$(podman inspect --format '{{index .Labels "org.opencontainers.image.version"}}' "${LOCAL_IMAGE}" 2>/dev/null || true)"
  if [[ "${built}" == *'${'* ]] || [ "${built}" = "0.0.0" ]; then
    error "Label org.opencontainers.image.version is '${built}', expected '${IMAGE_TAG}'. IMAGE_TAG was not passed to the build."
  fi
  if [ "${built}" != "${IMAGE_TAG}" ]; then
    warn "Label version mismatch: expected '${IMAGE_TAG}', got '${built}'."
  else
    ok "Label verified: org.opencontainers.image.version=${built}"
  fi
}

# =============================================================================
# qcow2 — bootc-image-builder: OCI image -> qcow2
# =============================================================================
step_qcow2() {
  podman image exists "${LOCAL_IMAGE}" 2>/dev/null \
    || error "OCI image '${LOCAL_IMAGE}' not found in podman storage. Run 'sudo make build-image' first."
  ok "OCI image found: ${LOCAL_IMAGE}"

  info "=== Converting ${LOCAL_IMAGE} to qcow2 with bootc-image-builder ==="
  info "  BIB image : ${BIB_IMAGE}"
  info "  Output    : ${OUTPUT_DIR}"

  # BIB refuses to run when its output directory already holds a previous result.
  rm -rf -- "${OUTPUT_DIR:?}/qcow2"
  mkdir -p "${OUTPUT_DIR}/qcow2"

  # Stale containers/volumes can hold storage locks that BIB's inner podman
  # cannot acquire ("acquiring lock ... file exists"). Pruning is opt-in
  # because it affects ALL stopped containers and unused volumes on the host.
  if [ "${PRUNE_STALE}" = "true" ]; then
    info "  PRUNE_STALE=true - removing stopped containers and unused volumes ..."
    podman container prune -f || true
    podman volume prune -f || true
  fi

  # The bare 'localhost/<name>:<tag>' reference is required (no transport prefix).
  # The disk layout is read from /usr/lib/bootc/install/10-disk-layout.toml,
  # which the Containerfile embeds in the image.
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
      "${LOCAL_IMAGE}" \
  || error "bootc-image-builder failed. See ${LOG_FILE}"

  [ -f "${QCOW2_PATH}" ] || error "Expected qcow2 not found at ${QCOW2_PATH}. Check the bootc-image-builder output above."
  ok "qcow2 produced: ${QCOW2_PATH} ($(du -sh "${QCOW2_PATH}" | awk '{print $1}'))"

  mv "${QCOW2_PATH}" "${VERSIONED_QCOW2}"
  ok "Renamed to ${VERSIONED_QCOW2}"
}

# =============================================================================
# push — optional: ContainerDisk image and/or bootc OCI image
# =============================================================================
step_push() {
  [ -n "${REGISTRY}" ] || error "REGISTRY is not set. Example: sudo make push REGISTRY=registry.example.com REGISTRY_NAMESPACE=myorg"

  if [ "${PUSH_CONTAINERDISK}" = "true" ]; then
    [ -f "${VERSIONED_QCOW2}" ] || error "qcow2 not found at ${VERSIONED_QCOW2}. Run 'sudo make build' first."
    local disk_ref
    disk_ref="$(registry_ref "${IMAGE_NAME}-containerdisk")"
    info "=== Wrapping qcow2 as ContainerDisk and pushing ${disk_ref} ==="

    # The importer looks for /disk/disk.img, so the versioned file is renamed.
    cat > "${OUTPUT_DIR}/Containerfile.disk" <<DISKEOF
FROM scratch
ADD qcow2/${IMAGE_NAME}-${IMAGE_TAG}-s390x.qcow2 /disk/disk.img
DISKEOF
    podman build \
      --platform "${PLATFORM}" \
      --tag "${disk_ref}" \
      --file "${OUTPUT_DIR}/Containerfile.disk" \
      "${OUTPUT_DIR}" \
    || error "ContainerDisk build failed. See ${LOG_FILE}"
    podman push --format v2s2 --tls-verify="${PUSH_TLS_VERIFY}" "${disk_ref}" \
      || error "podman push failed for ${disk_ref}. Check 'podman login ${REGISTRY}' and network access."
    ok "ContainerDisk pushed: ${disk_ref}"
  fi

  if [ "${PUSH_OCI}" = "true" ]; then
    podman image exists "${LOCAL_IMAGE}" 2>/dev/null \
      || error "Local image ${LOCAL_IMAGE} not found. Run 'sudo make build-image' first."
    local oci_ref
    oci_ref="$(registry_ref "${IMAGE_NAME}")"
    info "=== Pushing bootc OCI image ${oci_ref} ==="
    podman tag "${LOCAL_IMAGE}" "${oci_ref}" || error "podman tag failed for ${oci_ref}"
    podman push --format v2s2 --tls-verify="${PUSH_TLS_VERIFY}" "${oci_ref}" \
      || error "podman push failed for ${oci_ref}. Check 'podman login ${REGISTRY}' and network access."
    ok "OCI image pushed: ${oci_ref}"
  fi
}

summary() {
  echo ""
  echo "======================================================================"
  echo " Build complete"
  echo "======================================================================"
  echo "  OCI image : ${LOCAL_IMAGE}   (in root's podman storage)"
  echo "  qcow2     : ${VERSIONED_QCOW2}"
  echo "  Log       : ${LOG_FILE}"
  echo "======================================================================"
}

case "${STEP}" in
  check) step_check ;;
  image) step_image ;;
  qcow2) step_qcow2; summary ;;
  push)  require_root "${STEP}"; step_push ;;
  all)   step_check; step_image; step_qcow2; summary ;;
esac
