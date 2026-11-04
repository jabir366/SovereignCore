#!/bin/bash
# =============================================================================
# /usr/local/bin/mongo-first-boot.sh
# =============================================================================
#
# Baked into the disk image at build time.
# Triggered by cloud-init runcmd ONLY — never by systemd directly.
# Reads /etc/mongo-init-env (written by cloud-init) for all configuration.
#
# ── Step map ─────────────────────────────────────────────────────────────────
#   1. Sentinel check   — skip entirely if already ran (idempotent)
#   2. Wait             — poll for /etc/mongo-init-env up to 60 s
#   3. Generate keyFile — openssl rand -base64 756 (or reuse injected key)
#   4. Write mongod.conf — loopback-only, standalone, NO auth (setup window)
#   5. Start mongod     — wait up to 60 s for it to accept connections
#   6. Create admin user — python3.12/pymongo (mongosh not available on s390x)
#   7. Create app DB+user — python3.12/pymongo, authenticated
#   8. Rewrite mongod.conf — 0.0.0.0, auth+keyFile, optional RS/audit/encryption
#   9. Restart mongod   — now externally reachable with full security
#  10. Write sentinel   — /etc/mongodb-first-boot-done
#  11. Configure rsyslog — optional drop-in /etc/rsyslog.d/60-mongodb.conf
#
# ── Behaviour ────────────────────────────────────────────────────────────────
#   MONGO_RS_ENABLED unset or "false"  → standalone mongod (no replication block)
#   MONGO_RS_ENABLED=true              → mongod started with replication.replSetName
#
# Key design: users are always created in standalone mode (steps 4–7) to avoid
# NotPrimary errors. The replication block is added in step 8 AFTER all users
# exist, so the very first external-facing start already has full security.
#
# ── Important notes ──────────────────────────────────────────────────────────
#   • mongosh is NOT installed on s390x — all DB ops use python3.12/pymongo.
#   • Do NOT add storage.journal.enabled — that field was removed in MongoDB 8.x.
#   • mongod binds to 127.0.0.1 during steps 4–8 so the unauthenticated setup
#     window is never exposed to the pod network.
#
# ── COMPLIANCE Phase 2 blocks (injected at step 8) ───────────────────────────
# /etc/mongo-compliance-env is written by cloud-init
# and sourced at step 8 to optionally extend mongod.conf BEFORE the first
# external-facing start. No image rebuild required — flags are per-instance.
#
# ── Logging — rsyslog customization (injected at step 11) ────────────────────
# /etc/mongo-rsyslog-env is written by cloud-init and sourced here.
# When MONGO_RSYSLOG_ENABLED=true this step:
#   1. Generates /etc/rsyslog.d/60-mongodb.conf from the env variables.
#   2. Appends /etc/mongo-rsyslog-custom.conf (if present) for advanced rules.
#   3. Restarts rsyslog so the new config is active.
#
# No image rebuild is required — all parameters are per-instance values
# injected via cloud-init write_files.
#
#   MONGO_COMPLIANCE_ENCRYPTION=true
#     → encryption at rest
#     Generates /etc/mongodb-encryption-key (once) and sets security.enableEncryption
#     + security.encryptionKeyFile in BOTH the standalone and final mongod.conf, so the
#     data files are encrypted from creation (step 1c).
#     Requires: MongoDB Enterprise Advanced licence. Needs an empty dbPath.
#     Pair with an encrypted storage class for the underlying volume.
#
#   MONGO_COMPLIANCE_AUDIT=true
#     → audit logging
#     Appends auditLog block + setParameter.auditAuthorizationSuccess to mongod.conf.
#     auditAuthorizationSuccess=true: logs ALL auth decisions, not just failures.
#     Default audit path: /var/log/mongodb/audit.json
#
#   Controls NOT handled here (external tooling required):
#     log retention >= 90 days → log volume policy of the platform
#     key rotation < 365 days  → external key management
#     KMIP key server          → platform-level infrastructure
# =============================================================================

set -euo pipefail
SENTINEL=/etc/mongodb-first-boot-done
LOG=/var/log/mongo-first-boot.log
# Touch the log file first so exec-redirect cannot fail (set -e would kill
# the script if the file is unwritable or has a bad SELinux label).
touch "$LOG" && chmod 644 "$LOG" || true
exec >> "$LOG" 2>&1

echo "[mongo-first-boot] Starting at $(date)"

if [ -f "$SENTINEL" ]; then
  echo "[mongo-first-boot] Already ran — skipping."
  exit 0
fi

