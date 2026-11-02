# bootc Image Build — Complete Reference

> **Branch:** `bootc-approach` · **Repo:** `securedimage` · **Build host:** `lpar3` (`b39-cp4d3.pok.stglabs.ibm.com`, RHEL 9.6 s390x)

---

## 1. Where the code lives

| Location | What it is |
|---|---|
| **Local Mac** — `securedimage/` (branch `bootc-approach`) | Source-of-truth Git repo |
| **Build host lpar3** — `/home/cp4d/securedimage/` | Working copy rsync'd from Mac |
| **Build output** — `/data/securedimage/output/qcow2/` | Generated qcow2 disk images |
| **podman storage** — `/var/lib/containers/storage` | Built OCI layers (root-only) |

---

## 2. Who runs what

| Action | User | Why |
|---|---|---|
| `rsync` source to lpar3 | `cp4d` (Mac → lpar3 SSH) | Normal user SSH access |
| `setup-lpar3.sh` | **root** (via `sudo -S`) | DNF installs, podman pull from registry |
| `build.sh` Step 2 — `podman build` | **root** | podman storage `/var/lib/containers/storage` is root-only; BIB requires rootful podman |
| `build.sh` Step 3 — BIB `podman run` | **root** | BIB runs `--privileged` and bind-mounts KVM + container storage |
| `virtctl image-upload` (PVC upload) | `cp4d` | Uses `~/.kube/config` OCP session |
| `virtctl start/stop` | `cp4d` | OCP API access |

All root commands on lpar3 are invoked **non-interactively** from the Mac via:

```bash
echo 'watsonx.ai_ifm' | sudo -S bash -c '<command>'
```

---

## 3. Key files and their roles

| File | Role |
|---|---|
| `securedimage/Containerfile` | Full image definition — all 10 sections |
| `securedimage/build.sh` | Pipeline script: prereq check → podman build → BIB → qcow2 |
| `securedimage/setup-lpar3.sh` | One-time bootstrap: installs podman/bootc/skopeo, pulls BIB |
| `securedimage/upload.sh` | `virtctl image-upload` wrapper |
| `securedimage/Makefile` | Convenience targets (`make build-image`, `make build-qcow2`, etc.) |

---

## 4. The build pipeline — step by step

### Step 0 — One-time lpar3 bootstrap (run once as root)

```bash
# On lpar3, as root
cd /home/cp4d/securedimage
./setup-lpar3.sh
# Installs: podman, bootc, skopeo
# Pulls:    registry.redhat.io/rhel9/bootc-image-builder:latest
```

### Step 1 — Sync code from Mac → lpar3

```bash
# On Mac (local machine)
rsync -av --delete \
  -e "ssh -F /Users/manogya/.genericremoteconnect-ssh-config" \
  /Users/manogya/forkedrepos/sovereigncore/securedimage/ \
  lpar3:/home/cp4d/securedimage/ \
  --exclude='.git'
```

### Step 2 — Build OCI container image (`podman build`)

> **Version is auto-incremented** on every `podman build` step.  Do **not** pass
> `IMAGE_TAG=` manually in normal operation — `build.sh` reads `VERSION`,
> increments the patch digit, writes the new value back to `VERSION`, and passes
> it to `podman build` via `--build-arg IMAGE_TAG=<new-ver>`.

```bash
# Triggered from Mac, runs as root on lpar3
echo 'watsonx.ai_ifm' | sudo -S bash -c \
  'cd /home/cp4d/securedimage && \
   BUILD_STEP=image bash build.sh \
   > /data/securedimage/build.log 2>&1'
```

Internally `build.sh`:
1. Reads `VERSION` (e.g. `8.3.12`)
2. Increments patch → `8.3.13`
3. Writes `8.3.13` back to `VERSION`
4. Runs:

```bash
podman build \
  --platform linux/s390x \
  --build-arg IMAGE_TAG=8.3.13 \
  --tag localhost/mongodb-ea-bootc:8.3.13 \
  --file /home/cp4d/securedimage/Containerfile \
  /home/cp4d/securedimage/
```

5. Validates: `podman inspect --format '{{index .Labels "org.opencontainers.image.version"}}' localhost/mongodb-ea-bootc:8.3.13`
   → must equal `8.3.13` (not `${IMAGE_TAG}` or `0.0.0`)

**Output:** `localhost/mongodb-ea-bootc:8.3.13` in `/var/lib/containers/storage`

### Step 3 — Convert OCI → qcow2 (`bootc-image-builder`)

