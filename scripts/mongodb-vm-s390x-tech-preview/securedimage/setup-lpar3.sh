#!/usr/bin/env bash
# =============================================================================
# setup-lpar3.sh — One-time bootstrap for lpar3 (b39-cp4d3.pok.stglabs.ibm.com)
# =============================================================================
#
# Run this ONCE as root on lpar3 before using build.sh for the first time.
#
# What it does
# ─────────────
#   Phase 1  Install required RPMs (podman, bootc, skopeo)
#   Phase 2  Pull the bootc-image-builder container from registry.redhat.io
#   Phase 3  (optional) Install + configure Red Hat Image Builder (Mode B only)
#             ── Installs the RHEL AppStream version of osbuild-composer
#                (NOT the CentOS Stream version which only knows centos-9).
#             ── Enables osbuild-local-worker.socket alongside the main socket.
#             ── Creates /etc/rhsm/ca/redhat-uep.pem symlink if this host uses
#                a Satellite/Katello CA instead of the upstream Red Hat CA.
#   Phase 4  Add MongoDB Enterprise source to Image Builder (Mode B only)
#   Phase 5  Create the output directory tree
#   Phase 6  Smoke-test: verify every tool is present and working
#
# Usage
# ─────
#   # Minimal — Mode A only (Containerfile + BIB):
#   ./setup-lpar3.sh
#
#   # Full — including Mode B (Red Hat Image Builder):
#   SETUP_MODE_B=true ./setup-lpar3.sh
#
#   # Dry-run — print what would be done without executing:
#   DRY_RUN=true ./setup-lpar3.sh
#
# Environment variables
# ─────────────────────
#   SETUP_MODE_B      false    Set true to also install osbuild-composer (Mode B)
#   OUTPUT_DIR        /data/securedimage/output
#   BIB_IMAGE         registry.redhat.io/rhel9/bootc-image-builder:latest
#   DRY_RUN           false    Print commands without executing
#
# Prerequisites
# ─────────────
#   • Must be run as root
#   • RHEL 9.x s390x host registered via RHSM (direct CDN or Satellite/Katello)
#   • rhel-9-for-s390x-appstream-rpms repo must be enabled (subscription-manager)
#   • registry.redhat.io login must already exist (as the current root session)
#     If not: podman login registry.redhat.io
#
# IMPORTANT — osbuild-composer must come from RHEL AppStream, NOT CentOS Stream
# ─────────────────────────────────────────────────────────────────────────────
#   The CentOS Stream build of osbuild-composer (vendor: CentOS) only knows the
#   "centos-9" distro. On a RHEL 9 host it cannot find repository definitions for
#   "rhel-9.6" and crashes on every compose and depsolve call.
#
#   This script enforces the correct RHEL build (vendor: Red Hat, Inc.) by:
#     1. Removing any existing CentOS-sourced osbuild-composer packages.
#     2. Installing the RHEL AppStream build pinned to el9_6.
#   See TROUBLESHOOTING.md §1 for the full diagnosis.
# =============================================================================

set -euo pipefail

# ── Configurable defaults ────────────────────────────────────────────────────
SETUP_MODE_B="${SETUP_MODE_B:-false}"
OUTPUT_DIR="${OUTPUT_DIR:-/data/securedimage/output}"
BIB_IMAGE="${BIB_IMAGE:-registry.redhat.io/rhel9/bootc-image-builder:latest}"
DRY_RUN="${DRY_RUN:-false}"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[setup]${NC} $*"; }
ok()    { echo -e "${GREEN}[setup] ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup] ⚠${NC} $*"; }
error() { echo -e "${RED}[setup] ✗${NC} $*" >&2; exit 1; }

# run() — executes a command or prints it in dry-run mode.
# Uses 'eval' so that variable-expanded strings with spaces work correctly
# (e.g. "dnf install -y podman bootc" passed as a single string argument).
# Only call run() with trusted, internally-constructed strings — never with
# user-supplied input.
run() {
  if [ "${DRY_RUN}" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} $*"
  else
    eval "$@"
  fi
}

# =============================================================================
# GUARD CHECKS
# =============================================================================
if [ "$(id -u)" -ne 0 ]; then
  error "Must run as root. Use: sudo ./setup-lpar3.sh"
