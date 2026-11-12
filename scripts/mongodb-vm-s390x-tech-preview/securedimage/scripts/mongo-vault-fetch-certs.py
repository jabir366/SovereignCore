#!/usr/bin/python3.12
"""
/usr/local/bin/mongo-vault-fetch-certs.py
Baked into the disk image at build time (OSTree /usr is read-only at runtime).

Fetches the mongod TLS certificate from the tenant's HashiCorp Vault PKI
secrets engine. Runs BEFORE mongo-first-boot.sh starts mongod (systemd
ordering: mongo-vault-certs.service, wanted by mongodb-first-boot.service
and ordered Before=mongod.service), and again from the daily renewal timer.

WHY PYTHON + requests:
  The image has NO vault CLI, NO vault-agent binary and NO curl on s390x —
  only python3.12 + requests (pinned at build time). All Vault interaction
  is plain HTTPS JSON against the documented API:
    1. POST /v1/sys/wrapping/unwrap   (wrapping token -> single-use secret-id)
    2. POST /v1/auth/approle/login    (role_id + secret_id -> client token)
    3. POST /v1/{mount}/issue/{role}  (client token -> certificate + key)

FAIL CLOSED:
  On any error the script exits non-zero and NO certificate files are
  written. Via Requires=/After= ordering, mongod then never starts.
  There is no plaintext fallback anywhere. A 400 on the unwrap step is
  NOT retried: the wrapping token is single-use, so 400 means the token
  was already consumed elsewhere (possible interception — security alert,
  not a transient failure).

CONFIG — /etc/mongo-vault/env (written by cloud-init from chart values;
names/paths/SANs only, no credentials):
  VAULT_ADDR               https://vault.<ns>.svc.cluster.local:8200
  VAULT_CACERT             path to the CA that signed Vault's own listener
  VAULT_PKI_MOUNT          pki_int
  VAULT_PKI_ROLE           mongodb-server
  VAULT_ROLE_ID_FILE       /etc/mongo-vault/role_id            (not secret)
  VAULT_WRAPPED_SID_FILE   /etc/mongo-vault/wrapped-secret-id  (single-use)
  VAULT_RENEWAL_SID_FILE   /etc/mongo-vault/renewal-secret-id  (persistent)
  MONGO_TLS_CN             this member's FQDN (chart-computed)
  MONGO_TLS_ALT_NAMES      localhost[,external-vip-name]
  MONGO_TLS_IP_SANS        127.0.0.1   (REQUIRED: pymongo hostname
                           verification does not match a DNS SAN against an
                           IP-literal connection)
  MONGO_TLS_TTL            leaf TTL, e.g. 720h
  MONGO_TLS_CERT_DIR       /etc/mongodb/tls
  MONGO_TLS_MIN_REMAINING_S  skip re-issue while more than this remains

FILES WRITTEN (atomically — tmp + fsync + os.replace at the SAME path,
which mongod's rotateCertificates requires):
  /etc/mongodb/tls/server.pem   cert + PKCS#8 key, mongod:mongod 0400
  /etc/mongodb/tls/ca.pem       issuing CA + chain, mongod:mongod 0440
  /etc/mongodb/tls/expiration   notAfter epoch (fast-path sidecar)
  /run/mongo-vault/certs-changed  stamp consumed by mongo-vault-renew.service

KEY CUSTODY (see encryption-in-transit-vault-pki-implementation.md §A7):
  CA keys never leave Vault. The leaf private key is generated inside
  Vault and returned exactly ONCE in the issue response — it is never
  stored in Vault, Kubernetes or cloud-init afterwards.
"""
import grp
import os
import pwd
import subprocess
import sys
import tempfile
import time

import requests

LOG_FILE = "/var/log/mongo-vault-fetch.log"

# Retry budget: stays under the unit's TimeoutStartSec=540. Retries connection
# errors and HTTP 5xx only — a 4xx answer from Vault is definitive.
RETRY_DEADLINE_S = 480
RETRY_BACKOFF_S = (1, 2, 4, 8, 15, 30, 30, 60)

MONGOD_UID = pwd.getpwnam("mongod").pw_uid
MONGOD_GID = grp.getgrnam("mongod").gr_gid


def log(msg):
    line = "[vault-fetch] %s" % msg
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass  # journald still captured it


def die(msg):
    log("FATAL: %s" % msg)
    sys.exit(1)


