#!/bin/bash
# =============================================================================
# /usr/local/bin/mongo-pod-alias.sh
# =============================================================================
# Re-creates the pod-IP loopback alias on EVERY boot, before mongod starts.
#
# KubeVirt masquerade NAT: the VM's own pod IP is not on any interface, so
# mongod's replica-set isSelf check (resolve own FQDN -> connect to that IP)
# gets "Connection refused" and the node cannot find itself in the RS config.
# mongo-first-boot.sh adds the alias once, but `ip addr add` is not persistent,
# so after a VM restart (failover) the node would never rejoin without this.
#
# The alias is resolved from the headless-service FQDN at boot, so a changed
# pod IP (VM stopped/started -> new pod) is handled too.
#
# /etc/mongo-rs-self (host:port of this member) is written by mongo-first-boot.sh.
# =============================================================================
set -u
SELF_FILE=/etc/mongo-rs-self
[ -s "$SELF_FILE" ] || exit 0

SELF_HOST=$(cut -d: -f1 < "$SELF_FILE" | tr -d '[:space:]')
[ -n "$SELF_HOST" ] || exit 0

SELF_IP=""
for i in $(seq 1 24); do
  SELF_IP=$(python3.12 -c "
import socket, sys
print(socket.getaddrinfo(sys.argv[1], 27017, socket.AF_INET)[0][4][0])
" "$SELF_HOST" 2>/dev/null || true)
  [ -n "$SELF_IP" ] && break
  echo "[mongo-pod-alias] ${SELF_HOST} not resolvable yet ($i/24)..."
  sleep 5
done

if [ -z "$SELF_IP" ]; then
  echo "[mongo-pod-alias] ERROR: could not resolve ${SELF_HOST} — mongod isSelf check may fail" >&2
  exit 1
fi

# 'replace' is idempotent (no error if the address is already present).
ip addr replace "${SELF_IP}/32" dev lo
echo "[mongo-pod-alias] ${SELF_IP}/32 aliased on lo for ${SELF_HOST}"