fi

ARCH=$(uname -m)
if [ "${ARCH}" != "s390x" ]; then
  error "This script targets s390x only. Detected: ${ARCH}"
fi
ok "Host: $(hostname) | Arch: ${ARCH} | OS: $(cat /etc/redhat-release 2>/dev/null || echo 'RHEL')"

# =============================================================================
# PHASE 1 — Install required RPMs
# =============================================================================
info ""
info "=== Phase 1: Installing required RPMs ==="

PKGS_NEEDED=()

# podman — container engine for build and BIB
if ! command -v podman &>/dev/null; then
  PKGS_NEEDED+=(podman)
else
  ok "podman already installed: $(podman --version)"
fi

# bootc — bootc CLI (used for image inspection + upgrade inside VMs)
if ! command -v bootc &>/dev/null; then
  PKGS_NEEDED+=(bootc)
else
  ok "bootc already installed: $(bootc --version 2>/dev/null || echo 'installed')"
fi

# skopeo — used to inspect and copy OCI images between registries
if ! command -v skopeo &>/dev/null; then
  PKGS_NEEDED+=(skopeo)
else
  ok "skopeo already installed: $(skopeo --version 2>/dev/null | head -1)"
fi

if [ "${#PKGS_NEEDED[@]}" -gt 0 ]; then
  info "Installing: ${PKGS_NEEDED[*]}"
  run "dnf install -y ${PKGS_NEEDED[*]}"
  ok "RPMs installed: ${PKGS_NEEDED[*]}"
else
  ok "All core RPMs already present — nothing to install"
fi

# =============================================================================
# PHASE 2 — Pull bootc-image-builder container
# =============================================================================
info ""
info "=== Phase 2: Pulling bootc-image-builder ==="
info "  Image: ${BIB_IMAGE}"

# Verify registry.redhat.io auth before attempting pull.
# The registry.redhat.io login must already exist in the current root session.
# If not logged in yet, run: podman login registry.redhat.io
# Use your Red Hat portal credentials or a service account token
# (see: https://access.redhat.com/terms-based-registry/ for tokens).
if ! podman login --get-login registry.redhat.io &>/dev/null; then
  error "Not logged in to registry.redhat.io.
  Run first:  podman login registry.redhat.io
  Use Red Hat portal credentials or a token from:
  https://access.redhat.com/terms-based-registry/"
fi
ok "registry.redhat.io auth: $(podman login --get-login registry.redhat.io 2>/dev/null)"

if podman image exists "${BIB_IMAGE}" 2>/dev/null; then
  ok "BIB image already present — skipping pull"
  info "  To refresh: podman pull ${BIB_IMAGE}"
else
  info "Pulling BIB image (this may take several minutes) ..."
  run "podman pull ${BIB_IMAGE}"
  ok "BIB image pulled: ${BIB_IMAGE}"
fi

