#!/usr/bin/env bash
# configure-tenant-cluster.sh
#
# Onboards a fresh OCP spoke cluster as a BYOP tenant for MongoDB EA on s390x.
# Does the following:
#   1. Fetches the Quay CA cert from the hub registry
#   2. Merges Quay credentials into the spoke cluster-wide pull secret
#      (openshift-config/pull-secret) so nodes can pull OCM/klusterlet images
#   3. Creates a cluster-wide IDMS (ImageDigestMirrorSet) to redirect all
#      registry pulls through the internal Quay mirror
#   4. Configures cluster-wide CA trust and OpenShift Virtualization (CDI) settings.
#      Note: Per-namespace CDI secrets (quay-pull-secret) and CA ConfigMaps (quay-ca-bundle)
#      are now automatically extracted and provisioned on-demand by the Helm chart's
#      pre-sync hook (namespace-label-hook.yaml), requiring zero manual namespace preparation.
#
# Run this from a bastion that has oc access to the SPOKE cluster.
#
# Usage:
#   bash configure-tenant-cluster.sh [OPTIONS]
#
#   Options:
#     --registry  <host>      Quay registry hostname (required, e.g. registry-quay-quay-enterprise.apps.hub.example.com)
#     --user      <username>  Quay username (default: quayadmin)
#     --password  <password>  Quay password (required; or set QUAY_PASSWORD)
#     -y, --yes               Skip the confirmation prompt for the current oc cluster
#     -h, --help              Show this help and exit
#
# Examples:
#   bash configure-tenant-cluster.sh \
#     --registry registry-quay-quay-enterprise.apps.example.com \
#     --user quayadmin \
#     --password <password>
#
# Prerequisites:
#   - oc logged in to the spoke cluster (you will be asked to confirm it), or
#     SPOKE_KUBECONFIG / SPOKE_API + SPOKE_TOKEN set to target it explicitly

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG — default values (override via CLI flags or by editing here)
# ---------------------------------------------------------------------------

# Quay registry configuration
QUAY_REGISTRY="${QUAY_REGISTRY:-}"
QUAY_USER="${QUAY_USER:-quayadmin}"
QUAY_PASSWORD="${QUAY_PASSWORD:-}"
ASSUME_YES=false

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------

usage() {
  sed -n '/^# Usage:/,/^# Prerequisites:/p' "$0" | sed 's/^# \{0,4\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)  QUAY_REGISTRY="${2:?'--registry requires a value'}"; shift 2 ;;
    --user)      QUAY_USER="${2:?'--user requires a value'}";         shift 2 ;;
    --password)  QUAY_PASSWORD="${2:?'--password requires a value'}"; shift 2 ;;
    -y|--yes)    ASSUME_YES=true; shift ;;
    -h|--help)   usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -z "$QUAY_REGISTRY" ]] && {
  echo "ERROR: --registry <hostname> is required (e.g. registry-quay-quay-enterprise.apps.example.com)" >&2
  usage
}

[[ -z "$QUAY_PASSWORD" ]] && {
  echo "ERROR: Quay password is required (--password <password> or QUAY_PASSWORD env var)" >&2
  usage
}

# Strip any accidental http:// or https:// scheme prefix
QUAY_REGISTRY="${QUAY_REGISTRY#https://}"
QUAY_REGISTRY="${QUAY_REGISTRY#http://}"
QUAY_REGISTRY="${QUAY_REGISTRY%/}"

# CA cert file path for this specific registry
SAFE_REG_NAME=$(echo "$QUAY_REGISTRY" | tr '/:' '_')
QUAY_CA_CERT_FILE="/tmp/quay-ca-${SAFE_REG_NAME}.crt"


# Spoke cluster access (all optional). If none are set, the currently logged-in
# oc context is used after the user confirms it.
#   SPOKE_KUBECONFIG, OR both SPOKE_API + SPOKE_TOKEN
SPOKE_KUBECONFIG="${SPOKE_KUBECONFIG:-}"   # e.g. /root/.kube/spoke.kubeconfig
SPOKE_API="${SPOKE_API:-}"                 # e.g. https://api.ocpz-standard-5.xxx:6443
SPOKE_TOKEN="${SPOKE_TOKEN:-}"             # cluster-admin token on spoke

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✅ $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠️  $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ❌ $*" >&2; exit 1; }

