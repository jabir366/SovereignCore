#!/usr/bin/env bash
# =============================================================================
# setup-host.sh — one-time preparation of an s390x build host
# =============================================================================
#
# Usage:  sudo ./setup-host.sh
#
# What it does
#   1. Installs missing packages: podman, skopeo, bootc (via dnf)
#   2. Pulls the bootc-image-builder container image (BIB_IMAGE)
#   3. Creates the output directory (OUTPUT_DIR)
#   4. Smoke-tests the tools and /dev/kvm
#
# Configuration (environment variables or config.env; the environment wins)
#   BIB_IMAGE    registry.redhat.io/rhel9/bootc-image-builder:latest
#   OUTPUT_DIR   <repo>/output
#   DRY_RUN      false   print the commands without executing them
#
# Prerequisites
#   - root
#   - RHEL 9 s390x host with an active subscription (dnf can reach BaseOS/AppStream)
#   - registry login:  sudo podman login registry.redhat.io
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="setup"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

case "${1:-}" in
  -h|--help|help)
    awk 'NR<5{next} /^# ====/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
    exit 0 ;;
  '') ;;
  *) echo "Unknown argument: $1" >&2; exit 1 ;;
esac

load_config

BIB_IMAGE="${BIB_IMAGE:-registry.redhat.io/rhel9/bootc-image-builder:latest}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
case "${OUTPUT_DIR}" in
  /*) ;;
  *) OUTPUT_DIR="$(pwd)/${OUTPUT_DIR}" ;;
esac
DRY_RUN="${DRY_RUN:-false}"

# run <command> [args...] — execute, or only print when DRY_RUN=true.
run() {
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# ── Guards ───────────────────────────────────────────────────────────────────
require_root
require_s390x
ok "Host: $(hostname) | OS: $(cat /etc/redhat-release 2>/dev/null || echo 'unknown')"

# ── 1. Packages ──────────────────────────────────────────────────────────────
info "=== Installing required packages ==="
require_cmd dnf "This script supports RHEL-family hosts with dnf only."

PKGS_NEEDED=()
for tool in podman skopeo bootc; do
  if command -v "${tool}" >/dev/null 2>&1; then
    ok "${tool} already installed"
  else
    PKGS_NEEDED+=("${tool}")
  fi
done
if [ "${#PKGS_NEEDED[@]}" -gt 0 ]; then
  info "Installing: ${PKGS_NEEDED[*]}"
  run dnf install -y "${PKGS_NEEDED[@]}"
  ok "Installed: ${PKGS_NEEDED[*]}"
fi

# ── 2. bootc-image-builder ───────────────────────────────────────────────────
info "=== Pulling bootc-image-builder: ${BIB_IMAGE} ==="
if [ "${BIB_IMAGE%%/*}" = "registry.redhat.io" ] && [ "${DRY_RUN}" != "true" ]; then
  if ! podman login --get-login registry.redhat.io >/dev/null 2>&1; then
    error "Not logged in to registry.redhat.io as root. Run: sudo podman login registry.redhat.io   (Red Hat account or registry service account)"
  fi
  ok "registry.redhat.io login: $(podman login --get-login registry.redhat.io)"
fi
if [ "${DRY_RUN}" != "true" ] && podman image exists "${BIB_IMAGE}" 2>/dev/null; then
  ok "bootc-image-builder image already present (refresh with: podman pull ${BIB_IMAGE})"
else
  run podman pull "${BIB_IMAGE}"
  ok "bootc-image-builder image pulled"
fi

# ── 3. Output directory ──────────────────────────────────────────────────────
info "=== Creating output directory: ${OUTPUT_DIR} ==="
run mkdir -p "${OUTPUT_DIR}/qcow2"
if [ "${DRY_RUN}" != "true" ]; then
  require_free_space "${OUTPUT_DIR}" 10
fi

# ── 4. Smoke test ────────────────────────────────────────────────────────────
info "=== Smoke test ==="
FAILED=0
if [ "${DRY_RUN}" != "true" ]; then
  for tool in podman skopeo bootc; do
    if "${tool}" --version >/dev/null 2>&1; then
      ok "${tool}: $("${tool}" --version 2>/dev/null | head -1)"
    else
      warn "${tool}: not working"
      FAILED=$(( FAILED + 1 ))
    fi
  done
  if [ -c /dev/kvm ]; then
    ok "/dev/kvm present"
  else
    warn "/dev/kvm missing - bootc-image-builder needs KVM. Enable virtualization and load the 'kvm' kernel module."
    FAILED=$(( FAILED + 1 ))
  fi
  if podman image exists "${BIB_IMAGE}" 2>/dev/null; then
    ok "bootc-image-builder image present"
  else
    warn "bootc-image-builder image missing"
    FAILED=$(( FAILED + 1 ))
  fi
fi

echo ""
if [ "${FAILED}" -eq 0 ]; then
  echo "Setup complete. Next: sudo make build"
else
  echo "Setup finished with ${FAILED} warning(s) - see above."
  exit 1
fi