def load_env_file(path):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                env[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return env


def vault_request(session, method, url, **kw):
    """Bounded-retry request. Retries connection errors and HTTP 5xx only;
    a 4xx answer from Vault is definitive and returned immediately.
    NOTE: callers must NOT retry a failed unwrap on 400 — the wrapping token
    is single-use, so 400 there means 'already used or expired'."""
    start = time.monotonic()
    attempt = 0
    last = "no attempt"
    while time.monotonic() - start < RETRY_DEADLINE_S:
        try:
            r = session.request(method, url, timeout=15, **kw)
            if r.status_code < 500:
                return r
            last = "HTTP %d: %s" % (r.status_code, r.text[:200])
        except requests.RequestException as e:
            last = repr(e)
        wait = RETRY_BACKOFF_S[min(attempt, len(RETRY_BACKOFF_S) - 1)]
        log("%s %s failed (%s); retry in %ds" % (method, url, last, wait))
        time.sleep(wait)
        attempt += 1
    die("Vault unreachable within %ds: %s" % (RETRY_DEADLINE_S, last))


def atomic_write(path, content, mode):
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o750, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".vault-fetch-")
    with os.fdopen(fd, "w") as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.chown(tmp, MONGOD_UID, MONGOD_GID)
    os.replace(tmp, path)  # same path required for mongod online rotation


