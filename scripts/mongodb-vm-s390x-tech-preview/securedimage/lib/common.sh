#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — helpers shared by build-image.sh and setup-host.sh
# =============================================================================
# Source this file; do not execute it.
#
# Provides: logging (info/ok/warn/error), load_config, require_root,
#           require_s390x, require_cmd, require_free_space.
# =============================================================================

if [ -n "${_COMMON_SH_LOADED:-}" ]; then
  return 0
fi
_COMMON_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${LIB_DIR}/.." && pwd)"
LOG_TAG="${LOG_TAG:-build}"

info()  { echo "[${LOG_TAG}] $*"; }
ok()    { echo "[${LOG_TAG}] OK: $*"; }
warn()  { echo "[${LOG_TAG}] WARNING: $*" >&2; }
error() { echo "[${LOG_TAG}] ERROR: $*" >&2; exit 1; }

# load_config — read KEY=VALUE lines from config.env (or $CONFIG_FILE).
# Values already present in the environment win over the file, so
# `IMAGE_TAG=1.2.3 ./build-image.sh` always overrides config.env.
# The file is parsed, never sourced, so it cannot execute code.
load_config() {
  local file="${CONFIG_FILE:-${REPO_DIR}/config.env}"
  local line key val
  [ -f "${file}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "${line}" in
      ''|'#'*) continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    key="${key//[[:space:]]/}"
    if ! [[ "${key}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      error "Invalid line in ${file}: '${line}' (expected KEY=VALUE with an upper-case KEY)"
    fi
    if [[ "${val}" == \"*\" ]] || [[ "${val}" == \'*\' ]]; then
      val="${val:1:${#val}-2}"
    fi
    if [ -z "${!key+x}" ]; then
      export "${key}=${val}"
    fi
  done < "${file}"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "Must run as root (rootful podman is required). Re-run with: sudo $0 $*"
  fi
}

require_s390x() {
  local arch
  arch="$(uname -m)"
  if [ "${arch}" != "s390x" ]; then
    error "This build must run on an s390x host. Detected architecture: ${arch}."
  fi
  ok "Architecture: ${arch}"
}

# require_cmd <command> <install hint>
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "'$1' not found. $2"
  fi
}

# require_free_space <directory> <minimum GiB>
require_free_space() {
  local dir="$1" min_gib="$2" avail_kb avail_gib
  mkdir -p "${dir}"
  avail_kb="$(df --output=avail -k "${dir}" | tail -1 | tr -d '[:space:]')"
  avail_gib=$(( avail_kb / 1024 / 1024 ))
  if [ "${avail_gib}" -lt "${min_gib}" ]; then
    error "Insufficient disk space in ${dir}: ${avail_gib} GiB free, need at least ${min_gib} GiB. Free up space or set OUTPUT_DIR to a larger filesystem."
  fi
  ok "Disk space: ${avail_gib} GiB free in ${dir}"
}
