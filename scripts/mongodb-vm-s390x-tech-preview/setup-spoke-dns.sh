#!/usr/bin/env bash
# =============================================================================
# setup-spoke-dns.sh
#
# Configures Hub-native DNS resolution for an imported spoke cluster in
# IBM Sovereign Core
# Usage:
#   ./setup-spoke-dns.sh --domain <HOSTNAME_FQDN> --ip <RESOLVE_IP>
#   ./setup-spoke-dns.sh --help
#
# Example:
#   ./setup-spoke-dns.sh --domain api.ocpz-cp4d4-std.tt.testing --ip 10.17.100.50
#
# What it does:
#   1. Derives the zone from HOSTNAME_FQDN (e.g. ocpz-cp4d4-std.tt.testing).
#   2. Creates/updates ConfigMap 'gori-dns-zone-<zone>' in namespace 'gori-dns'.
#   3. Projects the ConfigMap into deployment 'coredns-gori'.
#   4. Upserts ACM 'dns-hub-only-policy' (scoped strictly to 'local-cluster' only)
#      to forward queries for the zone to coredns-gori.
#   5. CoreDNS dynamically loads the zone — zero changes to the landing zone VM.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Formatting helpers
# -----------------------------------------------------------------------------
info()    { echo "  [OK]  $*"; }
warn()    { echo "  [!!]  $*"; }
err()     { echo "  [ERROR] $*" >&2; }
section() { echo; echo "==> $*"; }

usage() {
  cat <<USAGE
Usage:
  $0 --domain <FQDN> --ip <IPV4>
  $0 --help

Configures Hub-native DNS resolution for an imported spoke cluster.

Options:
  -d, --domain <FQDN>   Fully qualified hostname to add (required),
                        e.g. api.ocpz-cp4d4-std.tt.testing
  -i, --ip <IPV4>       IPv4 address the hostname (and *.apps) resolves to (required),
                        e.g. 10.17.100.50
  -h, --help            Show this help text and exit

Example:
  $0 --domain api.ocpz-cp4d4-std.tt.testing --ip 10.17.100.50
USAGE
}

