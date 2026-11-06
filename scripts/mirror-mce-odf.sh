#!/usr/bin/env bash
# =============================================================================
# mirror-mce-odf.sh
#
# Mirrors multicluster-engine (MCE, incl. klusterlet images) and ODF
# (incl. ocs-client / cephcsi / rook / rhceph) from registry.redhat.io into a
# bring-your-own (BYO) registry, the same way "Purple with Enclave" does it for
# its landing zone: oc-mirror v2, catalog filtered to the Enclave-pinned
# versions, no architecture filter (full multi-arch manifest lists are copied).
#
# Use when the install does NOT go through Enclave (BYO), e.g. for the MongoDB
# on VM tech preview.
#
# Usage: mirror-mce-odf.sh [--dry-run] [--apply]
#   --dry-run  oc-mirror --dry-run only; nothing is pushed
#   --apply    oc apply the generated IDMS/ITMS/CatalogSource to the current cluster
#
# Environment (credentials are never taken as arguments):
#   TARGET_REGISTRY_ROOT         BYO push root, e.g. byo.example.com:8443/sovcloud
#   TARGET_REGISTRY_USERNAME     BYO registry user
#   TARGET_REGISTRY_PASSWORD     BYO registry password
#   REDHAT_USERNAME              registry.redhat.io user
#   REDHAT_PASSWORD              registry.redhat.io password
#   TARGET_REGISTRY_TLS_VERIFY   true (default) | false  (self-signed lab registries only)
#
# Requires: oc-mirror (v2), podman; oc for --apply
# Pins match mcsp resources/images-manifest/rh-{seed,storage}-operators-mirror-manifest.yaml
# =============================================================================
set -euo pipefail

CATALOG="registry.redhat.io/redhat/redhat-operator-index:v4.20"
ODF_CHANNEL="stable-4.20"
ODF_VERSION="4.20.7-rhodf"
ODF_PACKAGES="odf-operator odf-dependencies odf-csi-addons-operator rook-ceph-operator
  ocs-operator recipe mcg-operator odf-prometheus-operator ocs-client-operator
  cephcsi-operator odf-external-snapshotter-operator"

DRY_RUN=0; APPLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --apply)   APPLY=1 ;;
    -h|--help) sed -n '/^# Usage/,/^# Pins/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "ERROR: unknown option: $arg (use --dry-run, --apply)" >&2; exit 1 ;;
  esac
done

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ----------------------------- Checks ----------------------------------------
command -v oc-mirror >/dev/null 2>&1 || fail "oc-mirror (v2) not found in PATH"
command -v podman    >/dev/null 2>&1 || fail "podman not found in PATH"
(( ! APPLY || DRY_RUN )) || command -v oc >/dev/null 2>&1 || fail "--apply needs oc"

ROOT="${TARGET_REGISTRY_ROOT:-}"; ROOT="${ROOT#https://}"; ROOT="${ROOT#http://}"; ROOT="${ROOT%/}"
TLS_VERIFY="${TARGET_REGISTRY_TLS_VERIFY:-true}"
[[ -n "$ROOT" ]] || fail "TARGET_REGISTRY_ROOT is not set"
[[ -n "${REDHAT_USERNAME:-}" ]] || fail "REDHAT_USERNAME is not set"
[[ -n "${REDHAT_PASSWORD:-}" ]] || fail "REDHAT_PASSWORD is not set"
if (( ! DRY_RUN )); then
  [[ -n "${TARGET_REGISTRY_USERNAME:-}" ]] || fail "TARGET_REGISTRY_USERNAME is not set"
  [[ -n "${TARGET_REGISTRY_PASSWORD:-}" ]] || fail "TARGET_REGISTRY_PASSWORD is not set"
fi
[[ "$TLS_VERIFY" == "true" ]] || log "WARNING: TLS verification of the BYO registry is disabled"

