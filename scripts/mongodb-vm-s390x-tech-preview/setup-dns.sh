#!/usr/bin/env bash
# setup-dns.sh
#
# Usage: ./setup-dns.sh [-y|--yes|--no-prompt] <HOSTNAME_FQDN> <RESOLVE_IP>
#
# Options:
#   -y, --yes, --no-prompt   Disable all interactive prompts (settings confirmation,
#                            bastion IP selection, unreachable-host confirmation).
#   -h, --help               Show usage.
#
# What it does:
#   1. Checks if RESOLVE_IP is pingable
#   2. Installs dnsmasq if not present
#   3. Adds the A-record to dnsmasq drop-in config
#   4. Ensures 127.0.0.1 is first in /etc/resolv.conf (persisted via NetworkManager)
#   5. Restarts dnsmasq
#   6. Verifies ping + nslookup from bastion
#   7. Patches OCP CoreDNS operator to forward the zone to this bastion
#   8. Waits for CoreDNS rollout
#
# Env overrides (optional):
#   FORWARD_ZONE   - DNS zone to forward (default: auto-derived from HOSTNAME_FQDN)
#   BASTION_IP     - IP dnsmasq listens on and CoreDNS forwards to; skips the selection
#                    prompt. Use the bastion's PRIVATE IP. (default: you select from the
#                    detected local IPs; with --no-prompt the first private IP is used)
#   DNSMASQ_CONF   - drop-in conf file path (default: /etc/dnsmasq.d/ocp-custom.conf)

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
usage() { echo "Usage: $0 [-y|--yes|--no-prompt] <HOSTNAME_FQDN> <RESOLVE_IP>"; }

PROMPT=true
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes|--no-prompt) PROMPT=false; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option '$1'"; usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