```bash
echo 'watsonx.ai_ifm' | sudo -S bash -c \
  'cd /home/cp4d/securedimage && \
   BUILD_STEP=qcow2 bash build.sh \
   > /data/securedimage/bib.log 2>&1'
```

`build-qcow2` does NOT increment the version (no podman build). It uses the
version already written in `VERSION` by Step 2.

Internally `build.sh` runs:

```bash
podman run \
  --rm --privileged \
  -v /data/securedimage/output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v /run/containers/storage:/run/containers/storage \
  -v /dev/kvm:/dev/kvm \
  registry.redhat.io/rhel9/bootc-image-builder:latest \
    build \
    --type qcow2 \
    localhost/mongodb-ea-bootc:8.3.13
```

**Output:** `/data/securedimage/output/qcow2/rhel9-mongodb-ea-8.3.13-s390x.qcow2`

### Step 4 — Upload to OCP PVC

```bash
# As cp4d on lpar3 (uses ~/.kube/config)
export KUBECONFIG=/home/cp4d/.kube/config

# Delete old PVC first
oc delete pvc mongodb-ea-disk-bootc -n mongodb-vm-test

# Upload new qcow2
virtctl image-upload pvc mongodb-ea-disk-bootc \
  --namespace=mongodb-vm-test \
  --image-path=/data/securedimage/output/qcow2/rhel9-mongodb-ea-8.3.4-s390x.qcow2 \
  --size=25Gi \
  --storage-class=ocs-storagecluster-ceph-rbd-virtualization \
  --access-mode=ReadWriteOnce \
  --volume-mode=block \
  --insecure
```

### Step 5 — Start VM and SSH in

```bash
# Start the VM
virtctl start mongodb-ea-bootc-test -n mongodb-vm-test

# Wait for Running status
oc get vm mongodb-ea-bootc-test -n mongodb-vm-test \
  -o jsonpath='{.status.printableStatus}'

# Port-forward and SSH
virtctl port-forward vm/mongodb-ea-bootc-test 20022:22 -n mongodb-vm-test &
ssh -o PubkeyAcceptedKeyTypes=rsa-sha2-512,rsa-sha2-256,ssh-ed25519 \
    -p 20022 -i /home/cp4d/.ssh/id_rsa \
    cloud-user@localhost
```

---

## 5. What the Containerfile builds — section summary

| Section | What it does |
|---|---|
| **FROM** | `registry.redhat.io/rhel9/rhel-bootc:9.6` — Red Hat RHEL 9.6 bootc base (s390x variant auto-selected) |
| **§1** | MongoDB Enterprise 8.0 yum repo (`repo.mongodb.com/yum/redhat/9/mongodb-enterprise/8.0/s390x/`) |
| **§2** | Installs: `mongodb-enterprise-server`, `mongos`, `tools`, `cryptd`; `cloud-init`; `openscap-scanner`; `scap-security-guide`; `dracut-fips`; `python3`, `pip`, `openssl`, `iproute`, `util-linux`, `policycoreutils-python-utils` |
| **§3** | `pip3 install "pymongo>=4.7,<5.0"` |
| **§4** | `mongod` user dirs: `/var/lib/mongo`, `/var/log/mongodb` — correct ownership and mode |
| **§5** | COPY `mongo-first-boot.sh`, `mongo-rs-init.sh` → `/usr/local/bin/` |
| **§6** | COPY `mongodb-first-boot.service` → `/etc/systemd/system/`; enable `mongod.service` |
| **§7** | cloud-init `datasource_list: [NoCloud, None]`; lock root password; disable root SSH; enable sshd |
| **§8** | SELinux enforcing; `semanage fcontext` for MongoDB dirs (`mongod_db_t`, `mongod_log_t`) |
| **§8b** | `oscap xccdf eval --remediate profile_stig` — DISA STIG RHEL 9 remediation |
| **§8c** | `fips-mode-setup --enable`; `update-crypto-policies --set FIPS` |
| **§8d** | Post-scan hardening: FIPS marker files, `auditd.conf` values, `augenrules` drop-in, `login.defs`, service masks (`cockpit`, `kdump`, `debug-shell`), audit file perms |
| **§8e-A** | 74 audit syscall rules written to `/etc/audit/rules.d/` drop-ins |
| **§8e-B** | `auditd.conf` numeric thresholds (`space_left = 75`, `admin_space_left = 50`, `freq = 50`) |
| **§8e-C** | postfix `smtpd_relay_restrictions = permit_mynetworks, reject` |
| **§8e-D** | chrony: `pool` → `server` directive (`server 0.rhel.pool.ntp.org iburst maxpoll 16`) |
| **§8e-E** | `update-crypto-policies --set FIPS` — **reverted from FIPS:STIG** (STIG subpolicy removes RSA sig algos, breaks sshd startup; accepted finding) |
| **§8e-F** | `/usr/libexec/sshd-fixperms/fix-host-key-perms.sh` + systemd drop-in — **replaces broken glob** in `ExecStartPre` (systemd does not shell-expand globs) |
| **§8e-G** | `/root` init files `chmod 0640` |
| **§8e-H** | `semanage login -m -s staff_u __default__` — SELinux sudo context elevation |
| **§9a** | `/usr/lib/bootc/install/10-disk-layout.toml` embedded in image (BIB 9.8 removed `--config` flag; disk layout must live inside the bootc image) |
| **§9b** | `mongod.conf` — FIPS cipher mode, WiredTiger storage engine, replication, net binding |
| **§10** | OCI image labels: version, compliance controls, ISCF refs |