# Wait for /etc/mongo-init-env to be written by cloud-init (up to 60s)
for i in $(seq 1 30); do
  [ -f /etc/mongo-init-env ] && break
  echo "[mongo-first-boot] Waiting for /etc/mongo-init-env... ($i/30)"
  sleep 2
done

if [ ! -f /etc/mongo-init-env ]; then
  echo "[mongo-first-boot] ERROR: /etc/mongo-init-env not found after 60s" >&2
  exit 1
fi

# Source injected env
# shellcheck disable=SC1091
set -a && . /etc/mongo-init-env && set +a

MONGOD_CONF=/etc/mongod.conf

# ── 1. Generate MongoDB keyFile (required for RS auth between members) ───────
# All members must share the same keyFile — injected via cloud-init write_files.
KEYFILE=/etc/mongodb-keyfile
if [ ! -f "$KEYFILE" ]; then
  echo "[mongo-first-boot] Generating keyFile..."
  openssl rand -base64 756 > "$KEYFILE"
  chmod 400 "$KEYFILE"
  chown mongod:mongod "$KEYFILE"
  echo "[mongo-first-boot] WARNING: keyFile generated locally — members will have different keyFiles!"
  echo "[mongo-first-boot] For RS to work, all members must share the same keyFile via cloud-init."
else
  echo "[mongo-first-boot] keyFile already present at ${KEYFILE}."
  chmod 400 "$KEYFILE"
  chown mongod:mongod "$KEYFILE"
fi

# ── 2. Write mongod.conf WITHOUT replication block ──────────────────────────
# Users must be created in standalone mode to avoid NotPrimary errors.
# Bind to 127.0.0.1 only so the unauthenticated setup window is never
# reachable from the pod network. Step 6 rewrites the config to 0.0.0.0
# + auth + keyFile in one shot before the final external-facing start.
# Stop any pre-running mongod instance so configuration cleanly applies.
# Mask mongod.service BEFORE pkill — without this, systemd auto-restarts mongod
# immediately after pkill and occupies port 27017, causing the standalone
# systemd-run unit to fail to bind.  We unmask at the end of this script
# after the final RS-mode mongod is running.
systemctl mask mongod.service 2>/dev/null || true
pkill -15 -f "mongod -f" 2>/dev/null || true; sleep 5
# Remove stale socket file — if a previous mongod was started as root it leaves
# /tmp/mongodb-27017.sock owned by root; mongod (running as mongod user) cannot
# unlink it and exits 14 (FileNotOpen). Always clean it before starting.
rm -f /tmp/mongodb-27017.sock 2>/dev/null || true
rm -f /var/lib/mongo/mongod.lock /var/lib/mongo/WiredTiger.lock 2>/dev/null || true

# ── 1b. Load Phase 2 compliance flags (always present — written by cloud-init) ──
# File is always written by the provisioner even when all flags are false. Loaded HERE, before
# the first mongod start, because WiredTiger encryption can only be enabled on an
# empty dbPath: the standalone setup phase must already run with it.
# shellcheck disable=SC1091
if [ -f /etc/mongo-compliance-env ]; then
  set -a && . /etc/mongo-compliance-env && set +a
fi
# Ensure defaults if not injected (defence-in-depth for image-only use)
MONGO_COMPLIANCE_ENCRYPTION="${MONGO_COMPLIANCE_ENCRYPTION:-false}"
MONGO_COMPLIANCE_AUDIT="${MONGO_COMPLIANCE_AUDIT:-false}"
MONGO_COMPLIANCE_AUDIT_PATH="${MONGO_COMPLIANCE_AUDIT_PATH:-/var/log/mongodb/audit.json}"
MONGO_COMPLIANCE_AUDIT_AUTH_SUCCESS="${MONGO_COMPLIANCE_AUDIT_AUTH_SUCCESS:-true}"