# -----------------------------------------------------------------------------
# Arguments & Validation
# -----------------------------------------------------------------------------
HOSTNAME_FQDN=""
RESOLVE_IP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)
      [[ $# -ge 2 ]] || { err "Option '$1' requires a value"; usage >&2; exit 1; }
      HOSTNAME_FQDN="$2"; shift 2 ;;
    --domain=*)
      HOSTNAME_FQDN="${1#*=}"; shift ;;
    -i|--ip)
      [[ $# -ge 2 ]] || { err "Option '$1' requires a value"; usage >&2; exit 1; }
      RESOLVE_IP="$2"; shift 2 ;;
    --ip=*)
      RESOLVE_IP="${1#*=}"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "Unknown option: '$1'"
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$HOSTNAME_FQDN" || -z "$RESOLVE_IP" ]]; then
  err "Both --domain and --ip are required"
  usage >&2
  exit 1
fi

FORWARD_ZONE="$(echo "$HOSTNAME_FQDN" | cut -d'.' -f2-)"

if [[ "$HOSTNAME_FQDN" != *.* ]]; then
  err "--domain must contain at least one dot (e.g. api.cluster.example.com). Got: '${HOSTNAME_FQDN}'"
  exit 1
fi

if ! [[ "$RESOLVE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  err "--ip must be an IPv4 address. Got: '${RESOLVE_IP}'"
  exit 1
fi

GORI_DNS_NAMESPACE="${GORI_DNS_NAMESPACE:-gori-dns}"
COREDNS_DEPLOYMENT="${COREDNS_DEPLOYMENT:-coredns-gori}"
COREDNS_SERVICE="${COREDNS_SERVICE:-coredns-gori}"

echo "-------------------------------------------------------------------------"
echo "  FQDN to add    : ${HOSTNAME_FQDN}"
echo "  Resolves to    : ${RESOLVE_IP}"
echo "  Forward Zone   : ${FORWARD_ZONE}"
echo "  Hub DNS Target : in-cluster CoreDNS (namespace: ${GORI_DNS_NAMESPACE})"
echo "-------------------------------------------------------------------------"

# -----------------------------------------------------------------------------
# Pre-flight Checks
# -----------------------------------------------------------------------------
section "Step 1: Validating cluster connectivity"

if ! command -v oc &>/dev/null; then
  err "'oc' CLI tool is required but not found in PATH"
  exit 1
fi

if ! oc whoami &>/dev/null; then
  err "Not authenticated to OpenShift cluster. Please run 'oc login' first."
  exit 1
fi

info "Authenticated as: $(oc whoami)"

if ! oc get namespace "$GORI_DNS_NAMESPACE" &>/dev/null; then
  err "Namespace '${GORI_DNS_NAMESPACE}' does not exist on this cluster"
  exit 1
fi
info "Namespace '${GORI_DNS_NAMESPACE}' found"

# Discover coredns-gori service target IP
SVC_CLUSTER_IP=$(oc get svc -n "$GORI_DNS_NAMESPACE" "$COREDNS_SERVICE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
SVC_EXT_IP=$(oc get svc -n "$GORI_DNS_NAMESPACE" "$COREDNS_SERVICE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [[ -z "$SVC_EXT_IP" ]]; then
  SVC_EXT_IP=$(oc get svc -n "$GORI_DNS_NAMESPACE" "$COREDNS_SERVICE" -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null || true)
fi

TARGET_UPSTREAM="${SVC_EXT_IP:-$SVC_CLUSTER_IP}"
if [[ -z "$TARGET_UPSTREAM" ]]; then
  err "Could not determine IP for Service '${COREDNS_SERVICE}' in namespace '${GORI_DNS_NAMESPACE}'"
  exit 1
fi
info "Found coredns-gori service IP: ${TARGET_UPSTREAM}"

# -----------------------------------------------------------------------------
# Step 2: Create/Update Zone ConfigMap in gori-dns
# -----------------------------------------------------------------------------
section "Step 2: Creating/updating zone ConfigMap in ${GORI_DNS_NAMESPACE}"

ZONE_SAFE_NAME=$(echo "$FORWARD_ZONE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/^-//;s/-$//')
CM_NAME="gori-dns-zone-${ZONE_SAFE_NAME}"
SERIAL=$(date +%s)

# Take SOA primary NS and contact from this hub's base-zone ConfigMap, so the
# spoke zone matches whichever hub the script is run against.
SOA_FIELDS=$(oc get configmap -n "$GORI_DNS_NAMESPACE" -l app=gori-dns,zone-type=base -o json \
  | python3 -c "
import sys, json, re
for cm in json.load(sys.stdin).get('items', []):
    for content in (cm.get('data') or {}).values():
        m = re.search(r'\bSOA\s+(\S+)\s+(\S+)', content)
        if m:
            print(m.group(1), m.group(2))
            sys.exit(0)
sys.exit(1)
") || { err "Could not read SOA from the base-zone ConfigMap (labels app=gori-dns,zone-type=base) in '${GORI_DNS_NAMESPACE}'"; exit 1; }
read -r SOA_NS SOA_EMAIL <<<"$SOA_FIELDS"
info "SOA taken from hub base zone: ns=${SOA_NS} contact=${SOA_EMAIL}"

# Extract record prefix (e.g. 'api' from 'api.cluster.example.com')
SUB_RECORD=$(echo "$HOSTNAME_FQDN" | sed "s/\.${FORWARD_ZONE}$//")
[[ "$SUB_RECORD" == "$HOSTNAME_FQDN" ]] && SUB_RECORD="@"

ZONE_FILE_CONTENT="; Zone file for ${FORWARD_ZONE}
\$TTL 3600    ; default TTL for zone
\$ORIGIN ${FORWARD_ZONE}. ; base domain-name
@   IN  SOA  ${SOA_NS} ${SOA_EMAIL} (
    ${SERIAL} ; serial number
    12h        ; refresh
    15m        ; retry
    3w         ; expiry
    2h         ; minimum
    )
; Name server RR
    IN  NS   ${SOA_NS}
; A Records
${SUB_RECORD}         IN  A  ${RESOLVE_IP}
*.apps      IN  A  ${RESOLVE_IP}
"

oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CM_NAME}
  namespace: ${GORI_DNS_NAMESPACE}
  labels:
    app: gori-dns
    managed-by: sov-core-networking
    zone-name: "${FORWARD_ZONE}"
    zone-type: "spoke"
data:
  db.${FORWARD_ZONE}: |
$(echo "$ZONE_FILE_CONTENT" | sed 's/^/    /')
EOF
info "ConfigMap ${CM_NAME} created/updated with record: ${HOSTNAME_FQDN} -> ${RESOLVE_IP}"

# -----------------------------------------------------------------------------
# Step 3: Ensure ConfigMap is projected into deployment coredns-gori
# -----------------------------------------------------------------------------
section "Step 3: Ensuring ConfigMap is mounted in ${COREDNS_DEPLOYMENT}"

HAS_SOURCE=$(oc get deployment "$COREDNS_DEPLOYMENT" -n "$GORI_DNS_NAMESPACE" -o json \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
volumes = d.get('spec', {}).get('template', {}).get('spec', {}).get('volumes', [])
zones_vol = next((v for v in volumes if v.get('name') == 'zones-volume'), None)
sources = (zones_vol.get('projected') or {}).get('sources', []) if zones_vol else []
has_cm = any((s.get('configMap') or {}).get('name') == '${CM_NAME}' for s in sources)
print('true' if has_cm else 'false')
" 2>/dev/null || echo "false")

if [[ "$HAS_SOURCE" == "true" ]]; then
  info "ConfigMap ${CM_NAME} is already mounted in ${COREDNS_DEPLOYMENT}"
else
  info "Mounting ${CM_NAME} into ${COREDNS_DEPLOYMENT}..."
  oc get deployment "$COREDNS_DEPLOYMENT" -n "$GORI_DNS_NAMESPACE" -o json \
    | python3 -c "
import sys, json, subprocess
d = json.load(sys.stdin)
volumes = d.get('spec', {}).get('template', {}).get('spec', {}).get('volumes', [])
for v in volumes:
    if v.get('name') == 'zones-volume':
        sources = v.setdefault('projected', {}).setdefault('sources', [])
        sources.append({'configMap': {'name': '${CM_NAME}', 'optional': True}})
        break
patch = json.dumps({'spec': {'template': {'spec': {'volumes': volumes}}}})
subprocess.run(['oc', 'patch', 'deployment', '${COREDNS_DEPLOYMENT}', '-n', '${GORI_DNS_NAMESPACE}', '--type=strategic', '-p', patch], check=True)
"
  info "Patched ${COREDNS_DEPLOYMENT} successfully"
fi

# -----------------------------------------------------------------------------
# Step 4: Apply/Upsert ACM dns-hub-only-policy (Hub-only scoping)
# -----------------------------------------------------------------------------
section "Step 4: Upserting ACM dns-hub-only-policy (scoped to local-cluster only)"

# Ensure PlacementRule exists targeting only local-cluster
oc apply -f - <<EOF
apiVersion: apps.open-cluster-management.io/v1
kind: PlacementRule
metadata:
  name: dns-hub-only-placement-rule
  namespace: ${GORI_DNS_NAMESPACE}
spec:
  clusterSelector:
    matchExpressions:
    - key: name
      operator: In
      values:
      - local-cluster
EOF

# Ensure PlacementBinding exists
oc apply -f - <<EOF
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: dns-hub-only-placement-binding
  namespace: ${GORI_DNS_NAMESPACE}
placementRef:
  apiGroup: apps.open-cluster-management.io
  kind: PlacementRule
  name: dns-hub-only-placement-rule
subjects:
- apiGroup: policy.open-cluster-management.io
  kind: Policy
  name: dns-hub-only-policy
EOF

# Upsert server entry
EXISTING_SERVERS_JSON="[]"
if oc get policy dns-hub-only-policy -n "$GORI_DNS_NAMESPACE" &>/dev/null; then
  EXISTING_SERVERS_JSON=$(oc get policy dns-hub-only-policy -n "$GORI_DNS_NAMESPACE" -o json \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
try:
    servers = (
        d['spec']['policy-templates'][0]
         ['objectDefinition']['spec']['object-templates'][0]
         ['objectDefinition']['spec'].get('servers') or []
    )
except (KeyError, IndexError):
    servers = []
print(json.dumps(servers))
" 2>/dev/null || echo "[]")
fi

ENTRY_NAME="spoke-${ZONE_SAFE_NAME}"

UPSERT_RESULT=$(python3 -c "
import sys, json

servers = json.loads('''${EXISTING_SERVERS_JSON}''')

new_entry = {
    'name':          '${ENTRY_NAME}',
    'zones':         ['${FORWARD_ZONE}'],
    'forwardPlugin': {'policy': 'Sequential', 'upstreams': ['${TARGET_UPSTREAM}']}
}

action = 'added'
found = False
for i, s in enumerate(servers):
    if s.get('name') == new_entry['name'] or '${FORWARD_ZONE}' in (s.get('zones') or []):
        existing_zones = s.get('zones') or []
        if '${FORWARD_ZONE}' not in existing_zones:
            existing_zones.append('${FORWARD_ZONE}')
            action = 'updated'
        servers[i] = {
            'name':          s.get('name', '${ENTRY_NAME}'),
            'zones':         existing_zones,
            'forwardPlugin': {'policy': 'Sequential', 'upstreams': ['${TARGET_UPSTREAM}']}
        }
        found = True
        break

if not found:
    servers.append(new_entry)

print(json.dumps({'action': action, 'servers': servers}))
" 2>/dev/null)

DNS_ACTION=$(python3 -c "import sys,json; print(json.loads(sys.argv[1])['action'])" "${UPSERT_RESULT}" 2>/dev/null || echo "added")
UPDATED_SERVERS=$(python3 -c "import sys,json; print(json.dumps(json.loads(sys.argv[1])['servers']))" "${UPSERT_RESULT}" 2>/dev/null || echo "[]")

python3 -c "
import sys, json, yaml, subprocess

servers = json.loads(sys.argv[1])
manifest = {
    'apiVersion': 'policy.open-cluster-management.io/v1',
    'kind': 'Policy',
    'metadata': {
        'name': 'dns-hub-only-policy',
        'namespace': '${GORI_DNS_NAMESPACE}',
    },
    'spec': {
        'disabled': False,
        'remediationAction': 'enforce',
        'copyPolicyMetadata': False,
        'policy-templates': [{
            'objectDefinition': {
                'apiVersion': 'policy.open-cluster-management.io/v1',
                'kind': 'ConfigurationPolicy',
                'metadata': {'name': 'dns-hub-only-config'},
                'spec': {
                    'remediationAction': 'enforce',
                    'severity': 'high',
                    'object-templates': [{
                        'complianceType': 'musthave',
                        'objectDefinition': {
                            'apiVersion': 'operator.openshift.io/v1',
                            'kind': 'DNS',
                            'metadata': {'name': 'default'},
                            'spec': {'servers': servers},
                        },
                    }],
                },
            },
        }],
    },
}
p = subprocess.Popen(['oc', 'apply', '-f', '-'], stdin=subprocess.PIPE, text=True)
p.communicate(input=yaml.dump(manifest, default_flow_style=False))
if p.returncode != 0:
    sys.exit(p.returncode)
" "${UPDATED_SERVERS}"

info "Policy dns-hub-only-policy updated (${DNS_ACTION}) for zone '${FORWARD_ZONE}'"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo "========================================================================="
echo " Setup complete (Hub-native DNS)"
echo "========================================================================="
echo "  FQDN       : ${HOSTNAME_FQDN}"
echo "  Resolves to: ${RESOLVE_IP}"
echo "  Zone       : ${FORWARD_ZONE}"
echo "========================================================================="
