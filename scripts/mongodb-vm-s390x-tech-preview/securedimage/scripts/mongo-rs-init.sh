#!/bin/bash
# =============================================================================
# /usr/local/bin/mongo-rs-init.sh
# =============================================================================
#
# Baked into the disk image at build time.
# Runs ONLY on member-0 (MONGO_RS_INDEX=0 set in cloud-init runcmd)
# Triggered by cloud-init runcmd AFTER
# mongo-first-boot.sh has completed on member-0.
#
# ── Step map ─────────────────────────────────────────────────────────────────
#   1. Wait   — poll /etc/mongodb-first-boot-done sentinel up to 5 min
#   2. Reach  — verify all RS members accept authenticated connections
#   3. Check  — skip rs.initiate() if RS is already initiated (idempotent)
#   4. Alias  — add pod-IP loopback alias (KubeVirt masquerade NAT fix)
#   5. Init   — run replSetInitiate with full member config
#   6. Elect  — wait for PRIMARY election, print final RS status
#
# ── Idempotency / restart behaviour ──────────────────────────────────────────
#   Runs as mongo-rs-init.service (Restart=on-failure), guarded by
#   ConditionPathExists=/etc/mongo-rs-init.env. That file is written by
#   mongo-first-boot.sh on member-0 and shredded HERE once the RS is initiated /
#   has a PRIMARY, after which the unit is a permanent no-op. If the VM reboots
#   or a member is slow before then, the unit simply runs again.
#   Safe to re-run: step 3 detects an already-initiated RS and exits 0.
#
# ── Important notes ──────────────────────────────────────────────────────────
#   • mongosh is NOT installed on s390x — all DB ops use python3/pymongo.
#   • All member connections use admin credentials (ADMIN_PASS) with keyFile
#     auth — members must already have auth enabled from mongo-first-boot.sh.
#   • Credentials are read from os.environ only — never interpolated into
#     Python string literals, so passwords with special chars are safe.
#
# ── Reads from /etc/mongo-init-env ───────────────────────────────────────────
#   MONGO_RS_NAME     — replica set name, e.g. rs0
#   MONGO_RS_MEMBERS  — comma-separated host:port list, e.g. pod0.svc:27017,pod1.svc:27017
#   MONGO_RS_SELF     — this member's host:port, e.g. pod0.svc:27017
#                       Used to: (a) choose localhost when pinging self to avoid
#                       KubeVirt NAT issues, and (b) resolve the pod IP for the
#                       loopback alias (step 4).
#   ADMIN_PASS        — MongoDB admin user password (same on all members)
# =============================================================================

set -euo pipefail
LOG=/var/log/mongo-rs-init.log
touch "$LOG" && chmod 644 "$LOG" || true
exec >> "$LOG" 2>&1

# /etc/mongo-init-env is shredded by mongo-first-boot.sh after it completes;
# first-boot first copies it (member-0 only) to /etc/mongo-rs-init.env, which
# lives on persistent storage so this survives a reboot. Mode 600, root only.
ENV_FILE=/etc/mongo-rs-init.env
[ -f "$ENV_FILE" ] || { echo "[mongo-rs-init] ERROR: $ENV_FILE not found — nothing to do" >&2; exit 1; }
# shellcheck disable=SC1091
set -a && . "$ENV_FILE" && set +a

# Remove the plaintext credentials once the RS is up (no long-lived
# plaintext credential files). Called on every successful exit path.
cleanup_env() {
  shred -u "$ENV_FILE" 2>/dev/null || rm -f "$ENV_FILE"
  echo "[mongo-rs-init] $ENV_FILE removed."
}

echo "[mongo-rs-init] Starting at $(date)"
echo "[mongo-rs-init] RS name   : ${MONGO_RS_NAME}"
echo "[mongo-rs-init] Members   : ${MONGO_RS_MEMBERS}"
echo "[mongo-rs-init] Self      : ${MONGO_RS_SELF}"

# ── 1. Wait for mongo-first-boot sentinel ───────────────────────────────────
echo "[mongo-rs-init] Waiting for mongo-first-boot to complete..."
for i in $(seq 1 60); do
  [ -f /etc/mongodb-first-boot-done ] && break
  echo "[mongo-rs-init] Waiting for first-boot sentinel... ($i/60)"
  sleep 5
done

if [ ! -f /etc/mongodb-first-boot-done ]; then
  echo "[mongo-rs-init] ERROR: first-boot did not complete after 5 min" >&2
  exit 1
fi
echo "[mongo-rs-init] First-boot complete."

# ── 2. Wait for all members to be reachable ─────────────────────────────────
IFS=',' read -ra MEMBERS <<< "${MONGO_RS_MEMBERS}"

for member in "${MEMBERS[@]}"; do
  host="${member%%:*}"
  port="${member##*:}"
  # Use localhost for self to avoid KubeVirt masquerade NAT issue
  if [ "${host}" = "${MONGO_RS_SELF%%:*}" ]; then
    ping_host="localhost"
  else
    ping_host="${host}"
  fi
  echo "[mongo-rs-init] Waiting for ${member} (pinging ${ping_host}) with keyFile auth..."
  for i in $(seq 1 90); do
      if PING_HOST="${ping_host}" PING_PORT="${port}" python3.12 -c "