# ── 1c. WiredTiger encryption at rest ────────
# Needs a key: enableEncryption alone makes mongod exit. A per-node local key
# file (32 random bytes, base64 = AES-256) is generated once and then reused —
# regenerating it would make the existing data unreadable. Mode 400, owner mongod
# (mongod refuses a key file that is group/world accessible). Lives in /etc so the
# mongod_t SELinux domain can read it (same as /etc/mongodb-keyfile).
# NOTE: the key sits on the same disk as the data. For separation of key and data
# use KMIP instead of encryptionKeyFile.
ENC_KEYFILE=/etc/mongodb-encryption-key
ENC_SEC_LINES=""
ENC_STANDALONE_SECURITY=""
if [ "${MONGO_COMPLIANCE_ENCRYPTION}" = "true" ]; then
  echo "[mongo-first-boot] COMPLIANCE encryption-at-rest: enabling WiredTiger encryption-at-rest..."
  if [ ! -s "$ENC_KEYFILE" ]; then
    if [ -e /var/lib/mongo/WiredTiger.wt ]; then
      echo "[mongo-first-boot] ERROR: /var/lib/mongo already holds unencrypted data files — encryption cannot be enabled on an existing dbPath. Use a fresh disk." >&2
      exit 1
    fi
    (umask 077; openssl rand -base64 32 > "$ENC_KEYFILE")
    echo "[mongo-first-boot] encryption-at-rest: generated ${ENC_KEYFILE}."
  fi
  chown mongod:mongod "$ENC_KEYFILE"
  chmod 400 "$ENC_KEYFILE"
  ENC_SEC_LINES=$'  enableEncryption: true\n  encryptionKeyFile: '"${ENC_KEYFILE}"
  ENC_STANDALONE_SECURITY=$'security:\n'"${ENC_SEC_LINES}"$'\n'
fi

echo "[mongo-first-boot] Writing mongod.conf (loopback-only, standalone, no-auth)..."
cat > "$MONGOD_CONF" << EOF
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

storage:
  dbPath: /var/lib/mongo

net:
  port: 27017
  bindIp: 127.0.0.1

processManagement:
  timeZoneInfo: /usr/share/zoneinfo

${ENC_STANDALONE_SECURITY}
setParameter:
  diagnosticDataCollectionEnabled: false
EOF

# ── 3. Start mongod in standalone mode (loopback only, no auth, no replication)
echo "[mongo-first-boot] Starting mongod (loopback-only, standalone, no-auth)..."
# Use systemd-run to start mongod as a transient unit owned by the mongod user.
# This detaches mongod from the cloud-init runcmd process group entirely so it
# survives console disconnects and session termination (SIGHUP).
# su -s /bin/bash was replaced because su is a foreground process that receives
# SIGHUP when the controlling TTY closes, killing mongod with it.
# The config file must be in /etc/ (etc_t SELinux type) — mongod_t cannot read
# user_tmp_t files in /var/tmp or /tmp.
systemd-run --unit=mongod-firstboot-standalone --uid=mongod --gid=mongod \
  /usr/bin/mongod -f ${MONGOD_CONF}
sleep 8

# Poll every 2 s, up to 60 attempts (120 s total) for mongod to accept
# connections on the loopback. The loop breaks on first success.
# Use 127.0.0.1 directly instead of localhost to avoid DNS resolution delay.
# NOTE: Use single-quoted inline python — on s390x with FIPS enabled, pymongo
# running from a .py file returns exit 1 even on success due to a BrokenPipeError
# when stderr is redirected.  Single-quoted inline avoids the file-exec issue.
for i in $(seq 1 60); do
  if python3.12 -c 'import pymongo,sys,warnings;warnings.filterwarnings("ignore");c=pymongo.MongoClient("mongodb://127.0.0.1:27017",serverSelectionTimeoutMS=2000,directConnection=True);c.admin.command("ping");sys.exit(0)'; then
    echo "[mongo-first-boot] mongod is accepting connections."
    break
  fi
  echo "[mongo-first-boot] Waiting for mongod... ($i/60)"
  sleep 2
done

# Hard readiness guard after the polling loop.
if ! python3.12 -c 'import pymongo,sys,warnings;warnings.filterwarnings("ignore");c=pymongo.MongoClient("mongodb://127.0.0.1:27017",serverSelectionTimeoutMS=3000,directConnection=True);c.admin.command("ping");sys.exit(0)'; then
  echo "[mongo-first-boot] ERROR: mongod did not become ready after 120s — aborting" >&2
  exit 1
fi

# ── 4. Create admin user ─────────────────────────────────────────────────────
# Credentials are read from os.environ (exported by set -a above) rather than
# interpolated into Python string literals — prevents single-quote injection.
echo "[mongo-first-boot] Creating admin user..."
python3.12 << 'PYEOF'
import pymongo, os, warnings
warnings.filterwarnings('ignore')
admin_pass = os.environ['ADMIN_PASS']
# Connect without auth (standalone, no-auth mode) to create the first user.
# Do NOT specify authMechanism here — there is no auth yet, so no mechanism needed.
c = pymongo.MongoClient('mongodb://127.0.0.1:27017', serverSelectionTimeoutMS=5000,
    directConnection=True)