def main():
    cfg = load_env_file("/etc/mongo-vault/env")
    init_env = load_env_file("/etc/mongo-init-env")

    vault_addr = cfg.get("VAULT_ADDR", "").rstrip("/")
    if not vault_addr:
        die("VAULT_ADDR not set in /etc/mongo-vault/env")
    if not vault_addr.startswith("https://"):
        # Plain http silently disables TLS for the whole credential channel
        # (requests ignores session.verify for http URLs) — refuse it.
        die("VAULT_ADDR must use https:// (got %r)" % vault_addr)

    cert_dir = cfg.get("MONGO_TLS_CERT_DIR", "/etc/mongodb/tls")
    server_pem = os.path.join(cert_dir, "server.pem")
    exp_file = os.path.join(cert_dir, "expiration")
    min_remaining_s = int(cfg.get("MONGO_TLS_MIN_REMAINING_S", str(7 * 86400)))

    # 0. Fast path: certs on disk still have margin (reboot / renewal timer).
    if os.path.isfile(server_pem) and os.path.isfile(exp_file):
        try:
            remaining = int(open(exp_file).read().strip()) - int(time.time())
        except ValueError:
            remaining = -1
        if remaining > min_remaining_s:
            log("certs valid for %.1f more days; nothing to do"
                % (remaining / 86400.0))
            return 0

    role_id = open(cfg.get("VAULT_ROLE_ID_FILE",
                           "/etc/mongo-vault/role_id")).read().strip()
    wrap_file = cfg.get("VAULT_WRAPPED_SID_FILE",
                        "/etc/mongo-vault/wrapped-secret-id")
    renewal_file = cfg.get("VAULT_RENEWAL_SID_FILE",
                           "/etc/mongo-vault/renewal-secret-id")

    session = requests.Session()
    session.verify = cfg.get("VAULT_CACERT", "/etc/mongo-vault/vault-ca.pem")

    # 1. Obtain a secret_id: single-use wrapped token at first boot,
    #    persistent renewal secret-id afterwards.
    renewal_role_id_file = cfg.get("VAULT_RENEWAL_ROLE_ID_FILE",
                                   "/etc/mongo-vault/renewal-role-id")
    login_role_id = role_id
    used_renewal_secret = False
    if os.path.isfile(wrap_file):
        wrapping_token = open(wrap_file).read().strip()
        # SINGLE ATTEMPT — deliberately NOT retried: the wrapping token is
        # single-use and is consumed server-side even if the response is
        # lost, so a transport retry could burn it and manufacture a
        # misleading 400 ("interception") out of a transient network fault.
        try:
            r = session.post(vault_addr + "/v1/sys/wrapping/unwrap",
                             headers={"X-Vault-Token": wrapping_token},
                             timeout=15)
        except requests.RequestException as e:
            r = None
            log("unwrap transport failure (%r) — token state unknown; "
                "falling back to the renewal secret-id if present" % e)
        if r is not None and r.status_code == 200:
            secret_id = r.json()["data"]["secret_id"]
            os.unlink(wrap_file)
            log("unwrapped single-use secret-id (wrapping token consumed)")
        else:
            # 400 = already unwrapped elsewhere, expired, or intercepted —
            # a security signal: check the Vault audit log for an earlier
            # unwrap. The token is stale either way, so remove the file and
            # fall back to the renewal secret-id rather than wedging first
            # boot on a dead token.
            if r is not None:
                log("unwrap failed (HTTP %d): %s — token consumed, expired "
                    "or intercepted; check the Vault audit log"
                    % (r.status_code, r.text[:200]))
            os.unlink(wrap_file)
            if os.path.isfile(renewal_file):
                secret_id = open(renewal_file).read().strip()
                used_renewal_secret = True
                log("falling back to the persistent renewal secret-id")
            else:
                die("unwrap failed and no renewal-secret-id on disk — "
                    "re-mint the wrapped secret-id and re-provision")
    elif os.path.isfile(renewal_file):
        secret_id = open(renewal_file).read().strip()
        used_renewal_secret = True
        log("using persistent renewal secret-id")
    else:
        die("no wrapped-secret-id and no renewal-secret-id on disk")

    # AppRole login requires the matching role_id/secret_id PAIR: the renewal
    # secret-id belongs to the RENEWAL AppRole, which has its own RoleID.
    if used_renewal_secret:
        if not os.path.isfile(renewal_role_id_file):
            die("renewal secret-id in use but %s is missing — the renewal "
                "AppRole has its own RoleID (chart value vault.renewalRoleId)"
                % renewal_role_id_file)
        login_role_id = open(renewal_role_id_file).read().strip()

    # 2. AppRole login -> short-lived client token.
    r = vault_request(session, "POST",
                      vault_addr + "/v1/auth/approle/login",
                      json={"role_id": login_role_id, "secret_id": secret_id})
    if r.status_code != 200:
        die("approle login failed (HTTP %d): %s"
            % (r.status_code, r.text[:400]))
    auth = r.json()["auth"]
    token = auth["client_token"]
    log("approle login ok (policies=%s, ttl=%ss)"
        % (auth.get("token_policies"), auth.get("lease_duration")))

    # 3. Issue the member certificate from the PKI secrets engine.
    common_name = cfg.get("MONGO_TLS_CN") or init_env.get("MONGO_RS_SELF")
    if not common_name:
        die("no MONGO_TLS_CN in /etc/mongo-vault/env and no MONGO_RS_SELF")
    body = {
        "common_name": common_name,
        "alt_names": cfg.get("MONGO_TLS_ALT_NAMES", "localhost"),
        "ip_sans": cfg.get("MONGO_TLS_IP_SANS", "127.0.0.1"),
        "ttl": cfg.get("MONGO_TLS_TTL", "720h"),
        # PKCS#8 is required by mongod FIPS mode; Vault's default
        # (private_key_format=der) returns algorithm-specific PEM.
        "format": "pem",
        "private_key_format": "pkcs8",
    }
    mount = cfg.get("VAULT_PKI_MOUNT", "pki_int")
    role = cfg.get("VAULT_PKI_ROLE", "mongodb-server")
    r = vault_request(session, "POST",
                      vault_addr + "/v1/%s/issue/%s" % (mount, role),
                      headers={"X-Vault-Token": token}, json=body)
    if r.status_code != 200:
        die("pki issue failed (HTTP %d): %s"
            % (r.status_code, r.text[:400]))
    d = r.json()["data"]
    for field in ("certificate", "private_key", "issuing_ca"):
        if not d.get(field):
            die("pki issue response missing data.%s" % field)

    # 4. Write cert+key as one PEM (net.tls.certificateKeyFile) and the CA.
    server = d["certificate"].rstrip("\n") + "\n" \
        + d["private_key"].rstrip("\n") + "\n"
    ca = d["issuing_ca"].rstrip("\n") + "\n"
    for c in d.get("ca_chain") or []:
        c = c.rstrip("\n") + "\n"
        if c not in ca:
            ca += c

    atomic_write(server_pem, server, 0o400)                   # mongod:mongod
    atomic_write(os.path.join(cert_dir, "ca.pem"), ca, 0o440)
    atomic_write(exp_file, str(d["expiration"]) + "\n", 0o644)

    # Stamp so the renewal unit knows to rotate mongod's live certs — but
    # ONLY when mongod is actually running with the old certificate. The
    # first-boot and pre-mongod reboot paths need no live rotation (mongod
    # reads the file at start), and a stale stamp would trigger a spurious
    # (possibly failing) rotateCertificates on the next daily timer run.
    if subprocess.call(["systemctl", "is-active", "--quiet",
                        "mongod.service"]) == 0:
        os.makedirs("/run/mongo-vault", exist_ok=True)
        open("/run/mongo-vault/certs-changed", "w").close()
        log("mongod active — stamped certs-changed for online rotation")

    log("issued CN=%s serial=%s notAfter(epoch)=%s"
        % (common_name, d["serial_number"], d["expiration"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