import pymongo, os, sys
try:
    # Connect with admin credentials — proves mongod has keyFile loaded and auth enabled.
    # Credentials from os.environ — no shell interpolation in Python string literals.
    c = pymongo.MongoClient(
        f'mongodb://{os.environ[\"PING_HOST\"]}:{os.environ[\"PING_PORT\"]}',
        username='root', password=os.environ['ADMIN_PASS'], authSource='admin',
        authMechanism='SCRAM-SHA-256',
        serverSelectionTimeoutMS=3000, directConnection=True)
    c.admin.command('ping')
except Exception:
    sys.exit(1)
sys.exit(0)
" 2>/dev/null; then
      echo "[mongo-rs-init] ${member} is reachable with auth."
      break
    fi
    if [ "$i" -eq 90 ]; then
      echo "[mongo-rs-init] ERROR: ${member} not reachable after 15 min" >&2
      exit 1
    fi
    echo "[mongo-rs-init] ${member} not ready yet ($i/60)..."
    sleep 10
  done
done

# ── 3. Check idempotency — skip if RS already initiated ─────────────────────
RS_OK=$(python3.12 -c "
import pymongo, os
try:
    c = pymongo.MongoClient('mongodb://127.0.0.1:27017',
        username='root', password=os.environ['ADMIN_PASS'], authSource='admin',
        authMechanism='SCRAM-SHA-256',
        serverSelectionTimeoutMS=5000, directConnection=True)
    status = c.admin.command('replSetGetStatus')
    print('1' if status.get('ok') == 1.0 else '0')
except Exception:
    print('0')
" 2>/dev/null || echo "0")

if [ "$RS_OK" = "1" ]; then
  echo "[mongo-rs-init] Replica set already initiated — nothing to do."
  cleanup_env
  exit 0
fi

# ── 4. Add pod IP alias on loopback so MongoDB accepts the FQDN config ───────
# KubeVirt masquerade NAT means the VM's own pod IP is NOT on any interface.
# MongoDB validates that the self-member's hostname resolves to a local address.
# Adding the pod IP to lo makes MongoDB accept the FQDN in rs.initiate().
SELF_HOST="${MONGO_RS_SELF%%:*}"
SELF_IP=$(python3.12 -c "import socket; print(socket.getaddrinfo('${SELF_HOST}', 27017)[0][4][0])" 2>/dev/null || true)
if [ -n "$SELF_IP" ]; then
  echo "[mongo-rs-init] Adding pod IP ${SELF_IP} as loopback alias for FQDN validation..."
  ip addr add "${SELF_IP}/32" dev lo 2>/dev/null || echo "[mongo-rs-init] IP alias already exists or failed (continuing)"
else
  echo "[mongo-rs-init] WARNING: could not resolve ${SELF_HOST} — rs.initiate() may fail"
fi

# ── 5. Build and run rs.initiate() ──────────────────────────────────────────
# Credentials read from os.environ (exported by set -a) — not interpolated into
# Python string literals, so passwords with single quotes / special chars work.
echo "[mongo-rs-init] Running rs.initiate()..."
python3.12 << 'PYEOF'
import pymongo, os

members_str = os.environ['MONGO_RS_MEMBERS']
rs_name     = os.environ['MONGO_RS_NAME']
admin_pass  = os.environ['ADMIN_PASS']

members = []
for i, hp in enumerate(members_str.split(',')):
    members.append({'_id': i, 'host': hp.strip()})

config = {'_id': rs_name, 'members': members}
print(f'[mongo-rs-init] Initiating RS config: {config}')

c = pymongo.MongoClient('mongodb://127.0.0.1:27017',
    username='root', password=admin_pass, authSource='admin',
    authMechanism='SCRAM-SHA-256',
    serverSelectionTimeoutMS=5000, directConnection=True)
result = c.admin.command('replSetInitiate', config)
print(f'[mongo-rs-init] replSetInitiate result: {result}')
PYEOF

# ── 6. Wait for PRIMARY election ────────────────────────────────────────────
echo "[mongo-rs-init] Waiting for PRIMARY election..."
for i in $(seq 1 30); do
  PRIMARY=$(python3.12 << 'PYEOF'
import pymongo, os
try:
    c = pymongo.MongoClient('mongodb://127.0.0.1:27017',
        username='root', password=os.environ['ADMIN_PASS'], authSource='admin',
        authMechanism='SCRAM-SHA-256',
        serverSelectionTimeoutMS=5000, directConnection=True)
    status = c.admin.command('replSetGetStatus')
    primaries = [m for m in status['members'] if m['stateStr'] == 'PRIMARY']
    print(len(primaries))
except Exception:
    print(0)
PYEOF
)

  if [ "$PRIMARY" = "1" ]; then
    echo "[mongo-rs-init] PRIMARY elected. Replica set is healthy."
    # Print the final member state table for the operator log / audit trail.
    # Each line shows:  <hostname:port> -> PRIMARY | SECONDARY | ...
    python3.12 << 'PYEOF'
import pymongo, os
c = pymongo.MongoClient('mongodb://127.0.0.1:27017',
    username='root', password=os.environ['ADMIN_PASS'], authSource='admin',
    authMechanism='SCRAM-SHA-256',
    serverSelectionTimeoutMS=5000, directConnection=True)
for m in c.admin.command('replSetGetStatus')['members']:
    print(f'  {m["name"]} -> {m["stateStr"]}')
PYEOF
    cleanup_env
    exit 0
  fi
  echo "[mongo-rs-init] Waiting for PRIMARY... ($i/30)"
  sleep 10
done

echo "[mongo-rs-init] WARNING: PRIMARY not elected within 5 min. Check rs.status() manually." >&2
exit 1