db = c['admin']
existing = [u['user'] for u in db.command('usersInfo')['users']]
if 'root' not in existing:
    # createUser with SCRAM-SHA-256 only — SCRAM-SHA-1 uses MD5 which is
    # prohibited by FIPS 140-3 on s390x (UnsupportedDigestmodError).
    db.command('createUser', 'root',
        pwd=admin_pass,
        roles=[{'role': 'root', 'db': 'admin'}],
        mechanisms=['SCRAM-SHA-256'])
    print('[mongo-first-boot] root user created (SCRAM-SHA-256)')
else:
    print('[mongo-first-boot] [SKIP] root user already exists')
PYEOF

# ── 5. Create application database + user ────────────────────────────────────
# Same pattern: read all credentials from os.environ — no shell interpolation
# inside Python string literals, so passwords with quotes or special chars work.
echo "[mongo-first-boot] Creating app database and user..."
python3.12 << 'PYEOF'
import pymongo, os
admin_pass = os.environ['ADMIN_PASS']
db_name    = os.environ['DB_NAME']
db_user    = os.environ['DB_USER']
db_pass    = os.environ['DB_PASS']
c = pymongo.MongoClient('mongodb://127.0.0.1:27017',
    username='root', password=admin_pass, authSource='admin',
    authMechanism='SCRAM-SHA-256',
    serverSelectionTimeoutMS=5000, directConnection=True)
existing = [u['user'] for u in c[db_name].command('usersInfo')['users']]
if db_user not in existing:
    c[db_name].command('createUser', db_user,
        pwd=db_pass,
        roles=[{'role': 'readWrite', 'db': db_name}])
    print(f'[mongo-first-boot] {db_user} created in {db_name}')
else:
    print(f'[mongo-first-boot] [SKIP] {db_user} already exists')
PYEOF

# ── 6. Rewrite config: open to 0.0.0.0 + auth + keyFile, then restart ───────
# All users now exist. Rewrite mongod.conf in one shot so the first
# external-facing start already has auth + keyFile — no unauthenticated
# window is ever exposed to the pod network.
echo "[mongo-first-boot] Reopening bind to 0.0.0.0, enabling auth + keyFile..."
# Again use pkill instead of systemctl stop to avoid VM reboot during first boot.
pkill -15 -f "mongod -f" 2>/dev/null || true; sleep 5

# Compliance flags were loaded in step 1b (they must be known before the first
# standalone start so encryption is on from the very first data file).
cat > "$MONGOD_CONF" << EOF
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

storage:
  dbPath: /var/lib/mongo

net:
  port: 27017
  bindIp: 0.0.0.0

processManagement:
  timeZoneInfo: /usr/share/zoneinfo

security:
  authorization: enabled
  keyFile: /etc/mongodb-keyfile
${ENC_SEC_LINES}

setParameter:
  diagnosticDataCollectionEnabled: false
EOF

# ── 6b. COMPLIANCE Phase 2 — encryption at rest ─────────────────
# Encryption at rest is written into the security: block above (ENC_SEC_LINES,
# built in step 1c) — NOT appended here. An append at end-of-file lands under
# setParameter: and mongod exits with "Unknown --setParameter 'enableEncryption'".

# ── 6c. COMPLIANCE Phase 2 — audit logging ────────────────────────
# Appends auditLog block + setParameter block to mongod.conf.
# auditAuthorizationSuccess=true: logs ALL auth decisions (not just failures).
# Default audit path: /var/log/mongodb/audit.json
if [ "${MONGO_COMPLIANCE_AUDIT}" = "true" ]; then
  echo "[mongo-first-boot] COMPLIANCE audit-log: enabling JSON audit log at ${MONGO_COMPLIANCE_AUDIT_PATH}..."
  # Ensure the audit log directory exists and is owned by mongod
  mkdir -p "$(dirname "${MONGO_COMPLIANCE_AUDIT_PATH}")"
  chown mongod:mongod "$(dirname "${MONGO_COMPLIANCE_AUDIT_PATH}")"
  # Set append-only on audit log so mongod process cannot delete it
  # chattr +a prevents unlink/truncate; mongod can still append new records.
  # Requires: ext4 or xfs filesystem with chattr support. Silently skipped otherwise.
  touch "${MONGO_COMPLIANCE_AUDIT_PATH}" 2>/dev/null || true
  # The file is created by root here, but mongod runs as the mongod user. If it is
  # left root:root, mongod fails at startup with FileNotOpen ("Failed to open
  # <audit path>") and exits 1. chown/chmod MUST happen BEFORE chattr +a, because
  # an append-only file can no longer be chown'd without first removing the flag.
  chown mongod:mongod "${MONGO_COMPLIANCE_AUDIT_PATH}"
  chmod 640 "${MONGO_COMPLIANCE_AUDIT_PATH}"
  chattr +a "${MONGO_COMPLIANCE_AUDIT_PATH}" 2>/dev/null \
    && echo "[mongo-first-boot] audit-log: chattr +a applied to ${MONGO_COMPLIANCE_AUDIT_PATH}" \
    || echo "[mongo-first-boot] audit-log: WARNING chattr +a failed — filesystem may not support it"
  cat >> "$MONGOD_CONF" << EOF