---

## 6. Image version history

> **Version auto-increment:** as of `8.3.2.12`, each `make build-image` run
> increments the last version component automatically.  Manual `IMAGE_TAG=`
> overrides are no longer needed or recommended for routine builds.

| Tag | Commit | Key changes | Scan result |
|---|---|---|---|
| `8.3.2` (pre-§8d) | initial | Baseline | 291 pass / 101 fail (Scan 1) |
| `8.3.2` (post-§8d) | §8d commit | FIPS markers, auditd, login.defs, service masks, audit perms | 300 pass / 92 fail (Scan 2) |
| `8.3.3` | `fe6de62` | §8e A–H applied — **sshd broken** (FIPS:STIG + glob in ExecStartPre) | Scan 3 blocked |
| `8.3.4` | `5276027` | §8e-E reverted to FIPS; §8e-F fixed with helper script — sshd working | 289 pass / 123 fail (Scan 3) |
| `8.3.7` | `6004523` | §8e-A rewrite via write-audit-rules.sh; auditd drop-in two-ExecStartPost | 290 pass / 122 fail (Scan 5) |
| `8.3.8` | `1b327a1` | Remove auditctl -e 2; full auditd.conf rewrite; sysctl; fstab mount opts; postfix aliases | Scan 6 pending |
| `8.3.10` | `d5bdbd3` | §8e-L: fstab bind-mounts for partition_for_* STIG rules | Scan 6 pending |
| `8.3.2.11` | `bfa50f9` | Version management, SELinux ostree-relabel unit, CDI disk naming | — |
| **`8.3.2.12`** | current | **Quay Clair fixes:** restore /etc/os-release post-oscap, rpm --rebuilddb, ARG sentinel, auto-increment version | Clair scanning restored |

---

## 7. Environment variables for `build.sh`

| Variable | Default | Description |
|---|---|---|
| `IMAGE_TAG` | **auto-incremented from `VERSION`** | Set only for a one-off override; VERSION is NOT modified when set |
| `IMAGE_NAME` | `mongodb-ea-bootc` | OCI image name |
| `BUILD_STEP` | `all` | `check` / `image` / `qcow2` / `all`; only `image` and `all` trigger version increment |
| `OUTPUT_DIR` | `/data/securedimage/output` | Where qcow2 is written |
| `BIB_IMAGE` | `registry.redhat.io/rhel9/bootc-image-builder:latest` | BIB container image |
| `SKIP_BUILD` | `false` | `true` = reuse cached OCI image, re-run BIB only |
| `PUSH_CONTAINERDISK` | `true` | Wrap qcow2 as ContainerDisk OCI image and push |
| `PUSH_OCI` | `true` | Push raw bootc OCI image to registry (Quay Clair scannable) |
| `PUSH_PVC` | `false` | Upload qcow2 to OCP PVC via CDI / virtctl |
| `REGISTRY` | _(empty)_ | Required for push targets |
| `PLATFORM` | `linux/s390x` | podman build platform |

---

## 8. OCP / VM details

| Item | Value |
|---|---|
| OCP cluster | `ocpz-standard-1` |
| VM name | `mongodb-ea-bootc-test` |
| Namespace | `mongodb-vm-test` |
| PVC | `mongodb-ea-disk-bootc` |
| Storage class | `ocs-storagecluster-ceph-rbd-virtualization` |
| cloud-init secret | `bootc-test-cloudinit` (has `cp4d@lpar3` + `root@lpar3` RSA keys) |
| SSH user | `cloud-user` (sudo via `watsonx.ai_ifm`) |
| kubeconfig | `/home/cp4d/.kube/config` |
| OCP pull secret | `/tmp/rh-pull-secret.json` (for `podman --authfile`) |