# =============================================================================
# PHASE 3 — Red Hat Image Builder (Mode B — optional)
# =============================================================================
# Phases 3 and 4 are nested inside the SETUP_MODE_B guard because they are
# only relevant when Mode B (composer-cli) will be used for builds.
# If SETUP_MODE_B=false (the default), these phases are skipped entirely and
# a skip notice is printed at the end.
if [ "${SETUP_MODE_B}" = "true" ]; then
  info ""
  info "=== Phase 3: Installing Red Hat Image Builder (Mode B) ==="

  # ── 3a. Ensure the RHEL AppStream repo is enabled ─────────────────────────
  # osbuild-composer must come from the RHEL AppStream repo, NOT CentOS Stream.
  # The CentOS build (vendor: CentOS) only knows "centos-9" as a valid distro
  # and will crash with "unknown distribution: rhel-9.6" on every RHEL host.
  # See TROUBLESHOOTING.md §1 for the full diagnosis.
  info "Ensuring rhel-9-for-s390x-appstream-rpms is enabled ..."
  if subscription-manager repos --list-enabled 2>/dev/null \
       | grep -q "rhel-9-for-s390x-appstream-rpms"; then
    ok "rhel-9-for-s390x-appstream-rpms already enabled"
  else
    run "subscription-manager repos --enable=rhel-9-for-s390x-appstream-rpms"
    ok "rhel-9-for-s390x-appstream-rpms enabled"
  fi

  # ── 3b. Remove CentOS-sourced osbuild-composer if present ─────────────────
  # Detect by checking the RPM vendor field — CentOS packages report "CentOS".
  COMPOSER_VENDOR=$(rpm -q --queryformat '%{VENDOR}' osbuild-composer 2>/dev/null || true)
  if echo "${COMPOSER_VENDOR}" | grep -qi "centos"; then
    warn "CentOS-sourced osbuild-composer detected (vendor: ${COMPOSER_VENDOR}) — replacing with RHEL build"
    run "systemctl stop osbuild-composer.service osbuild-local-worker.socket osbuild-composer.socket 2>/dev/null || true"
    run "systemctl reset-failed osbuild-composer.service 2>/dev/null || true"
    run "dnf remove -y osbuild-composer osbuild-composer-core osbuild-composer-worker osbuild-composer-dnf-json 2>/dev/null || true"
    ok "CentOS osbuild-composer packages removed"
  fi

  # ── 3c. Install the RHEL AppStream build of osbuild-composer ──────────────
  # Pinned to 132.2-3.el9_6 — the latest RHEL 9.6 release as of this writing.
  # This version ships the rhel-9.json distro definition that makes depsolve
  # and compose work correctly against RHSM-subscribed CDN repos.
  # composer-cli (weldr-client) comes from the standard AppStream repo.
  #
  # Version matrix:
  #   CentOS Stream 9 repo   → 176-1.el9    (vendor: CentOS)   ← WRONG
  #   RHEL 9.6 AppStream     → 132.2-3.el9_6 (vendor: Red Hat) ← CORRECT
  RHEL_COMPOSER_VER="132.2-3.el9_6"
  if ! command -v composer-cli &>/dev/null || \
     ! rpm -q --queryformat '%{VENDOR}' osbuild-composer 2>/dev/null | grep -qi "red hat"; then
    info "Installing RHEL osbuild-composer ${RHEL_COMPOSER_VER} from AppStream ..."
    run "dnf install -y \
      --disablerepo='mirror.stream.centos.org*' \
      osbuild-composer-${RHEL_COMPOSER_VER}.s390x \
      osbuild-composer-core-${RHEL_COMPOSER_VER}.s390x \
      osbuild-composer-worker-${RHEL_COMPOSER_VER}.s390x \
      composer-cli"
    ok "RHEL osbuild-composer ${RHEL_COMPOSER_VER} installed"
  else
    ok "RHEL osbuild-composer already installed: $(rpm -q osbuild-composer 2>/dev/null)"
  fi

  # ── 3d. Fix RHSM CA certificate path expected by osbuild-composer ─────────
  # osbuild-composer's dnf resolver looks for /etc/rhsm/ca/redhat-uep.pem to
  # authenticate CDN requests. On hosts registered via Satellite/Katello this
  # file does not exist — the CA is stored as katello-server-ca.pem instead.
  # Creating a symlink resolves the "error setting certificate file" SSL error
  # that causes every depsolve/compose to fail.
  # See TROUBLESHOOTING.md §2 for the full diagnosis.
  RHSM_CA_DIR="/etc/rhsm/ca"
  UEP_PEM="${RHSM_CA_DIR}/redhat-uep.pem"
  if [ ! -f "${UEP_PEM}" ] && [ ! -L "${UEP_PEM}" ]; then
    # Pick the best available CA: prefer katello-server-ca, fall back to corp-root-ca
    if [ -f "${RHSM_CA_DIR}/katello-server-ca.pem" ]; then
      SATELLITE_CA="${RHSM_CA_DIR}/katello-server-ca.pem"
    elif [ -f "${RHSM_CA_DIR}/corp-root-ca.pem" ]; then
      SATELLITE_CA="${RHSM_CA_DIR}/corp-root-ca.pem"
    else
      SATELLITE_CA=""
    fi

    if [ -n "${SATELLITE_CA}" ]; then
      run "ln -sf ${SATELLITE_CA} ${UEP_PEM}"
      ok "RHSM CA symlink created: ${UEP_PEM} → ${SATELLITE_CA}"
    else
      warn "No Satellite CA found under ${RHSM_CA_DIR} and redhat-uep.pem is missing."
      warn "osbuild depsolve will fail with SSL cert errors."
      warn "Fix: ln -sf /path/to/your/ca.pem ${UEP_PEM}"
    fi
  else
    ok "RHSM CA cert: ${UEP_PEM} ✓"
  fi

  # ── 3e. Enable both required sockets ──────────────────────────────────────
  # osbuild-composer needs TWO sockets:
  #   osbuild-composer.socket      — weldr API (used by composer-cli)
  #   osbuild-local-worker.socket  — local osbuild worker (runs the actual build)
  # Starting only osbuild-composer.socket without the worker socket causes the
  # service to exit with "neither the local worker socket nor the remote worker
  # socket is enabled".
  info "Enabling osbuild sockets ..."
  run "systemctl enable --now osbuild-composer.socket osbuild-local-worker.socket"
  sleep 2

  # Verify the service came up correctly after socket activation
  if systemctl is-active --quiet osbuild-composer.socket 2>/dev/null; then
    ok "osbuild-composer.socket: active"
  else
    warn "osbuild-composer.socket: not active — check: journalctl -u osbuild-composer.service"
  fi
  if systemctl is-active --quiet osbuild-local-worker.socket 2>/dev/null; then
    ok "osbuild-local-worker.socket: active"
  else
    warn "osbuild-local-worker.socket: not active"
  fi

  # Verify the RHEL distro is now visible to the composer
  if composer-cli distros list 2>/dev/null | grep -q "rhel-9"; then
    ok "osbuild-composer distros: $(composer-cli distros list 2>/dev/null | grep rhel-9 | tr '\n' ' ')"
  else
    warn "rhel-9 distro not listed — composer may still be starting. Run: composer-cli distros list"
  fi

  # =============================================================================
  # PHASE 4 — Add MongoDB Enterprise repo source to Image Builder (Mode B)
  # =============================================================================
  info ""
  info "=== Phase 4: Adding MongoDB Enterprise source to Image Builder ==="

  # Check if the source is already registered
  if composer-cli sources list 2>/dev/null | grep -q "mongodb-enterprise"; then
    ok "MongoDB Enterprise source already in Image Builder"
  else
    info "Registering MongoDB Enterprise source ..."
    # Write the source definition to a temp file and push it
    MONGO_SOURCE_FILE=$(mktemp /tmp/mongodb-ea-source-XXXXXX.toml)
    # Note: weldr-client's composer-cli (RHEL 9) uses a flat array for gpgkeys,
    # NOT the [[gpgkeys]] table syntax used by older osbuild-composer clients.
    cat > "${MONGO_SOURCE_FILE}" <<'SRCEOF'