## COMPLIANCE audit logging
auditLog:
  destination: file
  format: JSON
  path: ${MONGO_COMPLIANCE_AUDIT_PATH}
EOF
  # If setParameter block exists, append parameter to it; otherwise create block
  if grep -q '^setParameter:' "$MONGOD_CONF"; then
    sed -i "/^setParameter:/a \ \ auditAuthorizationSuccess: ${MONGO_COMPLIANCE_AUDIT_AUTH_SUCCESS}" "$MONGOD_CONF"
  else
    cat >> "$MONGOD_CONF" << EOF

setParameter:
  auditAuthorizationSuccess: ${MONGO_COMPLIANCE_AUDIT_AUTH_SUCCESS}
EOF
  fi
fi

# Add replication block only when RS mode is requested
if [ "${MONGO_RS_ENABLED:-false}" = "true" ]; then
  cat >> "$MONGOD_CONF" << EOF

replication:
  replSetName: "${MONGO_RS_NAME}"
EOF
  echo "[mongo-first-boot] Replication configured: replSetName=${MONGO_RS_NAME}"

  # ── Pod IP loopback alias so MongoDB's isSelf check succeeds ─────────────────
  # KubeVirt masquerade NAT: the VM's pod IP is not on any interface.
  # MongoDB resolves its own FQDN to the pod IP for the isSelf check,
  # then tries to connect to that IP — which fails with Connection refused
  # unless the pod IP is aliased on lo.
  # `ip addr add` does not survive a reboot (and the pod IP changes when the VM
  # is restarted), so the alias is owned by mongo-pod-alias.service, which runs
  # before mongod on EVERY boot. It reads this member's host:port from
  # /etc/mongo-rs-self.
  echo "${MONGO_RS_SELF}" > /etc/mongo-rs-self
  chmod 644 /etc/mongo-rs-self
  systemctl restart mongo-pod-alias.service \
    || echo "[mongo-first-boot] WARNING: mongo-pod-alias.service failed — isSelf check may fail"

  # ── Persist the RS bootstrap env on member-0 for mongo-rs-init.service ──────
  # /etc/mongo-init-env is shredded at the end of this script and /tmp does not
  # survive a reboot, so rs-init used to die if the VM restarted before the RS
  # formed. /etc persists; mongo-rs-init.sh shreds this file once the RS has a
  # PRIMARY (or is already initiated).
  if [ "${MONGO_RS_INDEX:-}" = "0" ]; then
    install -m 600 -o root -g root /etc/mongo-init-env /etc/mongo-rs-init.env
    echo "[mongo-first-boot] RS bootstrap env persisted for mongo-rs-init.service."
  fi
fi

echo "[mongo-first-boot] Starting mongod with auth + keyFile$([ "${MONGO_RS_ENABLED:-false}" = "true" ] && echo " + replication" || echo "")$([ "${MONGO_COMPLIANCE_ENCRYPTION}" = "true" ] && echo " + encryption" || echo "")$([ "${MONGO_COMPLIANCE_AUDIT}" = "true" ] && echo " + audit" || echo "")..."
# Stop the standalone transient unit so the port is free.
systemctl stop mongod-firstboot-standalone.service 2>/dev/null || true
sleep 3
# Clean stale lock/socket files before final start.
rm -f /tmp/mongodb-27017.sock /var/lib/mongo/mongod.lock /var/lib/mongo/WiredTiger.lock 2>/dev/null || true
# Hand off to mongod.service — unmask (was masked during standalone setup window),
# enable for subsequent boots, then start. This ensures mongod is always managed
# by systemd and survives reboots without leaving an orphan systemd-run process.
systemctl unmask mongod.service 2>/dev/null || true
systemctl enable mongod.service 2>/dev/null || true
systemctl start mongod.service
sleep 8
# Fail loudly: a mongod that exits at startup (bad config, unreadable audit/key
# file, ...) must not let first-boot report success.
if ! systemctl is-active --quiet mongod.service; then
  echo "[mongo-first-boot] ERROR: mongod.service is not active after final start:" >&2
  journalctl -u mongod.service --no-pager -n 15 >&2 || true
  exit 1
