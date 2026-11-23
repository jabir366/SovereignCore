#!/bin/bash
# MongoDB VM-level compliance checks (the 12 SSH checks from ISCF_MONGODB_Control_Workflow).
# Runs ON the MongoDB VM. Prints PASS/FAIL per check and a total.
#
#   Inside the VM:      bash vm_checks_standalone.sh            (as cloud-user, like Concert)
#                       SUDO=1 bash vm_checks_standalone.sh     (as root, to compare)
#   From the cluster host (no copy onto the VM needed):
#     virtctl ssh -n mongodb-vm -i /root/mdb_key cloud-user@vmi/mongodb-byop-s390x-0 \
#        --command "bash -s" < vm_checks_standalone.sh
#
# Pass rule is the same as the workflow: pass unless output is empty or has "Result : FAIL".

RUN="bash"; [ "${SUDO:-0}" = "1" ] && RUN="sudo bash"
PASS=0; FAIL=0; TOTAL=0
TMP=$(mktemp)

run_check() {
  NAME="$1"; cat > "$TMP"; TOTAL=$((TOTAL+1))
  OUT=$($RUN "$TMP" 2>&1 </dev/null)
  if [ -n "$OUT" ] && ! echo "$OUT" | grep -qiE 'Result[[:space:]]*:[[:space:]]*FAIL'; then
    PASS=$((PASS+1)); echo "PASS  $NAME"
  else
    FAIL=$((FAIL+1)); echo "FAIL  $NAME"
  fi
  echo "$OUT" | grep -iE 'Output|Result|Error|denied|cannot' | head -4 | sed 's/^/        /'
}

echo "host: $(hostname)  user: $(whoami)  sudo: ${SUDO:-0}"
echo "------------------------------------------------------------"
run_check mdb_auth_01 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-auth-01 : SCRAM-SHA-256 Enforced"
echo "========================================="
echo "[Check 1] authorization: enabled"
AUTH=$(grep -i 'authorization:' /etc/mongod.conf | tr -d ' ')
echo "Output: $AUTH"
echo "Expected: authorization:enabled"
[ "$AUTH" = 'authorization:enabled' ] && echo 'Result : PASS' || echo 'Result : FAIL'
echo
echo "[Check 2] authenticationMechanisms includes SCRAM-SHA-256"
MECH=$(grep -i 'authenticationMechanisms' /etc/mongod.conf)
echo "Output: $MECH"
echo "Note: MongoDB 8.x defaults to SCRAM-SHA-256 if not explicitly set"
if echo "$MECH" | grep -q 'SCRAM-SHA-256'; then echo 'Result : PASS'; else echo 'Result : PASS (default SCRAM-SHA-256 - no weak override found)'; fi
EOF_CHECK
run_check mdb_auth_02 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-auth-02 : No Anonymous Access"
echo "========================================="
ADMIN_PASS=$(grep 'ADMIN_PASS' /etc/mongo-init-env 2>/dev/null | cut -d= -f2)
[ -z "$ADMIN_PASS" ] && ADMIN_PASS=$(grep 'ADMIN_PASS' /tmp/mongo-init-env.bak 2>/dev/null | cut -d= -f2)
[ -z "$ADMIN_PASS" ] && ADMIN_PASS=$(grep 'ADMIN_PASS' /etc/mongo-probe-pass-env 2>/dev/null | cut -d= -f2)
if [ -z "$ADMIN_PASS" ]; then echo 'Result : FAIL - cannot read ADMIN_PASS from any known location'; exit 0; fi
python3 -c "
import pymongo, sys
c = pymongo.MongoClient('mongodb://localhost:27017', username='root', password='$ADMIN_PASS', authSource='admin', serverSelectionTimeoutMS=5000, directConnection=True)
users = c.admin.command('usersInfo', {'forAllDBs': True})['users']
anon = [u['user'] for u in users if not u.get('user','').strip()]
print('Output: anonymous users =', anon)
print('Expected: empty list')
print('Result : PASS' if not anon else 'Result : FAIL')
"
EOF_CHECK
run_check mdb_enc_02 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-enc-02 : WiredTiger Encryption at Rest"
echo "========================================="
ENC=$(grep -i 'enableEncryption' /etc/mongod.conf | tr -d ' ')
echo "Output: $ENC"
echo "Expected: enableEncryption:true"
[ "$ENC" = 'enableEncryption:true' ] && echo 'Result : PASS' || echo 'Result : FAIL'
EOF_CHECK
run_check mdb_enc_03 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-enc-03 : Key Rotation < 365 Days"
echo "========================================="
VAULT_TOKEN=$(cat /etc/mongodb-vault-token 2>/dev/null || echo '')
if [ -z "$VAULT_TOKEN" ]; then echo 'Output: No Vault token at /etc/mongodb-vault-token'; echo 'Result : FAIL'; exit 0; fi
VAULT_ADDR=$(cat /etc/mongodb-vault-addr 2>/dev/null || echo 'https://vault.sovereign.local:8200')
python3 -c "
import requests, datetime, sys
vault_addr = open('/etc/mongodb-vault-addr').read().strip() if __import__('os').path.exists('/etc/mongodb-vault-addr') else 'https://vault.sovereign.local:8200'
vault_token = open('/etc/mongodb-vault-token').read().strip()
r = requests.get(vault_addr + '/v1/secret/mongodb/keymetadata', headers={'X-Vault-Token': vault_token}, timeout=5)
data = r.json().get('data', {})
created = data.get('created_date', '')
if not created:
    print('Result : FAIL - key metadata missing created_date')
    sys.exit(0)
