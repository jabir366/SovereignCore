# TROUBLESHOOTING — securedimage build pipeline

This document captures every issue encountered while setting up and running the
bootc-based MongoDB EA image build pipeline on lpar3 (b39-cp4d3, RHEL 9.6 s390x),
along with root-cause analysis and the exact commands used to resolve each one.

---

## Table of contents

1. [§1 — `unknown distribution: rhel-9.6` — CentOS osbuild-composer on RHEL host](#1--unknown-distribution-rhel-96--centos-osbuild-composer-on-rhel-host)
2. [§2 — `error setting certificate file: /etc/rhsm/ca/redhat-uep.pem` — Satellite CA mismatch](#2--error-setting-certificate-file-etcrhsmcaredhat-ueppem--satellite-ca-mismatch)
3. [§3 — `distro = "rhel-9"` in blueprint causes BlueprintsError](#3--distro--rhel-9-in-blueprint-causes-blueprintserror)
4. [§4 — `[[gpgkeys]]` table syntax rejected by weldr-client composer-cli](#4--gpgkeys-table-syntax-rejected-by-weldr-client-composer-cli)
5. [§5 — osbuild-composer.service crash-loops: "neither the weldr API socket nor the composer API socket is enabled"](#5--osbuild-composerservice-crash-loops-neither-the-weldr-api-socket-nor-the-composer-api-socket-is-enabled)
6. [§6 — osbuild-composer.service crash-loops: "neither the local worker socket nor the remote worker socket is enabled"](#6--osbuild-composerservice-crash-loops-neither-the-local-worker-socket-nor-the-remote-worker-socket-is-enabled)
7. [§7 — rsync to lpar3 fails: "Permission denied" on /root/securedimage/](#7--rsync-to-lpar3-fails-permission-denied-on-rootsecuredimage)
8. [§8 — Blueprint push accepted but depsolve returns empty / wrong distro](#8--blueprint-push-accepted-but-depsolve-returns-empty--wrong-distro)
9. [§9 — EUS/E4S AppStream repo returns HTTP 404 for repomd.xml](#9--euse4s-appstream-repo-returns-http-404-for-repomdxml)
10. [§10 — General: build fails: `/dev/kvm not present`](#10--general-build-fails-devkvm-not-present)
11. [§11 — General: `registry.redhat.io` pull error](#11--general-registryredhatcom-pull-error)
12. [§12 — Blueprint files section inline script: `bindIp: 0.0.0.0` in skeleton mongod.conf](#12--blueprint-files-section-inline-script-bindip-0000-in-skeleton-mongodconf)
13. [§13 — VM first-boot: `/etc/mongo-init-env` not found](#13--vm-first-boot-etcmongo-init-env-not-found)
14. [§14 — Replica Set PRIMARY not elected within timeout](#14--replica-set-primary-not-elected-within-timeout)

---

## §1 — `unknown distribution: rhel-9.6` — CentOS osbuild-composer on RHEL host

### Symptom

Every `composer-cli blueprints depsolve` or `composer-cli compose start` call
fails immediately with:

```
ERROR: BlueprintsError: mongodb-ea-bootc: GetDistro - unknown distribution: rhel-9.6
```

`composer-cli distros list` returns only:

```
centos-9
```

### Root cause

`osbuild-composer` was installed from CentOS Stream mirrors (the
`mirror.stream.centos.org_9-stream_AppStream_s390x_os_` repo). The CentOS build:

- Ships only `centos-9.json` and `centos-stream-9.json` in
  `/usr/share/osbuild-composer/repositories/`
- Has `centos-9` and `centos-stream-9` compiled in as known distros
- On a RHEL 9.6 host, reads the host OS as `rhel-9.6` — a distro it does not know

You can confirm the vendor mismatch:

```bash
rpm -qi osbuild-composer | grep -E "Vendor|Version|Release|From repo"
# Vendor     : CentOS          ← WRONG
# From repo  : mirror.stream.centos.org_9-stream_AppStream_s390x_os_
```

The RHEL 9 AppStream repo (`rhel-9-for-s390x-appstream-rpms`) carries the
correct Red Hat build at version `132.2-3.el9_6` which ships `rhel-9.json`
through `rhel-9.6.json` distro definitions.

### Fix

```bash
# 1. Stop all osbuild services
systemctl stop osbuild-composer.service osbuild-local-worker.socket osbuild-composer.socket \
  2>/dev/null || true
systemctl reset-failed osbuild-composer.service 2>/dev/null || true

# 2. Remove CentOS packages
dnf remove -y osbuild-composer osbuild-composer-core osbuild-composer-worker \
  osbuild-composer-dnf-json 2>/dev/null || true

# 3. Enable the RHEL AppStream repo (if not already enabled)
subscription-manager repos --enable=rhel-9-for-s390x-appstream-rpms

# 4. Install the RHEL build — pin to el9_6, disable CentOS repos
dnf install -y \
  --disablerepo='mirror.stream.centos.org*' \
  osbuild-composer-132.2-3.el9_6.s390x \
  osbuild-composer-core-132.2-3.el9_6.s390x \
  osbuild-composer-worker-132.2-3.el9_6.s390x \
  composer-cli

# 5. Verify vendor
rpm -qi osbuild-composer | grep Vendor
# Vendor     : Red Hat, Inc.   ← CORRECT

# 6. Enable sockets and verify distros (see §6 for why both sockets are needed)
systemctl enable --now osbuild-composer.socket osbuild-local-worker.socket
sleep 3
composer-cli distros list | grep rhel-9
# rhel-9
# rhel-9.0  ... rhel-9.6    ← CORRECT
```

> **Note on EUS/E4S repos:** `rhel-9-for-s390x-appstream-eus-rpms` and
> `rhel-9-for-s390x-appstream-e4s-rpms` are alternative channels for
> `osbuild-composer`. However the EUS channel for 9.6 may return HTTP 404 until
> that minor version is officially published under EUS. The standard
> `rhel-9-for-s390x-appstream-rpms` is sufficient and always available.
> See §9 for details on the 404 issue.

### `setup-lpar3.sh` change

Phase 3 now auto-detects the CentOS vendor and replaces the package before
installing. Re-running `SETUP_MODE_B=true ./setup-lpar3.sh` on a host with the
CentOS version will perform the replacement automatically.

---

## §2 — `error setting certificate file: /etc/rhsm/ca/redhat-uep.pem` — Satellite CA mismatch

### Symptom

After replacing the CentOS osbuild-composer with the RHEL build, `depsolve`
fails with:

```
ERROR: BlueprintsError: mongodb-ea-bootc: running osbuild-depsolve-dnf failed:
DNF error occurred: RepoError: Failed to download metadata for repo '...' [baseos:
https://cdn.redhat.com/content/dist/rhel9/9.6/s390x/baseos/os]:
Cannot download repomd.xml:
Curl error (77): Problem with the SSL CA cert (path? access rights?)
  [error setting certificate file: /etc/rhsm/ca/redhat-uep.pem]
```

### Root cause

`osbuild-composer`'s internal DNF resolver looks for
`/etc/rhsm/ca/redhat-uep.pem` as the CA certificate for authenticating
connections to `cdn.redhat.com`.

On hosts registered directly to Red Hat CDN this file exists.
On hosts registered via **Red Hat Satellite / Katello** (as lpar3 is), the
RHSM CA is installed as:

```
/etc/rhsm/ca/katello-server-ca.pem   ← Satellite-issued CA
/etc/rhsm/ca/katello-default-ca.pem
/etc/rhsm/ca/corp-root-ca.pem
```

The file `redhat-uep.pem` is simply absent and osbuild cannot authenticate.

Verify:

```bash
ls /etc/rhsm/ca/
# katello-server-ca.pem  katello-default-ca.pem  corp-root-ca.pem
# (no redhat-uep.pem)

cat /etc/rhsm/rhsm.conf | grep repo_ca_cert
# repo_ca_cert = /etc/rhsm/ca/katello-server-ca.pem
```

### Fix

Create the symlink that osbuild expects, pointing at the Satellite CA:

```bash
ln -sf /etc/rhsm/ca/katello-server-ca.pem /etc/rhsm/ca/redhat-uep.pem
ls -la /etc/rhsm/ca/redhat-uep.pem
# lrwxrwxrwx ... /etc/rhsm/ca/redhat-uep.pem -> /etc/rhsm/ca/katello-server-ca.pem
```

No service restart is needed — the symlink is read at runtime by the depsolve
process each time a compose or depsolve is triggered.

Verify the fix works:

```bash
composer-cli blueprints depsolve mongodb-ea-bootc 2>&1 | head -5
# blueprint: mongodb-ea-bootc v8.3.2
# mongodb-enterprise-8.x...
# bootc-1.x...
```

### `setup-lpar3.sh` change

Phase 3d now auto-detects the missing `redhat-uep.pem` and creates the symlink
from the best available Satellite CA under `/etc/rhsm/ca/`.

---

## §3 — `distro = "rhel-9"` in blueprint causes BlueprintsError

### Symptom

`composer-cli blueprints push` succeeds but any subsequent `depsolve` or
`compose start` call returns:

```
ERROR: BlueprintsError: mongodb-ea-bootc: GetDistro - 'rhel-9' is not a valid distribution
```

*(This was observed before the fix in §1 — when the CentOS osbuild-composer
was still installed.)*

### Root cause

Setting `distro = "rhel-9"` in the TOML blueprint is only valid when the
osbuild-composer binary knows about `rhel-9`. The CentOS build does not —
it returns this error. Even with the RHEL build installed, setting an explicit
`distro` that doesn't match the host can cause similar failures.

### Fix

Remove the `distro` field from the blueprint entirely. When omitted,
osbuild-composer detects the host OS automatically (RHEL 9.6 s390x on lpar3),
which is always correct.

```toml
# REMOVED:
# distro = "rhel-9"

name    = "mongodb-ea-bootc"
version = "8.3.2"
# ... (no distro field)
```

This fix is already applied in `blueprints/mongodb-ea.toml`.

---

## §4 — `[[gpgkeys]]` table syntax rejected by weldr-client composer-cli

### Symptom

`composer-cli sources add /tmp/mongodb-ea-source.toml` fails or silently drops
the GPG key, and subsequent package installs report GPG verification failures.

### Root cause

Older osbuild-composer documentation shows GPG keys using TOML table array
syntax:

```toml
[[gpgkeys]]
url = "https://pgp.mongodb.com/server-8.0.asc"
```

The `weldr-client` implementation of `composer-cli` shipped with RHEL 9
(version 35.x) expects a **flat inline array** instead:

```toml
gpgkeys = ["https://pgp.mongodb.com/server-8.0.asc"]
```

### Fix

Use the flat array syntax in the source TOML. The correct source definition
for the MongoDB Enterprise repo:

```toml
id        = "mongodb-enterprise"
name      = "MongoDB Enterprise Repository"
type      = "yum-baseurl"
url       = "https://repo.mongodb.com/yum/redhat/9/mongodb-enterprise/8.0/s390x/"
check_gpg = true
check_ssl = true
system    = false
rhsm      = false
gpgkeys   = ["https://pgp.mongodb.com/server-8.0.asc"]
```

This fix is applied in `setup-lpar3.sh` Phase 4.

---

## §5 — osbuild-composer.service crash-loops: "neither the weldr API socket nor the composer API socket is enabled"

### Symptom

Running `systemctl restart osbuild-composer.service` directly causes the
service to crash-loop with:

```
neither the weldr API socket nor the composer API socket is enabled,
osbuild-composer is useless without one of these APIs enabled
```

### Root cause

`osbuild-composer` is a **socket-activated** service. It must be started by
`osbuild-composer.socket` (the weldr API socket), not started directly via
`.service`. When `.service` is started directly without the socket listening,
the binary sees no inherited file descriptors and exits immediately.

### Fix

**Never** run `systemctl restart osbuild-composer.service` directly.
Instead restart or re-enable the socket:

```bash
# Correct way to restart
systemctl restart osbuild-composer.socket
# or stop + re-enable
systemctl stop osbuild-composer.socket
systemctl enable --now osbuild-composer.socket
```

If the service is in a crashed/failed state:

```bash
systemctl reset-failed osbuild-composer.service
systemctl enable --now osbuild-composer.socket osbuild-local-worker.socket
sleep 3
composer-cli distros list     # triggers socket activation
```

---

## §6 — osbuild-composer.service crash-loops: "neither the local worker socket nor the remote worker socket is enabled"

### Symptom

`osbuild-composer.service` starts via socket activation but immediately exits
with:

```
neither the local worker socket nor the remote worker socket is enabled,
osbuild-composer is useless without workers
```

`composer-cli distros list` returns an error or the service is `failed`.

### Root cause

`osbuild-composer` requires a **worker** socket in addition to the weldr API
socket. The default systemd preset on RHEL 9.6 only auto-enables
`osbuild-composer.socket` — the worker socket `osbuild-local-worker.socket`
is not enabled by default and must be enabled explicitly.

Verify:

```bash
systemctl list-unit-files 'osbuild*'
# osbuild-composer.socket          enabled   ← was enabled
# osbuild-local-worker.socket      disabled  ← MISSING — causes crash
```

### Fix

Enable both sockets together:

```bash
systemctl enable --now osbuild-composer.socket osbuild-local-worker.socket
sleep 3
systemctl is-active osbuild-composer.socket osbuild-local-worker.socket
# active
# active
composer-cli distros list | grep rhel
```

`setup-lpar3.sh` Phase 3e now enables both sockets in a single call.

---

## §7 — rsync to lpar3 fails: "Permission denied" on /root/securedimage/

### Symptom

Running `make rsync-to-lpar3` (or the rsync command directly) from the local
Mac fails with:

```
rsync: [Receiver] ERROR: cannot stat destination "/root/securedimage/": Permission denied (13)
```

### Root cause

The SSH config (`~/.genericremoteconnect-ssh-config`) connects to lpar3 as
user `cp4d` (UID 1001), not as root. The `/root/` directory is mode `700` and
not writable by `cp4d`.

### Fix

Rsync to the user's home directory first, then copy to `/root/` with `sudo`:

```bash
# Step 1 — sync to cp4d home (from local Mac)
rsync -av --delete \
  -e "ssh -F ~/.genericremoteconnect-ssh-config" \
  securedimage/ lpar3:/home/cp4d/securedimage/

# Step 2 — copy into root (on lpar3)
ssh -F ~/.genericremoteconnect-ssh-config lpar3 \
  "echo 'watsonx.ai_ifm' | sudo -S -p '' cp -a /home/cp4d/securedimage/. /root/securedimage/"
```

The `make rsync-to-lpar3` target in `Makefile` has been updated to use
`/home/cp4d/securedimage/` as the rsync destination. The copy to `/root/` is
a one-liner run immediately after.

---

## §8 — Blueprint push accepted but depsolve returns empty / wrong distro

### Symptom

`composer-cli blueprints push mongodb-ea.toml` prints no error.
`composer-cli blueprints list` shows `mongodb-ea-bootc`.
But `composer-cli blueprints depsolve mongodb-ea-bootc` either returns the
wrong packages or the same distro error as §1/§3.

### Root cause

This can happen in two scenarios:

1. **Stale service state** — the blueprint was pushed before the RHEL
   osbuild-composer was installed. The service read the blueprint metadata
   against the old CentOS distro state.

2. **Service restart needed** — after replacing the osbuild-composer package,
   the service needs to be restarted via the socket so it re-loads its distro
   and repo definitions.

### Fix

After any package replacement, always re-push the blueprint and re-trigger
the service:

```bash
# On lpar3 as root:
systemctl reset-failed osbuild-composer.service 2>/dev/null || true
systemctl enable --now osbuild-composer.socket osbuild-local-worker.socket
sleep 3

# Re-push blueprint
composer-cli blueprints push /root/securedimage/blueprints/mongodb-ea.toml
composer-cli blueprints show mongodb-ea-bootc | head -10  # verify

# Re-add MongoDB source if lost during package removal
composer-cli sources list | grep mongodb || {
  cat > /tmp/mongodb-src.toml <<'SRC'
id        = "mongodb-enterprise"
name      = "MongoDB Enterprise Repository"
type      = "yum-baseurl"
url       = "https://repo.mongodb.com/yum/redhat/9/mongodb-enterprise/8.0/s390x/"
check_gpg = true
check_ssl = true
system    = false
rhsm      = false
gpgkeys   = ["https://pgp.mongodb.com/server-8.0.asc"]
SRC
  composer-cli sources add /tmp/mongodb-src.toml
}

# Depsolve
composer-cli blueprints depsolve mongodb-ea-bootc 2>&1 | head -20
```

> **Note:** The MongoDB Enterprise source is stored in the osbuild-composer
> state database, not the package files. It usually survives a package
> replacement. Always verify with `composer-cli sources list`.

---

## §9 — EUS/E4S AppStream repo returns HTTP 404 for repomd.xml

### Symptom

After enabling `rhel-9-for-s390x-appstream-eus-rpms` and running `dnf info`
or any dnf command:

```
Errors during downloading metadata for repository 'rhel-9-for-s390x-appstream-eus-rpms':
  - Status code: 404 for https://cdn.redhat.com/content/eus/rhel9/9/s390x/appstream/os/repodata/repomd.xml
Error: Failed to download metadata for repo 'rhel-9-for-s390x-appstream-eus-rpms'
```

### Root cause

EUS (Extended Update Support) content for RHEL 9.6 had not yet been published
to CDN at the time of this setup (September 2026). EUS content is published on
a delayed schedule — typically 6 months after a minor release.

The `rhel-9-for-s390x-appstream-e4s-rpms` channel has the same issue for the
same reason.

### Fix

Disable the EUS/E4S repo and use the standard rolling AppStream instead:

```bash
subscription-manager repos \
  --disable=rhel-9-for-s390x-appstream-eus-rpms \
  --disable=rhel-9-for-s390x-appstream-e4s-rpms 2>/dev/null || true
```

The standard `rhel-9-for-s390x-appstream-rpms` carries `osbuild-composer`
`132.2-3.el9_6` and is sufficient. The supplementary repo
(`rhel-9-for-s390x-supplementary-rpms`) was enabled to confirm availability
but is not required for osbuild-composer itself.

---

## §10 — General: build fails: `/dev/kvm not present`

KVM is required by `bootc-image-builder` for `qemu-img` operations on s390x.

```bash
# Check module
lsmod | grep kvm
# Load if not loaded
modprobe kvm
ls /dev/kvm
```

---

## §11 — General: `registry.redhat.io` pull error

The `vismitha.pv` account is already logged in on lpar3. If the session expired:

```bash
podman login registry.redhat.io
# Re-run setup if BIB image is missing
./setup-lpar3.sh
```

---

## §12 — Blueprint files section inline script: `bindIp: 0.0.0.0` in skeleton mongod.conf

### Note

The skeleton `mongod.conf` baked into the image via the blueprint
`[[customizations.files]]` section has `bindIp: 127.0.0.1` (localhost only).
The final `mongod.conf` written by `mongo-first-boot.sh` uses `bindIp: 0.0.0.0`
(all interfaces) **after** authentication and TLS/keyFile are configured.

This is intentional — the VM runs inside OCP Virt behind the pod network.
Binding to `0.0.0.0` inside the VM is required for replica-set member
communication across VM pods. The OCP network policy and security groups
restrict external access at the cluster layer.

If your deployment requires stricter binding, set `bindIp` to the specific
pod or service CIDR in `mongod.conf` after first boot.

---

## §13 — VM first-boot: `/etc/mongo-init-env` not found

`mongo-first-boot.sh` waits up to 60 seconds for `/etc/mongo-init-env` which
is written by cloud-init `write_files`. If it never appears:

```bash
# Inside the VM (virsh console or oc debug)
cat /var/log/cloud-init-output.log
cat /var/log/mongo-first-boot.log

# Check cloud-init datasource
cat /etc/cloud/cloud.cfg.d/99-datasource.cfg
# Should be: datasource_list: [ NoCloud, None ]
```

Common causes:

- `mongodb.rootPassword`, `mongodb.databaseName`, or `mongodb.databasePassword`
  was empty in the Helm values — the cloud-init `write_files` block is
  templated from these values and renders as empty if they are not set.
- The VirtualMachine spec does not include the cloud-init `cloudInitNoCloud`
  volume — verify with `kubectl get vm <name> -o yaml | grep -A5 cloudInit`.

---

## §14 — Replica Set PRIMARY not elected within timeout

Check `mongo-rs-init.log` on member-0:

```bash
cat /var/log/mongo-rs-init.log
```

Common causes:

| Cause | Fix |
|---|---|
| Member DNS not resolvable at init time | Increase `COMPOSE_TIMEOUT` or add retry delay in `mongo-rs-init.sh` |
| `ADMIN_PASS` mismatch between members | Check `/etc/mongo-init-env` on each VM — must match Helm `mongodb.rootPassword` |
| keyFile mismatch | All members must share the same keyFile — injected by Helm via `mongodb.keyFile` |
| mongod not yet started on a member | `mongo-rs-init.sh` waits 60×10s per member — check `mongo-first-boot.log` on each |

---

## Quick reference: state verification commands

Run these on lpar3 as root to confirm everything is healthy before starting a
compose:

```bash
# 1. RHEL osbuild-composer installed (not CentOS)
rpm -qi osbuild-composer | grep -E "Version|Vendor"
#   Version : 132.2          ← or newer el9_6 build
#   Vendor  : Red Hat, Inc.  ← must be Red Hat

# 2. Both sockets active
systemctl is-active osbuild-composer.socket osbuild-local-worker.socket
#   active
#   active

# 3. RHSM CA symlink present
ls -la /etc/rhsm/ca/redhat-uep.pem
#   lrwxrwxrwx ... -> katello-server-ca.pem

# 4. RHEL 9.6 distro recognised
composer-cli distros list | grep "rhel-9.6"
#   rhel-9.6

# 5. Blueprint present
composer-cli blueprints list
#   mongodb-ea-bootc

# 6. MongoDB source present
composer-cli sources list
#   appstream  baseos  mongodb-enterprise

# 7. Depsolve clean
composer-cli blueprints depsolve mongodb-ea-bootc 2>&1 | head -5

# 8. BIB image present
podman image exists registry.redhat.io/rhel9/bootc-image-builder:latest \
  && echo "BIB OK" || echo "BIB missing — run: podman pull"

# 9. Output dirs exist
ls -la /data/securedimage/output/qcow2 /data/securedimage/output/oci-archive
```

Once all nine checks pass, run:

```bash
cd /root/securedimage
USE_RH_IMAGE_BUILDER=true ./build.sh
# or: make build-mode-b
```

---

## §15 — `nothing provides mongodb-mongosh` depsolve failure on s390x

### Symptom

`composer-cli blueprints depsolve mongodb-ea-bootc` fails with:

```
DNF error occurred: DepsolveError:
  Problem: conflicting requests
  - nothing provides mongodb-mongosh needed by mongodb-enterprise-8.0.x-1.el9.s390x
```

This happens for every available version of `mongodb-enterprise` in the repo.

### Root cause

`mongodb-enterprise` is a **meta-package** that declares a hard RPM dependency
on `mongodb-mongosh` (the MongoDB Shell). The MongoDB `mongosh` binary has
**no s390x build** — it is only published for `x86_64` and `arm64`.

The s390x repo at `https://repo.mongodb.com/yum/redhat/9/mongodb-enterprise/8.0/s390x/`
contains the individual component packages, but not `mongosh`:

```
mongodb-enterprise-server      ← mongod daemon         ✅ s390x
mongodb-enterprise-mongos      ← shard router          ✅ s390x
mongodb-enterprise-tools       ← dump/restore/etc.     ✅ s390x
mongodb-enterprise-cryptd      ← encryption daemon     ✅ s390x
mongodb-enterprise             ← meta (requires mongosh) ❌ s390x broken
mongodb-mongosh                ← NOT available          ❌ no s390x build
```

### Fix

Replace `mongodb-enterprise` in the blueprint `[[packages]]` list with the
four individual component packages:

```toml
[[packages]]
name    = "mongodb-enterprise-server"
version = "*"

[[packages]]
name    = "mongodb-enterprise-mongos"
version = "*"

[[packages]]
name    = "mongodb-enterprise-tools"
version = "*"

[[packages]]
name    = "mongodb-enterprise-cryptd"
version = "*"
```

This change is already applied in `blueprints/mongodb-ea.toml`.

### Note on `mongosh` absence

`mongosh` is the interactive MongoDB shell used for ad-hoc queries. On s390x
VMs it is not available. All MongoDB interactions in this pipeline use
`python3` + `pymongo` instead — this is already how `mongo-first-boot.sh`
and `mongo-rs-init.sh` are written (no `mongosh` calls anywhere).