id        = "mongodb-enterprise"
name      = "MongoDB Enterprise Repository"
type      = "yum-baseurl"
url       = "https://repo.mongodb.com/yum/redhat/9/mongodb-enterprise/8.0/s390x/"
check_gpg = true
check_ssl = true
system    = false
rhsm      = false
gpgkeys   = ["https://pgp.mongodb.com/server-8.0.asc"]
SRCEOF

    if [ "${DRY_RUN}" = "true" ]; then
      echo -e "${YELLOW}[DRY-RUN]${NC} composer-cli sources add ${MONGO_SOURCE_FILE}"
    else
      composer-cli sources add "${MONGO_SOURCE_FILE}"
      ok "MongoDB Enterprise source added to Image Builder"
      rm -f "${MONGO_SOURCE_FILE}"

      # Verify
      info "Source list after add:"
      composer-cli sources list
    fi
  fi

else
  info ""
  info "=== Phase 3+4: Skipped (SETUP_MODE_B=false) ==="
  info "  To enable Red Hat Image Builder: SETUP_MODE_B=true ./setup-lpar3.sh"
fi

# =============================================================================
# PHASE 5 — Create output directory tree
# =============================================================================
info ""
info "=== Phase 5: Creating output directory: ${OUTPUT_DIR} ==="

run "mkdir -p ${OUTPUT_DIR}/qcow2 ${OUTPUT_DIR}/oci-archive"
ok "Output directories created: ${OUTPUT_DIR}/{qcow2,oci-archive}"