fi

# ── 7. NTP stratum check ───────────────────────────
# Verify chrony is tracking before writing the sentinel file.
# Audit log timestamps are only legally defensible when NTP-synchronised.
# A warning (not an error) is logged if stratum > 4 — MongoDB still starts.
NTP_STRATUM=$(chronyc tracking 2>/dev/null | awk '/^Stratum/ {print $3}')
if [ -z "${NTP_STRATUM}" ]; then
  logger -t mongo-first-boot -p daemon.warning \
    "NTP: chronyc tracking failed — NTP status unknown. Audit timestamps may be unreliable."
  echo "[mongo-first-boot] NTP: WARNING chronyc not responding — NTP unverified."
elif [ "${NTP_STRATUM}" -gt 4 ] 2>/dev/null; then
  logger -t mongo-first-boot -p daemon.warning \
    "NTP: NTP stratum ${NTP_STRATUM} exceeds threshold (>4). Audit timestamps may be unreliable."
  echo "[mongo-first-boot] NTP: WARNING NTP stratum ${NTP_STRATUM} > 4 — timestamps unreliable."
else
  logger -t mongo-first-boot -p daemon.info \
    "NTP: NTP stratum ${NTP_STRATUM} — time sync verified."
  echo "[mongo-first-boot] NTP: NTP stratum ${NTP_STRATUM} — time sync verified."
fi

# ── 8. Write sentinel ────────────────────────────────────────────────────────
touch "$SENTINEL"

# ── 9. Configure rsyslog (optional — driven by /etc/mongo-rsyslog-env) ───────
# Always source the env file; the block is a no-op when MONGO_RSYSLOG_ENABLED=false.
# shellcheck disable=SC1091
if [ -f /etc/mongo-rsyslog-env ]; then
  set -a && . /etc/mongo-rsyslog-env && set +a
fi
MONGO_RSYSLOG_ENABLED="${MONGO_RSYSLOG_ENABLED:-false}"

if [ "${MONGO_RSYSLOG_ENABLED}" = "true" ]; then
  echo "[mongo-first-boot] Configuring rsyslog for MongoDB log forwarding..."

  # Ensure rsyslog imfile module and drop-in dir exist
  RSYSLOG_DROPIN=/etc/rsyslog.d/60-mongodb.conf

  # Defaults (defence-in-depth for image-only use without cloud-init)
  MONGO_RSYSLOG_FWD_ENABLED="${MONGO_RSYSLOG_FWD_ENABLED:-false}"
  MONGO_RSYSLOG_FWD_HOST="${MONGO_RSYSLOG_FWD_HOST:-}"
  MONGO_RSYSLOG_FWD_PORT="${MONGO_RSYSLOG_FWD_PORT:-514}"
  MONGO_RSYSLOG_FWD_PROTOCOL="${MONGO_RSYSLOG_FWD_PROTOCOL:-tcp}"
  MONGO_RSYSLOG_FWD_FORMAT="${MONGO_RSYSLOG_FWD_FORMAT:-rfc5424}"
  MONGO_RSYSLOG_MONGOD_ENABLED="${MONGO_RSYSLOG_MONGOD_ENABLED:-true}"
  MONGO_RSYSLOG_MONGOD_TAG="${MONGO_RSYSLOG_MONGOD_TAG:-mongodb-mongod}"
  MONGO_RSYSLOG_MONGOD_FACILITY="${MONGO_RSYSLOG_MONGOD_FACILITY:-local6}"
  MONGO_RSYSLOG_MONGOD_SEVERITY="${MONGO_RSYSLOG_MONGOD_SEVERITY:-info}"
  MONGO_RSYSLOG_AUDIT_ENABLED="${MONGO_RSYSLOG_AUDIT_ENABLED:-false}"
  MONGO_RSYSLOG_AUDIT_PATH="${MONGO_RSYSLOG_AUDIT_PATH:-/var/log/mongodb/audit.json}"
  MONGO_RSYSLOG_AUDIT_TAG="${MONGO_RSYSLOG_AUDIT_TAG:-mongodb-audit}"
  MONGO_RSYSLOG_AUDIT_FACILITY="${MONGO_RSYSLOG_AUDIT_FACILITY:-local7}"
  MONGO_RSYSLOG_AUDIT_SEVERITY="${MONGO_RSYSLOG_AUDIT_SEVERITY:-notice}"
  MONGO_RSYSLOG_RATELIMIT_INTERVAL="${MONGO_RSYSLOG_RATELIMIT_INTERVAL:-5}"
  MONGO_RSYSLOG_RATELIMIT_BURST="${MONGO_RSYSLOG_RATELIMIT_BURST:-500}"

  # Map format name to rsyslog template name
  case "${MONGO_RSYSLOG_FWD_FORMAT}" in
    rfc5424) RSYSLOG_TEMPLATE="RSYSLOG_SyslogProtocol23Format" ;;
    rfc3164) RSYSLOG_TEMPLATE="RSYSLOG_TraditionalForwardFormat" ;;
    json)    RSYSLOG_TEMPLATE="RSYSLOG_DebugFormat" ;;
    *)       RSYSLOG_TEMPLATE="RSYSLOG_SyslogProtocol23Format" ;;
  esac

  # Write the drop-in config
  cat > "${RSYSLOG_DROPIN}" << RSYSLOG_EOF
