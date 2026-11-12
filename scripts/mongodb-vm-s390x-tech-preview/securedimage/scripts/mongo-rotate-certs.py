#!/usr/bin/python3.12
"""
/usr/local/bin/mongo-rotate-certs.py
Baked into the disk image at build time.

Makes a RUNNING mongod pick up the replaced /etc/mongodb/tls/server.pem
without dropping connections. MongoDB 5.0+ online certificate rotation:
  db.adminCommand({rotateCertificates: 1})
  - new certificate files must reuse the SAME filename and path
    (mongo-vault-fetch-certs.py guarantees this with atomic os.replace)
  - existing connections keep the old certificate
  - new connections use the new one
  - a failed rotation does NOT kill mongod or invalidate the running config

NEVER send SIGHUP to mongod for rotation — in MongoDB 8.0 SIGHUP is handled
by the signal thread as a clean SHUTDOWN, not a reload.

Credentials: /etc/mongo-rotate-env (ADMIN_PASS, written once by
mongo-first-boot.sh, 0400 root:root — the same exposure class as
/etc/mongo-probe-pass; moving credentials to Vault is combined-plan
Phase 6). /etc/mongo-init-env is the fallback for the first-boot-time case
before that file is shredded.

rotateCertificates requires the hostManager role — the root user has it.
"""
import os
import warnings

import pymongo

warnings.filterwarnings("ignore")

TLS_ENV = "/etc/mongo-tls-env"


def _load_env(path):
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


def _admin_password():
    for path in ("/etc/mongo-rotate-env", "/etc/mongo-init-env"):
        pw = _load_env(path).get("ADMIN_PASS")
        if pw:
            return pw
    raise SystemExit("[rotate] FATAL: no ADMIN_PASS in /etc/mongo-rotate-env "
                     "or /etc/mongo-init-env — cannot rotate certificates")


def main():
    tls = _load_env(TLS_ENV)
    if tls.get("MONGO_TLS_ENABLED") != "true":
        print("[rotate] TLS not enabled — nothing to rotate")
        return 0
    ca_file = tls.get("MONGO_TLS_CA_FILE", "/etc/mongodb/tls/ca.pem")

    password = _admin_password()
    c = pymongo.MongoClient(
        "mongodb://127.0.0.1:27017",
        username="root", password=password, authSource="admin",
        authMechanism="SCRAM-SHA-256",
        tls=True, tlsCAFile=ca_file,
        serverSelectionTimeoutMS=10000, directConnection=True)
    c.admin.command("rotateCertificates")
    print("[rotate] mongod now serves the new certificate on new connections")
    return 0


if __name__ == "__main__":
    main()
