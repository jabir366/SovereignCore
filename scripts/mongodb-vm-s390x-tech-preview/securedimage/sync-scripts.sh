#!/usr/bin/env bash
# =============================================================================
# sync-scripts.sh — Sync scripts between securedimage/ and image-scripts/
# =============================================================================
#
# Enforces the single-source-of-truth rule:
#   securedimage/scripts/*.sh  ←→  services/mongodb-vm/v1/image-scripts/*.sh
#
# Both directories must contain IDENTICAL copies of:
#   mongo-first-boot.sh
#   mongo-rs-init.sh
#
# The Containerfile COPYs from securedimage/scripts/.
# The image-scripts/ directory is the canonical reference that operators expect
# to find alongside the Helm chart.
#
# Usage
# ─────
#   # Check: diff both directories and report any divergence
#   ./sync-scripts.sh check
#
#   # Sync FROM image-scripts/ INTO securedimage/scripts/ (image-scripts is source)
#   ./sync-scripts.sh from-chart
#
#   # Sync FROM securedimage/scripts/ INTO image-scripts/ (securedimage is source)
#   ./sync-scripts.sh from-image
#
#   # Default (no arg): same as 'check'
#   ./sync-scripts.sh
#
# Exit codes
# ──────────
#   0  Files are identical (or sync completed successfully)
#   1  Files differ (check mode) or copy failed
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Canonical paths
IMAGE_SCRIPTS_DIR="${REPO_ROOT}/s390x/byop-sample-repo/services/mongodb-vm/v1/image-scripts"
SECUREDIMAGE_SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# Files that must be identical in both directories
SYNC_FILES=(
  "mongo-first-boot.sh"
  "mongo-rs-init.sh"
)

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[sync]${NC} $*"; }
ok()    { echo -e "${GREEN}[sync] ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}[sync] ⚠${NC} $*"; }
# error() intentionally does NOT exit — in check mode we want to report ALL
# differing files in a single pass and then return a single non-zero code at
# the end, rather than stopping at the first difference. The caller increments
# DIFFS and decides when to exit.
error() { echo -e "${RED}[sync] ✗${NC} $*" >&2; }

# ── Validate both directories exist ─────────────────────────────────────────
if [ ! -d "${IMAGE_SCRIPTS_DIR}" ]; then
  echo -e "${RED}[sync] ✗ image-scripts directory not found: ${IMAGE_SCRIPTS_DIR}${NC}" >&2
  exit 1
fi
if [ ! -d "${SECUREDIMAGE_SCRIPTS_DIR}" ]; then
  echo -e "${RED}[sync] ✗ securedimage/scripts not found: ${SECUREDIMAGE_SCRIPTS_DIR}${NC}" >&2
  exit 1
fi

MODE="${1:-check}"

# =============================================================================
# check — compare only
# =============================================================================
do_check() {
  info "Comparing scripts:"
  info "  A (chart)  : ${IMAGE_SCRIPTS_DIR}"
  info "  B (image)  : ${SECUREDIMAGE_SCRIPTS_DIR}"
  echo ""

  DIFFS=0
  for f in "${SYNC_FILES[@]}"; do
    A="${IMAGE_SCRIPTS_DIR}/${f}"
    B="${SECUREDIMAGE_SCRIPTS_DIR}/${f}"

    if [ ! -f "${A}" ] && [ ! -f "${B}" ]; then
      warn "${f}: missing in BOTH directories"
      DIFFS=$(( DIFFS + 1 ))
    elif [ ! -f "${A}" ]; then
      warn "${f}: missing in image-scripts/ (only in securedimage/scripts/)"
      DIFFS=$(( DIFFS + 1 ))
    elif [ ! -f "${B}" ]; then
      warn "${f}: missing in securedimage/scripts/ (only in image-scripts/)"
      DIFFS=$(( DIFFS + 1 ))
    elif diff -q "${A}" "${B}" > /dev/null 2>&1; then
      ok "${f}: identical"
    else
      error "${f}: DIFFER"
      echo "  --- image-scripts/${f}"
      echo "  +++ securedimage/scripts/${f}"
      diff "${A}" "${B}" | head -30 || true
      echo "  (showing first 30 lines of diff)"
      DIFFS=$(( DIFFS + 1 ))
    fi
  done

  echo ""
  if [ "${DIFFS}" -eq 0 ]; then
    echo -e "${GREEN}All scripts are in sync.${NC}"
    return 0
  else
    echo -e "${RED}${DIFFS} file(s) differ. Run one of:${NC}"
    echo "  ./sync-scripts.sh from-chart   # copy image-scripts/ → securedimage/scripts/"
    echo "  ./sync-scripts.sh from-image   # copy securedimage/scripts/ → image-scripts/"
    return 1
  fi
}

# =============================================================================
# from-chart — image-scripts/ is source → securedimage/scripts/
# =============================================================================
do_from_chart() {
  info "Syncing FROM image-scripts/ (chart) → securedimage/scripts/ (image)"
  info "  Source : ${IMAGE_SCRIPTS_DIR}"
  info "  Target : ${SECUREDIMAGE_SCRIPTS_DIR}"
  echo ""

  for f in "${SYNC_FILES[@]}"; do
    SRC="${IMAGE_SCRIPTS_DIR}/${f}"
    DST="${SECUREDIMAGE_SCRIPTS_DIR}/${f}"
    if [ ! -f "${SRC}" ]; then
      warn "Source missing — skipping: ${SRC}"
      continue
    fi
    cp "${SRC}" "${DST}"
    ok "Copied: ${f}"
  done

  echo ""
  ok "Sync complete — securedimage/scripts/ now matches image-scripts/"
}

# =============================================================================
# from-image — securedimage/scripts/ is source → image-scripts/
# =============================================================================
do_from_image() {
  info "Syncing FROM securedimage/scripts/ (image) → image-scripts/ (chart)"
  info "  Source : ${SECUREDIMAGE_SCRIPTS_DIR}"
  info "  Target : ${IMAGE_SCRIPTS_DIR}"
  echo ""

  for f in "${SYNC_FILES[@]}"; do
    SRC="${SECUREDIMAGE_SCRIPTS_DIR}/${f}"
    DST="${IMAGE_SCRIPTS_DIR}/${f}"
    if [ ! -f "${SRC}" ]; then
      warn "Source missing — skipping: ${SRC}"
      continue
    fi
    cp "${SRC}" "${DST}"
    ok "Copied: ${f}"
  done

  echo ""
  ok "Sync complete — image-scripts/ now matches securedimage/scripts/"
}

# =============================================================================
# Dispatch
# =============================================================================
case "${MODE}" in
  check)       do_check ;;
  from-chart)  do_from_chart ;;
  from-image)  do_from_image ;;
  *)
    echo "Usage: $0 [check|from-chart|from-image]" >&2
    echo ""
    echo "  check        Diff both directories and report differences (default)"
    echo "  from-chart   Copy image-scripts/ → securedimage/scripts/"
    echo "  from-image   Copy securedimage/scripts/ → image-scripts/"
    exit 1
    ;;
esac