# /etc/rsyslog.d/60-mongodb.conf
# Generated by mongo-first-boot.sh — DO NOT EDIT MANUALLY.
# Re-generated at every first-boot from /etc/mongo-rsyslog-env.

# Load imfile module for file-based log tailing
module(load="imfile")

RSYSLOG_EOF

  # ── mongod.log imfile input ──────────────────────────────────────────────
  if [ "${MONGO_RSYSLOG_MONGOD_ENABLED}" = "true" ]; then
    cat >> "${RSYSLOG_DROPIN}" << RSYSLOG_EOF
# Tail /var/log/mongodb/mongod.log
input(type="imfile"
      File="/var/log/mongodb/mongod.log"
      Tag="${MONGO_RSYSLOG_MONGOD_TAG}"
      Facility="${MONGO_RSYSLOG_MONGOD_FACILITY}"
      Severity="${MONGO_RSYSLOG_MONGOD_SEVERITY}"
      ruleset="mongodb_logs"
$([ "${MONGO_RSYSLOG_RATELIMIT_INTERVAL}" -gt 0 ] && echo "      RateLimit.Interval=\"${MONGO_RSYSLOG_RATELIMIT_INTERVAL}\"" || true)
$([ "${MONGO_RSYSLOG_RATELIMIT_INTERVAL}" -gt 0 ] && echo "      RateLimit.Burst=\"${MONGO_RSYSLOG_RATELIMIT_BURST}\"" || true)
)

RSYSLOG_EOF
    echo "[mongo-first-boot] rsyslog: mongod.log imfile input configured (tag=${MONGO_RSYSLOG_MONGOD_TAG})"
  fi

  # ── audit.json imfile input ──────────────────────────────────────────────
  if [ "${MONGO_RSYSLOG_AUDIT_ENABLED}" = "true" ]; then
    # Ensure audit log directory exists for rsyslog to watch (may not exist yet)
    mkdir -p "$(dirname "${MONGO_RSYSLOG_AUDIT_PATH}")"
    cat >> "${RSYSLOG_DROPIN}" << RSYSLOG_EOF
# Tail MongoDB JSON audit log
input(type="imfile"
      File="${MONGO_RSYSLOG_AUDIT_PATH}"
      Tag="${MONGO_RSYSLOG_AUDIT_TAG}"
      Facility="${MONGO_RSYSLOG_AUDIT_FACILITY}"
      Severity="${MONGO_RSYSLOG_AUDIT_SEVERITY}"
      ruleset="mongodb_logs"
$([ "${MONGO_RSYSLOG_RATELIMIT_INTERVAL}" -gt 0 ] && echo "      RateLimit.Interval=\"${MONGO_RSYSLOG_RATELIMIT_INTERVAL}\"" || true)
$([ "${MONGO_RSYSLOG_RATELIMIT_INTERVAL}" -gt 0 ] && echo "      RateLimit.Burst=\"${MONGO_RSYSLOG_RATELIMIT_BURST}\"" || true)
)

RSYSLOG_EOF
    echo "[mongo-first-boot] rsyslog: audit log imfile input configured (path=${MONGO_RSYSLOG_AUDIT_PATH}, tag=${MONGO_RSYSLOG_AUDIT_TAG})"
  fi

  # ── Ruleset + forwarding action ──────────────────────────────────────────
  cat >> "${RSYSLOG_DROPIN}" << RSYSLOG_EOF