[[ $# -eq 2 ]] || { usage; exit 1; }
HOSTNAME_FQDN="$1"
RESOLVE_IP="$2"

# ---------------------------------------------------------------------------
# Basic Validation & Confirmation
# ---------------------------------------------------------------------------
if [[ "$HOSTNAME_FQDN" != *.* ]]; then
  echo "ERROR: HOSTNAME_FQDN must contain at least one dot (e.g. api.cluster.example.com). Got: '${HOSTNAME_FQDN}'"
  exit 1
fi

if ! [[ "$RESOLVE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "ERROR: RESOLVE_IP must be an IPv4 address. Got: '${RESOLVE_IP}'"
  exit 1
fi

FORWARD_ZONE="${FORWARD_ZONE:-$(echo "$HOSTNAME_FQDN" | cut -d'.' -f2-)}"

echo "--------------------------------------------"
echo "  FQDN to add  : ${HOSTNAME_FQDN}"
echo "  Resolves to  : ${RESOLVE_IP}"
echo "  Forward Zone : ${FORWARD_ZONE}"
echo "--------------------------------------------"
if $PROMPT; then
  read -rp "Proceed with these settings? [Y/n] " CONFIRM
  CONFIRM="${CONFIRM:-y}"
  [[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 1; }
fi

# Discover available IPv4 addresses on the bastion (excluding loopback)
DETECTED_IPS=()
if command -v ip &>/dev/null; then
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && DETECTED_IPS+=("$ip")
  done < <(ip -4 addr show 2>/dev/null | awk '/inet / && !/127\.0\.0\.1/{print $2}' | cut -d'/' -f1 | sort -u)
fi

if [[ ${#DETECTED_IPS[@]} -eq 0 ]] && command -v hostname &>/dev/null; then
  for ip in $(hostname -I 2>/dev/null); do
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && DETECTED_IPS+=("$ip")
  done
fi

# RFC1918 private ranges: 10/8, 172.16/12, 192.168/16
is_private_ip() {
  local a b
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  a=$((10#${BASH_REMATCH[1]}))
  b=$((10#${BASH_REMATCH[2]}))
  (( a == 10 )) || (( a == 172 && b >= 16 && b <= 31 )) || (( a == 192 && b == 168 ))
}
ip_label() { if is_private_ip "$1"; then echo "private"; else echo "public/non-RFC1918"; fi; }

# Determine BASTION_IP (the IP dnsmasq listens on and CoreDNS forwards to):
# 1. If BASTION_IP env is set, use it directly (no selection).
# 2. Otherwise list all detected IPs (marked private/public) and ask the user
#    to select one; pressing Enter accepts the default (first private IP).
# 3. With --no-prompt, the default (first private IP, else first IP) is used.
if [[ -z "${BASTION_IP:-}" ]]; then
  if [[ ${#DETECTED_IPS[@]} -eq 0 ]]; then
    echo "ERROR: Could not detect any valid IPv4 address. Please set BASTION_IP=<ip> env var."
    exit 1
  fi

  # Default selection: first private IP, falling back to the first detected IP
  DEFAULT_IDX=0
  for i in "${!DETECTED_IPS[@]}"; do
    if is_private_ip "${DETECTED_IPS[$i]}"; then DEFAULT_IDX=$i; break; fi
  done

  if $PROMPT; then
    echo
    echo "IP addresses detected on this host:"
    for i in "${!DETECTED_IPS[@]}"; do
      mark=""; [[ $i -eq $DEFAULT_IDX ]] && mark="  <- default"
      echo "  [$((i+1))] ${DETECTED_IPS[$i]}  ($(ip_label "${DETECTED_IPS[$i]}"))${mark}"
    done
    echo
    while true; do
      read -rp "Select the bastion IP to listen on and forward to [1-${#DETECTED_IPS[@]}] (default $((DEFAULT_IDX+1))): " CHOICE
      CHOICE="${CHOICE:-$((DEFAULT_IDX+1))}"
      if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#DETECTED_IPS[@]} )); then
        BASTION_IP="${DETECTED_IPS[$((CHOICE-1))]}"
        break
      else
        echo "Invalid selection. Please choose a number between 1 and ${#DETECTED_IPS[@]}."
      fi
    done
  else
    BASTION_IP="${DETECTED_IPS[$DEFAULT_IDX]}"
  fi
fi

if ! [[ "$BASTION_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "ERROR: BASTION_IP must be an IPv4 address. Got: '${BASTION_IP}'"
  exit 1
fi

echo "  -> Using Bastion IP: ${BASTION_IP} ($(ip_label "$BASTION_IP"))"
if ! is_private_ip "$BASTION_IP"; then
  echo "  [!!]  ${BASTION_IP} is not a private (RFC1918) address"
fi

DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/dnsmasq.d/ocp-custom.conf}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo "  [OK]  $*"; }
warn()    { echo "  [!!]  $*"; }
section() { echo; echo "==> $*"; }

# ---------------------------------------------------------------------------
# Step 1 — Ping check
# ---------------------------------------------------------------------------
section "Step 1: Checking if ${RESOLVE_IP} is reachable"
if ping -c2 -W2 "$RESOLVE_IP" &>/dev/null; then
  info "${RESOLVE_IP} is pingable — proceeding"
else
  warn "${RESOLVE_IP} is NOT reachable (ICMP blocked or host is down)"
  warn "DNS records will still be configured, but the host may not respond"
  if $PROMPT; then
    read -rp "  Continue anyway? [y/N] " CONT
    [[ "${CONT,,}" == "y" ]] || { echo "Aborted."; exit 1; }
  else
    warn "Prompting disabled — continuing anyway"
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — Install dnsmasq
# ---------------------------------------------------------------------------
section "Step 2: Ensuring dnsmasq is installed"
if command -v dnsmasq &>/dev/null; then
  info "dnsmasq already installed: $(dnsmasq --version 2>&1 | head -1)"
else
  info "Installing dnsmasq..."
  if command -v dnf &>/dev/null;  then dnf install -y dnsmasq
  elif command -v yum &>/dev/null; then yum install -y dnsmasq
  elif command -v apt-get &>/dev/null; then apt-get install -y dnsmasq
  else echo "ERROR: cannot detect package manager — install dnsmasq manually"; exit 1
  fi
  info "dnsmasq installed"
fi

# ---------------------------------------------------------------------------
# Step 3 — Configure dnsmasq listening & add A-record
# ---------------------------------------------------------------------------
section "Step 3: Configuring dnsmasq listening & A-record in ${DNSMASQ_CONF}"
mkdir -p "$(dirname "$DNSMASQ_CONF")"

# Configure dnsmasq to listen on 127.0.0.1 and the chosen BASTION_IP
DNSMASQ_LISTEN_CONF="/etc/dnsmasq.d/00-listen.conf"
cat > "$DNSMASQ_LISTEN_CONF" <<EOF
# Listen on localhost and chosen bastion interface IP
listen-address=127.0.0.1,${BASTION_IP}
bind-interfaces
EOF
info "Configured ${DNSMASQ_LISTEN_CONF} with listen-address=127.0.0.1,${BASTION_IP}"

RECORD="address=/${HOSTNAME_FQDN}/${RESOLVE_IP}"

if [[ -f "$DNSMASQ_CONF" ]] && grep -qF "address=/${HOSTNAME_FQDN}/" "$DNSMASQ_CONF"; then
  OLD=$(grep "address=/${HOSTNAME_FQDN}/" "$DNSMASQ_CONF")
  if [[ "$OLD" == "$RECORD" ]]; then
    info "Record already correct — no change needed"
  else
    sed -i "s|address=/${HOSTNAME_FQDN}/.*|${RECORD}|" "$DNSMASQ_CONF"
    info "Updated: ${OLD} -> ${RECORD}"
  fi
else
  echo "$RECORD" >> "$DNSMASQ_CONF"
  info "Appended: ${RECORD}"
fi

# ---------------------------------------------------------------------------
# Step 4 — Ensure 127.0.0.1 is first in /etc/resolv.conf
# ---------------------------------------------------------------------------
section "Step 4: Ensuring 127.0.0.1 is first nameserver in /etc/resolv.conf"

if head -5 /etc/resolv.conf | grep -q "^nameserver 127.0.0.1"; then
  info "127.0.0.1 already present in resolv.conf"
else
  # Prepend 127.0.0.1 as the first nameserver
  cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%s)
  sed -i '0,/^nameserver/s/^nameserver/nameserver 127.0.0.1\nnameserver/' /etc/resolv.conf
  info "Prepended nameserver 127.0.0.1 to /etc/resolv.conf"
fi

# Persist via NetworkManager so it survives reboots
NM_DROP_IN="/etc/NetworkManager/conf.d/99-dnsmasq-prepend.conf"
if [[ ! -f "$NM_DROP_IN" ]]; then
  cat > "$NM_DROP_IN" <<'EOF'
[main]
dns=none
EOF
  info "Created ${NM_DROP_IN} (prevents NetworkManager from overwriting resolv.conf)"
  systemctl reload NetworkManager 2>/dev/null || true
else
  info "${NM_DROP_IN} already exists"
fi

# ---------------------------------------------------------------------------
# Step 5 — Enable + restart dnsmasq
# ---------------------------------------------------------------------------
section "Step 5: Enabling and restarting dnsmasq"
systemctl enable dnsmasq --quiet
systemctl restart dnsmasq
sleep 1
if systemctl is-active --quiet dnsmasq; then
  info "dnsmasq is running"
else
  echo "ERROR: dnsmasq failed to start"
  journalctl -u dnsmasq --no-pager -n 20
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 6 — Verify from bastion: ping + nslookup + port 53 firewall check
# ---------------------------------------------------------------------------
section "Step 6: Verifying DNS resolution & firewall from bastion"

# Open port 53 on firewalld if active
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
  if ! firewall-cmd --list-services 2>/dev/null | grep -qw "dns"; then
    info "Opening DNS service in firewalld..."
    firewall-cmd --add-service=dns --permanent --quiet 2>/dev/null || true
    firewall-cmd --reload --quiet 2>/dev/null || true
    info "Firewalld DNS service enabled"
  else
    info "Firewalld DNS service already permitted"
  fi
fi

RESOLVED=$(dig +short @"${BASTION_IP}" "$HOSTNAME_FQDN" 2>/dev/null || true)
if [[ "$RESOLVED" == "$RESOLVE_IP" ]]; then
  info "dig @${BASTION_IP} ${HOSTNAME_FQDN} => ${RESOLVED}"
else
  warn "dig @${BASTION_IP} returned '${RESOLVED}' (expected ${RESOLVE_IP})"
fi

RESOLVED_LOCAL=$(dig +short @127.0.0.1 "$HOSTNAME_FQDN" 2>/dev/null || true)
if [[ "$RESOLVED_LOCAL" == "$RESOLVE_IP" ]]; then
  info "dig @127.0.0.1 ${HOSTNAME_FQDN} => ${RESOLVED_LOCAL}"
fi

RESOLVED_OS=$(getent hosts "$HOSTNAME_FQDN" 2>/dev/null | awk '{print $1}' || true)
if [[ "$RESOLVED_OS" == "$RESOLVE_IP" ]]; then
  info "OS resolver (getent) ${HOSTNAME_FQDN} => ${RESOLVED_OS}"
else
  warn "OS resolver returned '${RESOLVED_OS}' (expected ${RESOLVE_IP}) — resolv.conf may need a shell restart"
fi

if ping -c1 -W2 "$HOSTNAME_FQDN" &>/dev/null; then
  info "ping ${HOSTNAME_FQDN} => OK"
else
  warn "ping ${HOSTNAME_FQDN} failed — host may block ICMP but DNS is working"
fi

# ---------------------------------------------------------------------------
# Step 7 — Apply/upsert ACM dns-hub-only-policy (scoped to local-cluster only)
# ---------------------------------------------------------------------------
# Forwarding spoke zones must be applied only on the Hub (local-cluster) so
# they are NEVER propagated to managed/spoke clusters.
# Strategy:
#   - PlacementRule targets only local-cluster (hub).
#   - PlacementBinding + Policy are idempotent: oc apply is safe on re-runs.
#   - The servers list inside the ConfigurationPolicy is rebuilt from the live
#     state on every run: existing entries are preserved, the new zone is
#     appended (or updated in-place if the entry name already exists).
#   - The full Policy manifest is re-applied via `oc apply`, which avoids
#     fragile JSON-patch path arithmetic and handles the first-run / nth-run
#     cases uniformly.
# ---------------------------------------------------------------------------
section "Step 7: Configuring ACM dns-hub-only-policy (namespace: gori-dns)"

if ! command -v oc &>/dev/null; then
  warn "'oc' not found — skipping CoreDNS patch (run manually or add oc to PATH)"
elif ! oc whoami &>/dev/null 2>&1; then
  warn "Not logged into OCP cluster — skipping CoreDNS patch (run 'oc login' first)"
else
  info "Logged in as: $(oc whoami)"
  info "Bastion IP for CoreDNS upstream: ${BASTION_IP}"
  info "Forward zone: ${FORWARD_ZONE}"

  # Derive a safe ACM server entry name from the zone (replace dots/special chars with dashes)
  ENTRY_NAME="${FORWARD_ZONE//[^a-zA-Z0-9]/-}"

  # ── Namespace ──────────────────────────────────────────────────────────────
  if ! oc get namespace gori-dns &>/dev/null; then
    info "Creating namespace gori-dns..."
    oc create namespace gori-dns
  else
    info "Namespace gori-dns already exists"
  fi

  # ── PlacementRule (hub-only target) ───────────────────────────────────────
  oc apply -f - <<'EOF'
apiVersion: apps.open-cluster-management.io/v1
kind: PlacementRule
metadata:
  name: dns-hub-only-placement-rule
  namespace: gori-dns
spec:
  clusterSelector:
    matchExpressions:
    - key: name
      operator: In
      values:
      - local-cluster
EOF
  info "PlacementRule dns-hub-only-placement-rule applied (hub-only)"

  # ── PlacementBinding ──────────────────────────────────────────────────────
  oc apply -f - <<'EOF'
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: dns-hub-only-placement-binding
  namespace: gori-dns
placementRef:
  apiGroup: apps.open-cluster-management.io
  kind: PlacementRule
  name: dns-hub-only-placement-rule
subjects:
- apiGroup: policy.open-cluster-management.io
  kind: Policy
  name: dns-hub-only-policy
EOF
  info "PlacementBinding dns-hub-only-placement-binding applied"

  # ── Build updated servers list ─────────────────────────────────────────────
  # Read live servers from the policy (empty list if policy does not yet exist).
  # Then upsert the new entry: update in-place if the entry name matches,
  # otherwise append.  Zones within an existing entry are also deduplicated.
  # The ACTION variable written to stderr drives the log message below.

  EXISTING_SERVERS_JSON="[]"
  if oc get policy dns-hub-only-policy -n gori-dns &>/dev/null; then
    EXISTING_SERVERS_JSON=$(oc get policy dns-hub-only-policy -n gori-dns -o json \
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

  # Upsert: compute the new servers list and the action taken
  UPSERT_RESULT=$(python3 -c "
import sys, json

servers = json.loads('''${EXISTING_SERVERS_JSON}''')

new_entry = {
    'name':          '${ENTRY_NAME}',
    'zones':         ['${FORWARD_ZONE}'],
    'forwardPlugin': {'policy': 'Random', 'upstreams': ['${BASTION_IP}']}
}

action = 'added'
found  = False
for i, s in enumerate(servers):
    if s.get('name') == new_entry['name']:
        # Deduplicate zones: keep existing zones, add new one only if absent
        existing_zones = s.get('zones') or []
        if '${FORWARD_ZONE}' not in existing_zones:
            existing_zones.append('${FORWARD_ZONE}')
            action = 'updated'
        else:
            # Zone already present — check if upstream also matches
            existing_ups = (s.get('forwardPlugin') or {}).get('upstreams') or []
            if existing_ups == ['${BASTION_IP}']:
                action = 'no-change'
            else:
                action = 'updated'
        # Rebuild entry with merged zones + current bastion IP
        servers[i] = {
            'name':          '${ENTRY_NAME}',
            'zones':         existing_zones,
            'forwardPlugin': {'policy': 'Random', 'upstreams': ['${BASTION_IP}']}
        }
        found = True
        break

if not found:
    servers.append(new_entry)

print(json.dumps({'action': action, 'servers': servers}))
" 2>/dev/null)

  DNS_ACTION=$(python3 -c "import sys,json; print(json.loads(sys.argv[1])['action'])" "${UPSERT_RESULT}" 2>/dev/null || echo "added")
  UPDATED_SERVERS=$(python3 -c "import sys,json; print(json.dumps(json.loads(sys.argv[1])['servers']))" "${UPSERT_RESULT}" 2>/dev/null || echo "[]")

  if [[ "$DNS_ACTION" == "no-change" ]]; then
    info "Zone '${FORWARD_ZONE}' already present in dns-hub-only-policy — no change needed"
  else
    # ── Apply full Policy manifest (safe on first run and on nth re-run) ──────
    # Building the complete manifest from the updated servers list and applying
    # it with `oc apply` is idempotent and avoids fragile JSON-patch paths.
    POLICY_YAML=$(python3 -c "
import sys, json, yaml

servers = json.loads(sys.argv[1])

manifest = {
    'apiVersion': 'policy.open-cluster-management.io/v1',
    'kind': 'Policy',
    'metadata': {
        'name':      'dns-hub-only-policy',
        'namespace': 'gori-dns',
    },
    'spec': {
        'disabled':           False,
        'remediationAction':  'enforce',
        'copyPolicyMetadata': False,
        'policy-templates': [{
            'objectDefinition': {
                'apiVersion': 'policy.open-cluster-management.io/v1',
                'kind':       'ConfigurationPolicy',
                'metadata':   {'name': 'dns-hub-only-config'},
                'spec': {
                    'remediationAction': 'enforce',
                    'severity':          'high',
                    'object-templates': [{
                        'complianceType': 'musthave',
                        'objectDefinition': {
                            'apiVersion': 'operator.openshift.io/v1',
                            'kind':       'DNS',
                            'metadata':   {'name': 'default'},
                            'spec':       {'servers': servers},
                        },
                    }],
                },
            },
        }],
    },
}
print(yaml.dump(manifest, default_flow_style=False, allow_unicode=True))
" "${UPDATED_SERVERS}" 2>/dev/null)

    if [[ -z "$POLICY_YAML" ]]; then
      warn "python3 yaml module not available — falling back to oc patch"
      oc patch policy dns-hub-only-policy -n gori-dns --type=merge \
        -p="{\"spec\":{\"policy-templates\":[{\"objectDefinition\":{\"spec\":{\"object-templates\":[{\"complianceType\":\"musthave\",\"objectDefinition\":{\"apiVersion\":\"operator.openshift.io/v1\",\"kind\":\"DNS\",\"metadata\":{\"name\":\"default\"},\"spec\":{\"servers\":${UPDATED_SERVERS}}}}]}}}]}}"
    else
      echo "$POLICY_YAML" | oc apply -f -
    fi

    if [[ "$DNS_ACTION" == "added" ]]; then
      info "Zone '${FORWARD_ZONE}' added to dns-hub-only-policy"
    else
      info "Zone '${FORWARD_ZONE}' updated in dns-hub-only-policy"
    fi
  fi

  info "ACM config-policy-controller will enforce this on hub dns.operator/default (not propagated to spokes)"

  # ---------------------------------------------------------------------------
  # Step 8 — Wait for CoreDNS rollout
  # ---------------------------------------------------------------------------
  section "Step 8: Waiting for CoreDNS daemonset rollout"
  oc rollout status daemonset/dns-default -n openshift-dns --timeout=120s \
    && info "CoreDNS rollout complete" \
    || warn "Rollout timed out — check: oc get pods -n openshift-dns"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "============================================"
echo " Setup complete"
echo "============================================"
echo "  FQDN       : ${HOSTNAME_FQDN}"
echo "  Resolves to: ${RESOLVE_IP}"
echo "  Zone fwd   : ${FORWARD_ZONE} -> ${BASTION_IP}:53"
echo "  dnsmasq cfg: ${DNSMASQ_CONF}"
echo
echo "Test from a cluster pod:"
echo "  oc run dns-test --rm -it --image=registry.redhat.io/ubi9/ubi-minimal:latest \\"
echo "    --restart=Never -- nslookup ${HOSTNAME_FQDN}"
echo "============================================"