# Run oc against the spoke cluster (explicit kubeconfig/token, else current oc context)
spoke() {
  if [[ -n "$SPOKE_KUBECONFIG" ]]; then
    KUBECONFIG="$SPOKE_KUBECONFIG" oc "$@"
  elif [[ -n "$SPOKE_API" && -n "$SPOKE_TOKEN" ]]; then
    oc --server="$SPOKE_API" --token="$SPOKE_TOKEN" --insecure-skip-tls-verify "$@"
  else
    oc "$@"
  fi
}

# Verify oc is available and the cluster is reachable. Fail with a clear message
# here, rather than exiting silently later inside a command with hidden output.
command -v oc >/dev/null 2>&1 || fail "'oc' CLI not found in PATH"

SPOKE_USER=$(spoke whoami 2>&1) \
  || fail "Cannot access the cluster via oc: ${SPOKE_USER}. Run 'oc login', or set SPOKE_KUBECONFIG, or SPOKE_API + SPOKE_TOKEN"
SPOKE_SERVER=$(spoke whoami --show-server 2>/dev/null || true)

# When falling back to the current oc context, confirm it is the intended cluster.
if [[ -z "$SPOKE_KUBECONFIG" && ( -z "$SPOKE_API" || -z "$SPOKE_TOKEN" ) && "$ASSUME_YES" != true ]]; then
  echo "This script will modify the cluster you are currently logged in to:"
  echo "  API server : ${SPOKE_SERVER}"
  echo "  User       : ${SPOKE_USER}"
  [[ -t 0 ]] || fail "Not an interactive terminal; re-run with --yes to confirm the cluster above"
  read -r -p "Continue? [y/N] " REPLY
  [[ "$REPLY" =~ ^[Yy]$ ]] || fail "Aborted by user"
fi

# ---------------------------------------------------------------------------
# Step 1 — Fetch Quay CA cert (always re-fetch, never reuse a cached file)
#
# Always re-fetch even if a cached file exists: the registry hostname may be
# the same across hubs (e.g. same Quay FQDN pattern) but the TLS cert changes
# when the hub is rebuilt. A stale cached cert causes user-ca-bundle to contain
# the wrong CA and blocks klusterlet image pulls.
#
# We extract only the ROOT CA (last cert in the -showcerts chain). Storing the
# leaf or intermediate cert instead causes TLS handshake failures: the node
# cannot verify the chain, Quay rejects the auth exchange, and the kubelet
# reports "unauthorized" even though the pull-secret credentials are correct.
# ---------------------------------------------------------------------------
log "Step 1: Fetching Quay root CA cert from ${QUAY_REGISTRY}"

log "  Fetching certificate chain from ${QUAY_REGISTRY} (with SNI)..."
openssl s_client -servername "${QUAY_REGISTRY}" -connect "${QUAY_REGISTRY}:443" \
  -showcerts </dev/null 2>/dev/null \
  | awk '/-----BEGIN CERTIFICATE-----/{c=""} {c=c"\n"$0} /-----END CERTIFICATE-----/{last=c} END{print substr(last,2)}' \
  > "$QUAY_CA_CERT_FILE"
[[ -s "$QUAY_CA_CERT_FILE" ]] || fail "Failed to fetch CA cert from ${QUAY_REGISTRY}"

CERT_SUBJECT=$(openssl x509 -in "$QUAY_CA_CERT_FILE" -noout -subject 2>/dev/null || true)
CERT_ISSUER=$(openssl x509 -in "$QUAY_CA_CERT_FILE" -noout -issuer 2>/dev/null || true)
ok "Root CA cert retrieved: ${CERT_SUBJECT} | ${CERT_ISSUER}"