# Ruleset for MongoDB log messages
ruleset(name="mongodb_logs") {
RSYSLOG_EOF

  if [ "${MONGO_RSYSLOG_FWD_ENABLED}" = "true" ] && [ -n "${MONGO_RSYSLOG_FWD_HOST}" ]; then
    cat >> "${RSYSLOG_DROPIN}" << RSYSLOG_EOF
  # Forward to remote syslog server
  action(type="omfwd" Target="${MONGO_RSYSLOG_FWD_HOST}" Port="${MONGO_RSYSLOG_FWD_PORT}" Protocol="${MONGO_RSYSLOG_FWD_PROTOCOL}" Template="${RSYSLOG_TEMPLATE}"$([ "${MONGO_RSYSLOG_FWD_PROTOCOL}" = "tcp" ] && echo " TCP_Framing=\"octet-counted\"" || true))
RSYSLOG_EOF
    echo "[mongo-first-boot] rsyslog: forwarding to ${MONGO_RSYSLOG_FWD_HOST}:${MONGO_RSYSLOG_FWD_PORT}/${MONGO_RSYSLOG_FWD_PROTOCOL} (format=${MONGO_RSYSLOG_FWD_FORMAT})"
  else
    echo "[mongo-first-boot] rsyslog: forwarding disabled (or host not set) — local only"
  fi

  cat >> "${RSYSLOG_DROPIN}" << RSYSLOG_EOF
}
RSYSLOG_EOF

  # ── Append verbatim custom config if provided ────────────────────────────
  if [ -f /etc/mongo-rsyslog-custom.conf ]; then
    echo "" >> "${RSYSLOG_DROPIN}"
    echo "# Custom rsyslog rules (from /etc/mongo-rsyslog-custom.conf)" >> "${RSYSLOG_DROPIN}"
    cat /etc/mongo-rsyslog-custom.conf >> "${RSYSLOG_DROPIN}"
    echo "[mongo-first-boot] rsyslog: appended custom config from /etc/mongo-rsyslog-custom.conf"
  fi

  # Restart rsyslog to pick up the new drop-in
  systemctl restart rsyslog && echo "[mongo-first-boot] rsyslog restarted successfully." \
    || echo "[mongo-first-boot] WARNING: rsyslog restart failed — check journalctl -u rsyslog"
else
  echo "[mongo-first-boot] rsyslog customization disabled (MONGO_RSYSLOG_ENABLED=false) — skipping."
fi

# mongod.service was already unmasked, enabled and started above (step 6).
# Nothing to do here — kept as a no-op comment for clarity.

# ── 10. Enable + start mongo-primary-probe.service ──────────────────────────
# The probe HTTP server must be running for the KubeVirt readiness probe to pass.
# We cannot call `systemctl start mongo-primary-probe.service` directly here
# because this script runs inside a systemd-run transient unit — systemd will
# deadlock waiting for the new simple service to reach "active" state while
# still inside the transaction that launched this transient unit.
# Fix: use systemd-run with --no-block to fire-and-forget the probe start,
# completely detached from the current transient unit's cgroup/transaction.
systemctl enable mongo-primary-probe.service 2>/dev/null || true
systemd-run --unit=mongo-probe-launcher --no-block \
  /bin/bash -c 'systemctl start mongo-primary-probe.service' 2>/dev/null || true
echo "[mongo-first-boot] mongo-primary-probe.service enabled and launch scheduled."

# ── 10b. Start RS initiation on member-0 ─────────────────────────────────────
# mongo-rs-init.service is enabled in the image and guarded by
# ConditionPathExists=/etc/mongo-rs-init.env, so it only ever runs on member-0
# while the RS is not yet formed — at first boot (started here) and again after
# any reboot that happens before the RS has a PRIMARY. --no-block: we are inside
# a systemd unit, see the probe comment above.
if [ -f /etc/mongo-rs-init.env ]; then
  systemctl start --no-block mongo-rs-init.service
  echo "[mongo-first-boot] mongo-rs-init.service started."
fi

# ── Shred /etc/mongo-init-env after use ─────────
# The file was already written 0600 by cloud-init. Shredding it ensures
# credentials are not recoverable from disk after first-boot completes.
# 'shred -u' overwrites then unlinks; fallback to plain rm if shred unavailable.
if [ -f /etc/mongo-init-env ]; then
  if shred -u /etc/mongo-init-env 2>/dev/null; then
    echo "[mongo-first-boot] /etc/mongo-init-env shredded."
  else
    rm -f /etc/mongo-init-env
    echo "[mongo-first-boot] /etc/mongo-init-env removed (shred unavailable)."
  fi
fi

echo "[mongo-first-boot] Done at $(date)"