WORK_DIR="$(pwd)/mce-odf-mirror-work"
mkdir -p "$WORK_DIR"
AUTH_FILE="$(mktemp)"; chmod 600 "$AUTH_FILE"; echo '{"auths":{}}' > "$AUTH_FILE"
trap 'rm -f "$AUTH_FILE"' EXIT

login() {   # <registry> <user> <password> <tls-verify>
  printf '%s' "$3" | podman login --authfile "$AUTH_FILE" --tls-verify="$4" \
    --username "$2" --password-stdin "$1" >/dev/null || fail "login to $1 failed"
  log "Logged in to $1"
}
login registry.redhat.io "$REDHAT_USERNAME" "$REDHAT_PASSWORD" true
(( DRY_RUN )) || login "${ROOT%%/*}" "$TARGET_REGISTRY_USERNAME" "$TARGET_REGISTRY_PASSWORD" "$TLS_VERIFY"

# ----------------------------- ImageSetConfigurations ------------------------
# MCE (rh-seed): same targetCatalog as mcsp, so the catalog lands at <root>/redhat/redhat-operator-index
cat > "$WORK_DIR/mce.yaml" <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
    - catalog: ${CATALOG}
      targetCatalog: redhat/redhat-operator-index
      packages:
        - name: multicluster-engine
          defaultChannel: stable-2.10
          channels:
            - name: stable-2.10
              minVersion: 2.10.0
              maxVersion: 2.10.6
EOF

# ODF (rh-storage): <root>/redhat/redhat-operator-index-odf
{
  cat <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
    - catalog: ${CATALOG}
      targetCatalog: redhat/redhat-operator-index-odf
      packages:
EOF
  for p in $ODF_PACKAGES; do
    printf '        - name: %s\n          defaultChannel: %s\n          channels:\n            - name: %s\n              minVersion: %s\n              maxVersion: %s\n' \
      "$p" "$ODF_CHANNEL" "$ODF_CHANNEL" "$ODF_VERSION" "$ODF_VERSION"
  done
  printf '        - name: odr-cluster-operator\n        - name: odr-hub-operator\n'
} > "$WORK_DIR/odf.yaml"

# ----------------------------- Mirror ----------------------------------------
mirror() {   # <name> <suffix>
  local name="$1" suffix="$2" ws="$WORK_DIR/$1" f out
  mkdir -p "$ws"
  local cmd=(oc-mirror --v2 --config "$WORK_DIR/$name.yaml" --workspace "file://$ws"
    --authfile "$AUTH_FILE" --dest-tls-verify="$TLS_VERIFY" --ignore-release-signature
    --retry-times 5 --retry-delay 10s)
  (( DRY_RUN )) && cmd+=(--dry-run)
  log "=== $name -> docker://$ROOT ==="
  "${cmd[@]}" "docker://$ROOT"

  (( DRY_RUN )) && return 0
  # Prefix/suffix the generated resource names (same convention as mcsp mirror.sh)
  # so they cannot overwrite the IDMS/ITMS/CatalogSources of other mirror runs.
  out="$WORK_DIR/cluster-resources/$suffix"; mkdir -p "$out"
  for f in "$ws"/working-dir/cluster-resources/*.yaml; do
    [[ -e "$f" ]] || continue
    sed -E "/^metadata:/,/^  name:/ s/^(  name: )sovcloud-(.*)$/\1\2/; /^metadata:/,/^  name:/ s/^(  name: )(.+)$/\1sovcloud-\2-${suffix}/" \
      "$f" > "$out/$(basename "$f")"
  done
}

mirror mce rh-seed
mirror odf rh-storage

# ----------------------------- Apply -----------------------------------------
if (( DRY_RUN )); then
  log "Dry run finished; nothing was pushed."
elif (( APPLY )); then
  log "Applying cluster resources"
  oc apply -f "$WORK_DIR/cluster-resources" --recursive
  log "IDMS/ITMS trigger a MachineConfigPool roll-out; wait with: oc wait --for=condition=Updated mcp --all --timeout=120m"
else
  log "Apply with: oc apply -f $WORK_DIR/cluster-resources --recursive"
fi