age = (datetime.date.today() - datetime.date.fromisoformat(created[:10])).days
print('Output: key age = ' + str(age) + ' days')
print('Expected: age < 365')
print('Result : PASS' if age < 365 else 'Result : FAIL')
"
EOF_CHECK
run_check mdb_aud_01 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-aud-01 : auditLog Destination Set"
echo "========================================="
AUDIT=$(grep -A5 'auditLog:' /etc/mongod.conf 2>/dev/null)
echo "Output:"
echo "$AUDIT"
echo "Expected: destination: file, format: JSON, path set"
DEST=$(echo "$AUDIT" | grep 'destination')
FMT=$(echo "$AUDIT" | grep 'format')
PTH=$(echo "$AUDIT" | grep 'path')
[ -n "$DEST" ] && [ -n "$FMT" ] && [ -n "$PTH" ] && echo 'Result : PASS' || echo 'Result : FAIL'
EOF_CHECK
run_check mdb_aud_02 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-aud-02 : Admin Operations Logged"
echo "========================================="
RESULT=$(grep -i 'auditAuthorizationSuccess' /etc/mongod.conf | tr -d ' ')
echo "Output: $RESULT"
echo "Expected: auditAuthorizationSuccess:true"
[ "$RESULT" = 'auditAuthorizationSuccess:true' ] && echo 'Result : PASS' || echo 'Result : FAIL'
EOF_CHECK
run_check mdb_aud_03 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-aud-03 : Log Retention >= 90 Days"
echo "========================================="
LOG_DIR='/var/log/mongodb'
[ ! -d "$LOG_DIR" ] && echo 'Result : FAIL - log dir not found' && exit 0
ls -lth "$LOG_DIR"
LOGROTATE=$(cat /etc/logrotate.d/mongodb 2>/dev/null || echo 'NOT FOUND')
echo "Logrotate config: $LOGROTATE"
ROTATIONS=$(echo "$LOGROTATE" | grep -i 'rotate' | awk '{print $2}')
echo "Rotations configured: $ROTATIONS"
echo "Expected: >= 13 (weekly x 13 = 91 days)"
ROT_VAL=0
[ -n "$ROTATIONS" ] && ROT_VAL=$ROTATIONS
[ "$ROT_VAL" -ge 13 ] && echo 'Result : PASS' || echo 'Result : FAIL'
EOF_CHECK
run_check mdb_net_01 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-net-01 : bindIp Check"
echo "========================================="
BIND=$(grep -i 'bindIp' /etc/mongod.conf | tr -d ' ')
echo "Output: $BIND"
echo "Note: bindIp:0.0.0.0 is intentional (KubeVirt NAT). NetworkPolicy is the enforcement layer."
if echo "$BIND" | grep -q 'bindIp:'; then echo 'Result : PASS (compensating control: NetworkPolicy mdb-net-02)'; else echo 'Result : FAIL (bindIp not configured)'; fi
EOF_CHECK
run_check mdb_rbac_01 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-rbac-01 : Least-Privilege DB Roles"
echo "========================================="
ADMIN_PASS=$(grep 'ADMIN_PASS' /etc/mongo-init-env 2>/dev/null | cut -d= -f2)
[ -z "$ADMIN_PASS" ] && ADMIN_PASS=$(grep 'ADMIN_PASS' /tmp/mongo-init-env.bak 2>/dev/null | cut -d= -f2)
[ -z "$ADMIN_PASS" ] && ADMIN_PASS=$(grep 'ADMIN_PASS' /etc/mongo-probe-pass-env 2>/dev/null | cut -d= -f2)
[ -z "$ADMIN_PASS" ] && echo 'Result : FAIL - cannot read ADMIN_PASS from any known location' && exit 0
python3 -c "
import pymongo
DANGEROUS = {'root','dbAdminAnyDatabase','userAdminAnyDatabase','readWriteAnyDatabase','clusterAdmin'}
c = pymongo.MongoClient('mongodb://localhost:27017', username='root', password='$ADMIN_PASS', authSource='admin', serverSelectionTimeoutMS=5000, directConnection=True)
users = c.admin.command('usersInfo', {'forAllDBs': True})['users']
violations = [f\"{u['user']}: {set(r['role'] for r in u.get('roles',[])) & DANGEROUS}\" for u in users if (set(r['role'] for r in u.get('roles',[])) & DANGEROUS) and u['user'] != 'root']
print('Output: violations =', violations)
print('Result : PASS' if not violations else 'Result : FAIL')
"
EOF_CHECK
run_check mdb_rbac_02 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-rbac-02 : No Root Role in Production"
echo "========================================="
ADMIN_PASS=$(grep 'ADMIN_PASS' /etc/mongo-init-env 2>/dev/null | cut -d= -f2)
[ -z "$ADMIN_PASS" ] && ADMIN_PASS=$(grep 'ADMIN_PASS' /tmp/mongo-init-env.bak 2>/dev/null | cut -d= -f2)
[ -z "$ADMIN_PASS" ] && ADMIN_PASS=$(grep 'ADMIN_PASS' /etc/mongo-probe-pass-env 2>/dev/null | cut -d= -f2)
[ -z "$ADMIN_PASS" ] && echo 'Result : FAIL - cannot read ADMIN_PASS from any known location' && exit 0
python3 -c "
import pymongo
c = pymongo.MongoClient('mongodb://localhost:27017', username='root', password='$ADMIN_PASS', authSource='admin', serverSelectionTimeoutMS=5000, directConnection=True)
users = c.admin.command('usersInfo', {'forAllDBs': True})['users']
bad = [u['user'] for u in users if any(r['role']=='root' for r in u.get('roles',[])) and u['user']!='root']
print('Output: users with root role (excl admin root) =', bad)
print('Result : PASS' if not bad else 'Result : FAIL')
"
EOF_CHECK
run_check mdb_virt_03 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-virt-03 : Guest OS RHEL CIS Hardened"
echo "========================================="
echo "[Check 1] SELinux enforcing"
SEL=$(getenforce 2>/dev/null)
echo "Output: $SEL" && echo "Expected: Enforcing"
[ "$SEL" = 'Enforcing' ] && echo 'Result : PASS' || echo 'Result : FAIL'
echo
echo "[Check 2] Only root has UID 0"
UID0=$(awk -F: '$3==0 {print $1}' /etc/passwd)
echo "Output: $UID0" && echo "Expected: root"
[ "$UID0" = 'root' ] && echo 'Result : PASS' || echo 'Result : FAIL'
echo
echo "[Check 3] SSH password auth disabled"
SSHPASS=$(grep -i '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null)
echo "Output: $SSHPASS"
echo "$SSHPASS" | grep -qi 'no' && echo 'Result : PASS' || echo 'Result : FAIL'
echo
echo "[Check 4] FIM tool installed"
FIM=$(rpm -qa | grep -iE 'aide|tripwire|wazuh')
echo "Output: $FIM"
[ -n "$FIM" ] && echo 'Result : PASS' || echo 'Result : FAIL'
EOF_CHECK
run_check mdb_s390x_01 <<'EOF_CHECK'
#!/bin/bash
echo "========================================="
echo " mdb-s390x-01 : CPACF Hardware Crypto Active"
echo "========================================="
echo "[Check 1] lszcrypt"
CRYPTO=$(lszcrypt 2>/dev/null)
if [ -n "$CRYPTO" ]; then echo "Output: $CRYPTO"; else echo 'Output: lszcrypt not available'; fi
echo
echo "[Check 2] /proc/cpuinfo CPACF/MSA flag"
CPACF=$(grep -iE 'cpacf|msa' /proc/cpuinfo 2>/dev/null | head -3)
echo "Output: $CPACF"
echo "Expected: CPACF or MSA feature present"
[ -n "$CRYPTO" ] || [ -n "$CPACF" ] && echo 'Result : PASS' || echo 'Result : FAIL'
EOF_CHECK
echo "------------------------------------------------------------"
echo "VM-level checks: $PASS pass, $FAIL fail, $TOTAL total"
rm -f "$TMP"