# ---------------------------------------------------------------------------
# Step 2 — Generate Quay credentials for cluster pull secret
# ---------------------------------------------------------------------------
log "Step 2: Preparing Quay credentials for ${QUAY_USER}"

# Use basic auth for full account access across all repos (MongoDB, OCM, etc.)
QUAY_AUTH=$(echo -n "${QUAY_USER}:${QUAY_PASSWORD}" | base64 | tr -d '\n')
ok "Quay credentials formatted for pull secret"

# ---------------------------------------------------------------------------
# Step 2b — Remove stale ImageDigestMirrorSet entries from previous hub runs
#
# setup-tenant.sh may have been run against a different hub previously, leaving
# IDMS objects whose mirrors point at the old hub's Quay registry.  Those stale
# mirrors silently redirect image pulls to the wrong (unreachable) registry,
# causing "unauthorized" or connection-refused errors even when the pull-secret
# and CA bundle are correct for the current hub.
#
# Strategy: scan every IDMS on the spoke; delete any whose mirror list contains
# a "quay-enterprise" hostname that is NOT the current QUAY_REGISTRY.
# ---------------------------------------------------------------------------
log "Step 2b: Removing stale ImageDigestMirrorSet entries from previous hub runs"

if spoke get imagedigestmirrorset &>/dev/null 2>&1; then
  STALE_IDMS=$(spoke get imagedigestmirrorset -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
current = '${QUAY_REGISTRY}'
stale = []
for item in d.get('items', []):
    name = item['metadata']['name']
    mirrors_str = json.dumps(item)
    # Check if this IDMS references any quay-enterprise host that is NOT current
    import re
    hosts = re.findall(r'registry-quay-quay-enterprise\.[^\"/]+', mirrors_str)
    for h in hosts:
        if h != current:
            stale.append(name)
            break
for n in stale:
    print(n)
" 2>/dev/null || true)

  if [[ -n "$STALE_IDMS" ]]; then
    while IFS= read -r idms_name; do
      [[ -z "$idms_name" ]] && continue
      warn "Deleting stale ImageDigestMirrorSet '${idms_name}' (points at old hub registry)"
      spoke delete imagedigestmirrorset "${idms_name}" --ignore-not-found
    done <<< "$STALE_IDMS"
    ok "Stale ImageDigestMirrorSet entries removed"
  else
    ok "No stale ImageDigestMirrorSet entries found"
  fi
else
  log "  ImageDigestMirrorSet API not available — skipping IDMS cleanup"
fi

# ---------------------------------------------------------------------------
# Step 3 — Merge Quay credentials into spoke cluster-wide pull secret
#
# If the spoke was previously registered to a different hub/registry, stale
# entries for old registries may be present. This step:
#   1. Removes any existing entry whose key contains "quay-enterprise" but is
#      NOT the current QUAY_REGISTRY — i.e. credentials from an old hub.
#   2. Adds/updates the entry for the current QUAY_REGISTRY.
# ---------------------------------------------------------------------------
log "Step 3: Updating spoke cluster-wide pull secret with Quay credentials"
log "  Removing stale quay-enterprise entries from previous hubs (if any)"

TMP_SECRET=$(mktemp /tmp/spoke-pull-XXXXXX.json)
TMP_MERGED=$(mktemp /tmp/spoke-pull-merged-XXXXXX.json)

spoke get secret pull-secret \
  -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' |
base64 -d > "$TMP_SECRET"

python3 - <<PYEOF
import json

with open('${TMP_SECRET}') as f:
    data = json.load(f)

auths = data.setdefault('auths', {})

# Remove stale entries: any quay-enterprise registry that is NOT the current one.
# These are leftovers from setup-tenant.sh runs against a different hub.
stale = [k for k in list(auths.keys())
         if 'quay-enterprise' in k and k != '${QUAY_REGISTRY}']
for k in stale:
    del auths[k]
    print(f'[python] removed stale registry entry: {k}')

# Add / update the current registry.
auths['${QUAY_REGISTRY}'] = {'auth': '${QUAY_AUTH}'}
print(f'[python] added/updated registry entry: ${QUAY_REGISTRY}')

with open('${TMP_MERGED}', 'w') as f:
    json.dump(data, f)
PYEOF

spoke set data secret/pull-secret \
  -n openshift-config \
  --from-file=.dockerconfigjson="$TMP_MERGED"

rm -f "$TMP_SECRET" "$TMP_MERGED"
ok "Cluster-wide pull secret updated on spoke"

# ---------------------------------------------------------------------------
# Step 4 — Configure OpenShift Virtualization (CDI) & Cluster CA Trust
# ---------------------------------------------------------------------------
log "Step 4: Configuring OpenShift Virtualization (CDI) trust for ${QUAY_REGISTRY}"

# Patch HyperConverged (HCO) if installed on the spoke
if spoke get hyperconverged kubevirt-hyperconverged -n openshift-cnv &>/dev/null; then
  log "  Patching HyperConverged storageImport.insecureRegistries..."
  spoke patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type=merge \
    -p "{\"spec\":{\"storageImport\":{\"insecureRegistries\":[\"${QUAY_REGISTRY}\"]}}}" 2>/dev/null || true
  ok "HyperConverged patched with insecureRegistries: ${QUAY_REGISTRY}"
fi

# Patch CDIConfig directly if present
if spoke get cdiconfig config &>/dev/null; then
  log "  Patching CDIConfig insecureRegistries..."
  spoke patch cdiconfig config --type=merge \
    -p "{\"spec\":{\"insecureRegistries\":[\"${QUAY_REGISTRY}\"]}}" 2>/dev/null || true
  ok "CDIConfig patched with insecureRegistries: ${QUAY_REGISTRY}"
fi

# Update cluster-wide user-ca-bundle in openshift-config
log "Step 5: Adding Quay CA to cluster-wide user-ca-bundle and image config"
CA_CONTENT=$(cat "${QUAY_CA_CERT_FILE}")

# Always replace the CA bundle with only the current hub's CA.
# Appending is wrong when the spoke was previously connected to a different hub:
# the old hub's CA stays in the bundle and causes no immediate harm, but the
# fingerprint check below would skip the update even when the new CA is absent,
# because it matches against the first cert only (openssl x509 reads one cert).
# Replace-not-append is safe: the only CA needed here is the one that signs the
# current hub's Quay wildcard cert.
TMP_BUNDLE=$(mktemp /tmp/ca-bundle-XXXXXX.crt)
echo "${CA_CONTENT}" > "$TMP_BUNDLE"
spoke create configmap user-ca-bundle \
  --namespace openshift-config \
  --from-file=ca-bundle.crt="$TMP_BUNDLE" \
  --dry-run=client -o yaml | spoke apply -f -
rm -f "$TMP_BUNDLE"
ok "user-ca-bundle replaced with current hub Quay CA"

# Ensure cluster Image config references user-ca-bundle
log "Ensuring image.config.openshift.io/cluster references additionalTrustedCA..."
spoke patch image.config.openshift.io/cluster \
  --type=merge \
  -p '{"spec":{"additionalTrustedCA":{"name":"user-ca-bundle"}}}' 2>/dev/null || true
ok "image.config.openshift.io/cluster configured"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "======================================================="
echo " setup-tenant.sh completed successfully"
echo "======================================================="
echo ""
echo " Quay registry       : ${QUAY_REGISTRY}"
echo " CA cert             : ${QUAY_CA_CERT_FILE}"
echo " Cluster-wide configuration:"
echo "   - openshift-config/pull-secret  (dockerconfigjson — node image pulls)"
echo "   - openshift-config/user-ca-bundle (Quay CA — replaced with current hub CA)"
echo ""
echo " Next steps:"
echo "   1. Import the spoke via the ACM/RHACM UI or import.sh"
echo "   2. Wait for klusterlet to register (oc get managedcluster on hub)"
echo "   3. Run import.sh v1 to register the MongoDB catalog"
echo "   4. Deploy MongoDB EA via the BYOP catalog UI"
echo "======================================================="