# Report available space
AVAIL_KB=$(df --output=avail -k "${OUTPUT_DIR}" | tail -1)
AVAIL_GIB=$(( AVAIL_KB / 1024 / 1024 ))
info "  Available space in ${OUTPUT_DIR}: ${AVAIL_GIB} GiB"
if [ "${AVAIL_GIB}" -lt 10 ]; then
  warn "Low disk space: ${AVAIL_GIB} GiB. Build requires at least 10 GiB."
else
  ok "Disk space sufficient: ${AVAIL_GIB} GiB"
fi

# =============================================================================
# PHASE 6 — Smoke-test all tools
# =============================================================================
info ""
info "=== Phase 6: Smoke-test ==="

FAILED=0

check_cmd() {
  local name="$1"; local cmd="$2"
  if eval "${cmd}" &>/dev/null; then
    ok "${name}: $(eval "${cmd}" 2>/dev/null | head -1)"
  else
    warn "${name}: FAILED — ${cmd}"
    FAILED=$(( FAILED + 1 ))
  fi
}

check_cmd "podman"  "podman --version"
check_cmd "bootc"   "bootc --version 2>/dev/null || echo 'installed'"
check_cmd "skopeo"  "skopeo --version"

if [ -c /dev/kvm ]; then
  ok "/dev/kvm: present (KVM available)"
else
  warn "/dev/kvm: NOT present — BIB requires KVM. Ensure the kvm kernel module is loaded."
  FAILED=$(( FAILED + 1 ))
fi

if podman image exists "${BIB_IMAGE}" 2>/dev/null; then
  ok "BIB image: ${BIB_IMAGE} ✓"
else
  warn "BIB image: NOT found — pull failed or image was removed"
  FAILED=$(( FAILED + 1 ))
fi

if [ "${SETUP_MODE_B}" = "true" ]; then
  check_cmd "composer-cli" "composer-cli --version"

  # Verify vendor: must be Red Hat, not CentOS
  VENDOR=$(rpm -q --queryformat '%{VENDOR}' osbuild-composer 2>/dev/null || true)
  if echo "${VENDOR}" | grep -qi "red hat"; then
    ok "osbuild-composer vendor: ${VENDOR} ✓"
  else
    warn "osbuild-composer vendor: '${VENDOR}' — expected 'Red Hat'. Run setup again."
    FAILED=$(( FAILED + 1 ))
  fi

  if systemctl is-active --quiet osbuild-composer.socket 2>/dev/null; then
    ok "osbuild-composer.socket: active"
  else
    warn "osbuild-composer.socket: not active — run: systemctl enable --now osbuild-composer.socket"
    FAILED=$(( FAILED + 1 ))
  fi
  if systemctl is-active --quiet osbuild-local-worker.socket 2>/dev/null; then
    ok "osbuild-local-worker.socket: active"
  else
    warn "osbuild-local-worker.socket: not active — run: systemctl enable --now osbuild-local-worker.socket"
    FAILED=$(( FAILED + 1 ))
  fi

  if composer-cli distros list 2>/dev/null | grep -q "rhel-9"; then
    ok "distros list contains rhel-9 ✓"
  else
    warn "rhel-9 not in distros list — osbuild-composer may still be starting up"
    FAILED=$(( FAILED + 1 ))
  fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
if [ "${FAILED}" -eq 0 ]; then
  echo -e "${GREEN} lpar3 setup complete — ready to run build.sh${NC}"
else
  echo -e "${YELLOW} lpar3 setup completed with ${FAILED} warning(s) — check above${NC}"
fi
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  Next steps:"
echo "    1. Sync securedimage/ to lpar3:  (from your local machine)"
echo "         rsync -av --delete securedimage/ root@lpar3:/root/securedimage/"
echo "         (or: scp -F ~/.genericremoteconnect-ssh-config -r securedimage lpar3:/root/)"
echo ""
echo "    2. Run the build (on lpar3):"
echo "         cd /root/securedimage"
echo "         ./build.sh                        # Mode A (Containerfile)"
if [ "${SETUP_MODE_B}" = "true" ]; then
  echo "         USE_RH_IMAGE_BUILDER=true ./build.sh  # Mode B (Image Builder)"
fi
echo ""
echo "    3. Upload to OCP:"
echo "         oc login <cluster-api-url>"
echo "         ./upload.sh"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
