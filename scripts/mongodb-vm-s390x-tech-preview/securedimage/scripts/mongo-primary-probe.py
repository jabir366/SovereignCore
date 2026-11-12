#!/usr/bin/python3.12
"""
/usr/local/bin/mongo-primary-probe.py
Lightweight HTTP server baked into the bootc image.
Returns 200 + "PRIMARY\n"   if this mongod is the RS primary.
Returns 503 + "NOT PRIMARY\n" otherwise.

Runs as mongo-primary-probe.service, started by cloud-init runcmd.
KubeVirt readinessProbe.httpGet /health:8080 uses the 200/503 response to gate
VIP endpoint selection so only the primary receives client traffic.

WHY BAKED IN:
  /usr/local/bin is read-only on bootc (OSTree-managed /usr tree). Writing here
  at runtime via cloud-init write_files raises OSError(30, 'Read-only file system'),
  which aborts the entire write_files module and prevents runcmd from running.
  The password file (/etc/mongo-probe-pass) is still injected at runtime by
  cloud-init write_files because /etc is writable.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import pymongo

PORT = 8080
PASS_FILE = "/etc/mongo-probe-pass"
TLS_ENV_FILE = "/etc/mongo-tls-env"


def _load_tls_env():
    """Parse /etc/mongo-tls-env (written by cloud-init when compliance.tls
    is enabled; persists in /etc, nothing shreds it). Returns {} when TLS
    is off so the probe works identically on non-TLS deployments."""
    env = {}
    try:
        with open(TLS_ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                env[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return env


def is_primary():
    try:
        pwd = open(PASS_FILE).read().strip()
        tlskw = {}
        tls_env = _load_tls_env()
        if tls_env.get("MONGO_TLS_ENABLED") == "true":
            # No client certificate needed: mongod runs with
            # allowConnectionsWithoutCertificates: true. The cert's
            # IP SAN 127.0.0.1 covers this loopback connection.
            tlskw = dict(
                tls=True,
                tlsCAFile=tls_env.get(
                    "MONGO_TLS_CA_FILE", "/etc/mongodb/tls/ca.pem"),
            )
        c = pymongo.MongoClient(
            "mongodb://127.0.0.1:27017",
            username="root",
            password=pwd,
            authSource="admin",
            authMechanism="SCRAM-SHA-256",
            serverSelectionTimeoutMS=1500,
            directConnection=True,
            **tlskw,
        )
        return bool(c.admin.command("hello").get("isWritablePrimary"))
    except Exception:
        return False


class ProbeHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            if is_primary():
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"PRIMARY\n")
            else:
                self.send_response(503)
                self.end_headers()
                self.wfile.write(b"NOT PRIMARY\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass  # suppress access log noise


# Bind 0.0.0.0: KubeVirt masquerade reaches the guest on the pod-network address,
# not on loopback. Exposure is limited by the network policy of the
# deployment (restrict port 8080 ingress to trusted peers).
HTTPServer(("0.0.0.0", PORT), ProbeHandler).serve_forever()
