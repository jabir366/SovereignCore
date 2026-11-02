# securedimage — bootc-based MongoDB EA disk image for OCP Virt s390x

> **Quay Clair CVE scanning:** push the raw bootc OCI image (not the ContainerDisk)
> using `make push-oci REGISTRY=<your-registry>`.  See
> [Quay Clair scanning](#quay-clair-scanning) for full details.

Builds a **bootc / RHEL Image Mode** container image converted to a `qcow2` disk
image by Red Hat's image build toolchain. The resulting disk is used as the boot
image for MongoDB Enterprise Advanced `VirtualMachine` objects running under
OCP Virt on IBM Z (s390x).

Two build modes are supported — **both produce identical, bootc-compatible output**:

| Mode | Image content source | STIG + FIPS hardening | Disk conversion |
|---|---|---|---|
| **A** (default) | `Containerfile` (podman build) | `oscap --remediate` (STIG) + `fips-mode-setup` in build layer | `bootc-image-builder` (BIB) |
| **B** | Blueprint (`composer-cli`, osbuild-composer) | `customizations.openscap` (STIG, native) + `fips = true` | `bootc-image-builder` (BIB) |

> **BIB is used in both modes.** Mode B no longer outputs a qcow2 directly —
> it produces an OCI container image (`compose type: container`), loads it into
> podman, then feeds it to BIB. This ensures both modes produce genuinely
> bootc-compatible disks with the correct OSTree/composefs bootloader layout.

---

## What is bootc?

**bootc** (Boot Container) is Red Hat's "RHEL Image Mode" — it treats a RHEL OS
image as an OCI container that can be updated atomically, rolled back, and
converted into a disk image for VMs or bare metal.

Key properties relevant here:

| Property | What it means |
|---|---|
| OSTree/composefs layout | The root filesystem is a read-only composefs mount backed by an OSTree commit — this is what BIB builds |
| Atomic upgrades | `bootc upgrade` on the running VM fetches the new OCI image and stages it for next boot |
| Rollback | `bootc rollback` returns to the previous image on next boot |
| BIB compatibility | `bootc-image-builder` only works with images that contain the `bootc` RPM and a proper OSTree layout |

The `bootc` RPM is included in both the `Containerfile` (Mode A) and the
blueprint `packages` list (Mode B). Without it, BIB would produce a non-bootable disk.

---

## Directory structure

```
securedimage/
├── Containerfile                        ← Mode A: OS definition (bootc base + MongoDB EA)
├── Makefile                             ← Entry point — make help for all targets
├── build.sh                             ← Builds qcow2 (Mode A or B, selectable via env var)
├── setup-lpar3.sh                       ← One-time bootstrap for lpar3 build host
├── sync-scripts.sh                      ← Keep scripts/ in sync with image-scripts/
├── upload.sh                            ← Uploads qcow2 to OCP PVC via virtctl
├── scripts/
│   ├── mongo-first-boot.sh              ← Baked into image; triggered by cloud-init
│   ├── mongo-rs-init.sh                 ← Baked into image; RS initiation on member-0
│   ├── mongo-primary-probe.py           ← Baked into image; VIP readiness probe (HA + vip.enabled)
│   ├── aide-check.service               ← Systemd one-shot unit: runs aide --check daily
│   └── aide-check.timer                 ← Systemd timer: daily 02:00 + OnBootSec=30min
├── units/
│   ├── mongodb-first-boot.service       ← systemd unit (not auto-enabled; cloud-init starts it)
│   └── mongo-primary-probe.service      ← systemd unit for VIP primary probe (HA + vip.enabled)
└── README.md
```

> **Single source of truth:** `scripts/mongo-first-boot.sh` and
> `scripts/mongo-rs-init.sh` are the **same files** as
> `services/mongodb-vm/v1/image-scripts/`. Do not edit one without updating
> the other. Use `sync-scripts.sh` or `make sync-check` to verify.

---

## File descriptions

### `Containerfile` — Mode A OS definition

Defines the bootc container image:

| Section | What it does |
|---|---|
| **1** | Adds the MongoDB Enterprise YUM repository (`/etc/yum.repos.d/mongodb-enterprise.repo`) |
| **2** | Installs packages: `mongodb-enterprise`, `python3.12`, `python3.12-pip`, `cloud-init`, `openssl`, `iproute`, `util-linux`, `policycoreutils-python-utils`, `openscap-scanner`, `scap-security-guide`, `dracut-fips`, **`aide`** |
| **3** | Installs `pymongo>=4.7,<5.0` + CVE-free transitive deps (`urllib3`, `setuptools`, `requests`, `idna`, `oauthlib`, `Jinja2`, `configobj`) via `pip3.12` |
| **4** | Creates `/var/lib/mongo`, `/var/log/mongodb`, `/etc/mongodb` with `mongod:mongod` ownership |
| **5** | `COPY`s `scripts/mongo-first-boot.sh`, `scripts/mongo-rs-init.sh`, `scripts/mongo-primary-probe.py` into `/usr/local/bin/` |
| **6** | `COPY`s `units/mongodb-first-boot.service` + `units/mongo-primary-probe.service` into `/etc/systemd/system/`; disables both (cloud-init starts them) |
| **7** | Locks cloud-init to `NoCloud` datasource only (OCP Virt VirtualMachine spec) |
| **8** | SSH hardening: `PermitRootLogin no`, `PasswordAuthentication no`, `passwd -l root` |
| **8b** | Applies DISA STIG for RHEL 9 via `oscap xccdf eval --remediate` (profile: `stig`); saves audit report to `/root/stig-scan-report.html` |
| **8b-post** | **Restores `/etc/os-release`** to canonical RHEL 9 values after oscap (required for Quay Clair distribution detection) |
| **8c** | Enables FIPS 140-3: `fips-mode-setup --enable` + `update-crypto-policies --set FIPS` |
| **9** | Writes skeleton `/etc/mongod.conf` (rewritten by `mongo-first-boot.sh` at first boot) |
| **9a-aide** | **AIDE FIM** (mdb-gov-02 / iscf-sc-04): `COPY`s `scripts/aide-check.service` + `scripts/aide-check.timer`; runs `aide --init` to build the known-good baseline database at build time; `systemctl enable aide-check.timer` bakes the daily check into every deployed VM |
| **9b** | **`rpm --rebuilddb`** — rebuilds the RPM database so Clair's package indexer finds a consistent, queryable database |
| **10** | OCI labels: image metadata + ISCF compliance control references (version supplied via `--build-arg IMAGE_TAG`) |

### `build.sh` — Build orchestrator

Two modes selected by `USE_RH_IMAGE_BUILDER`:

| Step | Mode A (`false`) | Mode B (`true`) |
|---|---|---|
| 1 | Validate prereqs | Validate prereqs (incl. composer-cli) |
| 2 | `podman build` → OCI image | `composer-cli compose start … container` |
| 3 | BIB: OCI → qcow2 | Wait for compose; download OCI archive |
| 4 | (optional) Wrap qcow2 as ContainerDisk | `podman load` OCI archive → local image |
| 5 | (optional) Push ContainerDisk | BIB: OCI → qcow2 (same as Mode A step 3) |

### `setup-lpar3.sh` — One-time bootstrap

Idempotent setup script for lpar3. Phases:

| Phase | Action |
|---|---|
| 1 | Install RPMs: `podman`, `bootc`, `skopeo` (skips already-installed) |
| 2 | Pull `registry.redhat.io/rhel9/bootc-image-builder:latest` (skips if present) |
| 3 | *(SETUP_MODE_B=true only)* Install `osbuild-composer` + `composer-cli`, start socket |
| 4 | *(SETUP_MODE_B=true only)* Add MongoDB EA source to Image Builder |
| 5 | Create output directory tree: `OUTPUT_DIR/{qcow2,oci-archive}` |
| 6 | Smoke-test all tools; report warnings |

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `SETUP_MODE_B` | `false` | `true` = also install Image Builder (Mode B support) |
| `OUTPUT_DIR` | `/data/securedimage/output` | Output directory to create |
| `BIB_IMAGE` | `registry.redhat.io/rhel9/bootc-image-builder:latest` | BIB image to pull |
| `DRY_RUN` | `false` | `true` = print commands without executing |

### `sync-scripts.sh` — Script sync utility

Ensures `securedimage/scripts/` and `image-scripts/` are identical:

| Mode | Action |
|---|---|
| `check` (default) | Diff both directories; exit 1 if any file differs |
| `from-chart` | Copy `image-scripts/` → `securedimage/scripts/` |
| `from-image` | Copy `securedimage/scripts/` → `image-scripts/` |

### `upload.sh` — OCP PVC upload

Uploads the qcow2 to OCP as a CDI DataVolume source PVC via `virtctl image-upload`.
Auto-detects the CDI upload proxy URL from the cluster. Prints the Helm `--set`
overrides needed after upload.

### `scripts/mongo-first-boot.sh` — First-boot initialiser

Runs **once** at first boot (guarded by sentinel `/etc/mongodb-first-boot-done`).
Step map (see script header for full detail):

| Step | Action |
|---|---|
| 1 | Sentinel check — skip entirely if already ran |
| 2 | Wait up to 60 s for `/etc/mongo-init-env` |
| 3 | Generate or reuse `/etc/mongodb-keyfile` |
| 4 | Write `mongod.conf` — loopback-only, standalone, NO auth |
| 5 | Start mongod; poll up to 60 s for readiness |
| 6 | Create MongoDB `root` admin user (python3/pymongo) |
| 7 | Create application database + user (python3/pymongo) |
| 8 | Rewrite `mongod.conf` — `0.0.0.0`, auth + keyFile + `authMechanisms: SCRAM-SHA-256` (mdb-auth-01) + optional compliance blocks (encryption, audit); `chattr +a` on audit log if enabled (mdb-aud-04) |
| 9 | Restart mongod with full security |
| 10 | Write sentinel |
| 11 | NTP stratum check via `chronyc tracking` — warns if stratum > 4, does NOT block start (mdb-vm-01) |
| 12 | Configure rsyslog drop-in `/etc/rsyslog.d/60-mongodb.conf` if `MONGO_RSYSLOG_ENABLED=true` |
| 13 | **Shred `/etc/mongo-init-env`** — `shred -u` overwrites and unlinks the credentials file so passwords are unrecoverable from disk after first-boot (mdb-enc-06) |

Security notes:
- Binds to `127.0.0.1` during steps 4–8 so no unauthenticated window is
  exposed to the pod network.
- `authMechanisms: SCRAM-SHA-256` is written into `mongod.conf` at step 8 — mongod **never starts in a state that accepts SHA-1** authentication.
- `chattr +a` (append-only) on the audit log prevents the `mongod` process from deleting or truncating audit evidence (mdb-aud-04).
- `/etc/mongo-init-env` is shredded after use — no plaintext credentials remain on disk after first boot (mdb-enc-06).
- All credentials are read from `os.environ` in Python — never shell-interpolated into string literals, so passwords with special characters work safely.
- `mongosh` is NOT used — not available on s390x. All DB operations use `python3`/`pymongo`.

### `scripts/mongo-rs-init.sh` — Replica Set initialiser

Runs **only on member-0** (triggered by cloud-init after first-boot completes).
Step map:

| Step | Action |
|---|---|
| 1 | Wait up to 5 min for `/etc/mongodb-first-boot-done` sentinel |
| 2 | Verify all RS members accept authenticated connections |
| 3 | Check idempotency — skip if RS already initiated |
| 4 | Add pod-IP loopback alias (KubeVirt masquerade NAT fix) |
| 5 | Run `replSetInitiate` with full member config |
| 6 | Wait for PRIMARY election; print final member state table |

### `scripts/aide-check.service` — AIDE one-shot systemd unit

Runs `aide --check` as a `Type=oneshot` unit after `auditd.service`. Output goes to `journal+console`; a non-zero exit marks the unit failed, which Compliance Operator / Concert can alert on. Control: `mdb-gov-02 / iscf-sc-04`.

### `scripts/aide-check.timer` — AIDE daily timer

Fires the AIDE check at `02:00` daily and `30 min` after boot (`OnBootSec=30min`). `Persistent=true` catches reboots that skipped the 02:00 window. Enabled in the image at build time via `systemctl enable aide-check.timer`.

### `scripts/mongo-primary-probe.py` — VIP readiness probe

Python script run by `mongo-primary-probe.service` on each HA VM. Reads the root password from `/etc/mongo-probe-pass` (written by cloud-init, `0400 mongod:mongod`) and exits `0` only when `db.hello().isWritablePrimary` is `true`. Used as the KubeVirt readiness probe so the VIP Service endpoint always points to the current primary.

### `units/mongodb-first-boot.service` — systemd unit

Wraps `mongo-first-boot.sh` as a `Type=oneshot` systemd unit.
**Not enabled by default** — cloud-init `runcmd` starts it explicitly via
`systemctl start mongodb-first-boot.service` after writing `/etc/mongo-init-env`,
preventing a race between the unit and cloud-init credential injection.

### `units/mongo-primary-probe.service` — VIP probe systemd unit

Wraps `mongo-primary-probe.py` as a long-running `Type=simple` unit. Enabled in the image at build time; starts automatically on every deployed HA VM. The probe exit code drives the KubeVirt pod readiness — only the PRIMARY VM is `Ready` so the VIP Service endpoint list is always length-1.

---

## DISA STIG + FIPS 140-3 hardening — how it works

This image enforces the **DISA Security Technical Implementation Guide (STIG) for
Red Hat Enterprise Linux 9** (`xccdf_org.ssgproject.content_profile_stig`) from
the `scap-security-guide` package, combined with **FIPS 140-3** cryptographic
module enforcement.

### Why STIG instead of CIS Level 1?

| Aspect | CIS Level 1 | DISA STIG (this image) |
|---|---|---|
| Regulatory alignment | Industry best-practice | NIST SP 800-53 / FedRAMP mandatory |
| FIPS 140-3 requirement | No | **Yes — mandatory** |
| CAC/PIV auth settings | No | Yes |
| auditd syscall logging | Partial | **Full** |
| FedRAMP ATO evidence | Partial | **Primary documentation source** |
| Restrictiveness | Moderate | **High** |

The STIG profile is the federally mandated baseline for US government workloads.
Its rules map 1-to-1 to NIST SP 800-53 controls, making it the required evidence
source for an Authorizing Official (AO) reviewing a FedRAMP ATO package.

### Mode A — Containerfile (Sections 8b + 8c)

Section 8b of the [`Containerfile`](Containerfile) runs the STIG remediation:

```bash
oscap xccdf eval \
  --remediate \
  --profile xccdf_org.ssgproject.content_profile_stig \
  --report /root/stig-scan-report.html \
  --results /root/stig-scan-results.xml \
  /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
```

Section 8c enables FIPS 140-3:

```bash
fips-mode-setup --enable
update-crypto-policies --set FIPS
```

- `--remediate` applies all automatic fixes for failing STIG rules at build time
- The scan report (`/root/stig-scan-report.html`) and results XML are baked into
  the image as audit evidence — inspect with `podman run` or `virt-cat`
- Exit code 2 (evaluation error) fails the build; exit code 1 (findings after
  remediation) is reported but does not fail the build (expected for rules that
  require a live kernel or bootloader — NOTAPPLICABLE in a container layer)
- `fips=1` is added to the kernel command line via the bootc install config
  embedded in the image (Containerfile Section 9a) to complete FIPS enforcement
  at boot time

### STIG rules covered by other controls

| STIG rule area | Covered by |
|---|---|
| Separate `/boot`, `/var/log`, `/var/lib/mongo` partitions | Containerfile Section 8e-L (fstab bind/tmpfs entries) |
| SELinux enforcing | Containerfile Section 8 + bootc default |
| `PermitRootLogin no`, `PasswordAuthentication no` | Containerfile Section 8 |
| No default/empty passwords | Containerfile `passwd -l root` |
| mongod non-root user | MongoDB EA RPM default + Containerfile ownership |
| FIPS 140-3 cryptographic modules | Containerfile Section 8c + Section 9a `kargs = ["fips=1"]` |

---

## Quay Clair scanning

Quay Clair (ClairCore) performs CVE scanning on pushed images.  Only the raw
bootc OCI image — **not** the ContainerDisk — contains an RPM database that
Clair can index.

### Which image to push for scanning

| Image | Contains RPM DB | Clair scans it |
|---|---|---|
| `mongodb-ea-bootc:<tag>-s390x` (OCI build image) | **Yes** | **Yes** |
| `mongodb-ea-bootc-containerdisk:<tag>-s390x` | No (scratch + qcow2 blob) | No (expected) |

Push the OCI image:

```bash
# Via make
make push-oci REGISTRY=quay.io/<org>

# Via build.sh directly
PUSH_OCI=true REGISTRY=quay.io/<org> ./build.sh
```

### How Clair scanning works

1. The OCI image is pushed to Quay.
2. Quay's indexer reads the image manifest and walks each layer tarball.
3. **Distribution detection:** Clair reads `/etc/os-release` from the layer
   diff. It looks for `ID=rhel` and `VERSION_ID="9"` to select the RHEL 9
   CVE database.  If these fields are absent or incorrect, Clair classifies
   the image as `unknown` and produces no scan result.
4. **Package indexing:** Clair opens `/var/lib/rpm/` and queries the RPM
   database for installed package names and EVR tuples.  A corrupt or
   inconsistent RPM database causes zero-package results and a silently empty
   scan.
5. **CVE matching:** Clair matches indexed packages against the Red Hat
   Security Data API to produce the vulnerability report.

### Fixes applied in this build to ensure scanning works

| Fix | Section | Why |
|---|---|---|
| Restore `/etc/os-release` after `oscap --remediate` | `8b-post` | STIG rules can overwrite `ID` / `VERSION_ID`; Clair needs `ID=rhel` and `VERSION_ID="9"` |
| Rebuild RPM database | `9b` | Multiple RPM operations across `RUN` layers can leave the BDB database in an inconsistent state; `rpm --rebuilddb` ensures a clean, queryable database |
| Concrete version in `LABEL org.opencontainers.image.version` | `10` | Quay uses this label in the Clair index cache key; an unexpanded `${...}` token causes cache collisions and stale or absent scan results |
| `ARG IMAGE_TAG` default is `0.0.0` | `ARG` section | Makes builds without `--build-arg` immediately visible instead of silently inheriting a stale version |
| `build.sh` label validation | post-build check | Errors immediately if the label contains `${...}` or `0.0.0` before any push |

### Verifying the scan

```bash
# After pushing the OCI image, verify the label is concrete
podman inspect --format '{{index .Labels "org.opencontainers.image.version"}}' \
  quay.io/<org>/byop/mongodb-ea-bootc:<tag>-s390x
# Must print e.g. "8.3.13" — never "${IMAGE_TAG}" or "0.0.0"

# Verify /etc/os-release is intact inside the built OCI image
podman run --rm localhost/mongodb-ea-bootc:<tag> \
  grep -E '^(ID|VERSION_ID)=' /etc/os-release
# Must print: ID=rhel  and  VERSION_ID="9"

# Verify the RPM database is queryable
podman run --rm localhost/mongodb-ea-bootc:<tag> \
  rpm -qa --queryformat '%{NAME}-%{VERSION}\n' | wc -l
# Must return a non-zero count (typically 400+)
```

---

## Prerequisites (lpar3 — b39-cp4d3.pok.stglabs.ibm.com)

### Mode A (Containerfile + BIB)

| Requirement | Check | Install |
|---|---|---|
| s390x host | `uname -m` → `s390x` | — |
| RHEL 9.x | `cat /etc/redhat-release` | — |
| Podman ≥ 4 | `podman --version` | `dnf install -y podman` |
| bootc | `bootc --version` | `dnf install -y bootc` |
| skopeo | `skopeo --version` | `dnf install -y skopeo` |
| `/dev/kvm` | `ls /dev/kvm` | KVM module must be loaded |
| `registry.redhat.io` login | `podman login --get-login registry.redhat.io` | `podman login registry.redhat.io` |
| BIB image | `podman images \| grep bootc-image-builder` | `podman pull registry.redhat.io/rhel9/bootc-image-builder:latest` |
| `oc` CLI | `oc version --client` | extract from OCP release |
| `virtctl` | `virtctl version --client` | `oc adm release extract --tools` |
| `/data` ≥ 10 GiB free | `df -h /data` | default output dir for qcow2 |

### Mode B (Red Hat Image Builder)

All Mode A requirements **plus** (`setup-lpar3.sh SETUP_MODE_B=true` handles these):

| Requirement | Check | Install |
|---|---|---|
| `osbuild-composer` | `systemctl status osbuild-composer.socket` | `dnf install -y osbuild-composer composer-cli` |
| `composer-cli` | `composer-cli --version` | included above |
| MongoDB EA source added | `composer-cli sources list` | handled by `setup-lpar3.sh` Phase 4 |

---

## Quick start

### Step 1 — Sync to lpar3 (from local machine)

```bash
# Using make (reads SSH config from ~/.genericremoteconnect-ssh-config)
make rsync-to-lpar3

# Manual alternative
rsync -av --delete \
  -e "ssh -F ~/.genericremoteconnect-ssh-config" \
  securedimage/ lpar3:/root/securedimage/
```

### Step 2 — One-time bootstrap on lpar3

```bash
# SSH to lpar3
ssh -F ~/.genericremoteconnect-ssh-config lpar3
sudo -i

cd /root/securedimage

# Mode A only (Containerfile + BIB)
./setup-lpar3.sh

# Mode A + Mode B (also installs Image Builder)
SETUP_MODE_B=true ./setup-lpar3.sh
```

### Step 3 — Build

```bash
# Mode A — Containerfile + BIB (default)
./build.sh
# or: make build

# Mode B — Image Builder + BIB
USE_RH_IMAGE_BUILDER=true ./build.sh
# or: make build-mode-b

# Build + push ContainerDisk directly to registry (no virtctl upload needed)
PUSH_CONTAINERDISK=true REGISTRY=<your-registry> ./build.sh
# or: make push REGISTRY=<your-registry>
```

### Step 4 — Upload to OCP

```bash
oc login <cluster-api-url>
./upload.sh
# or: make upload
```

---

## Build options

### Version management

The version is managed automatically:

| Concept | Detail |
|---|---|
| **Canonical store** | `VERSION` file — one line, `MAJOR.MINOR.PATCH` (e.g. `8.3.12`) |
| **Auto-increment** | Every `make build-image` / `make build` / `./build.sh` invocation increments the **last** dot-segment of the version before calling `podman build` and writes the new value back to `VERSION` |
| **How it reaches the image** | `build.sh` passes `--build-arg IMAGE_TAG=<new-ver>` to `podman build`; the Containerfile receives it via `ARG IMAGE_TAG` and embeds it in `LABEL org.opencontainers.image.version` |
| **Sentinel default** | The Containerfile `ARG IMAGE_TAG` default is `0.0.0` — any build that does NOT receive `--build-arg IMAGE_TAG` will embed `0.0.0`, making the mistake immediately visible in Quay |
| **Caller override** | Set `IMAGE_TAG=x.y.z` in the environment to override for a single run without modifying `VERSION` |
| **Manual jump** | `make version-bump VERSION_NEW=8.4.0` — sets `VERSION` to an explicit value; the next build auto-increments to `8.4.1` |
| **Label validation** | `build.sh` inspects the built image and errors if the label contains `${...}` or `0.0.0` |

#### Version flow

```
VERSION file (8.3.12)
      │
      ▼  build.sh increments patch → 8.3.13
      │  writes 8.3.13 back to VERSION
      │
      ▼  podman build --build-arg IMAGE_TAG=8.3.13
      │
      ▼  Containerfile: ARG IMAGE_TAG → LABEL version="8.3.13"
      │
      ▼  built image: org.opencontainers.image.version = "8.3.13"
      │
      ▼  push to Quay → Clair reads label → CVE scan triggered
```

### build.sh

| Variable | Default | Description |
|---|---|---|
| `IMAGE_TAG` | auto-incremented from `VERSION` | Concrete version for this build; override to skip auto-increment |
| `IMAGE_NAME` | `mongodb-ea-bootc` | Image name |
| `OUTPUT_DIR` | `/data/securedimage/output` | Where qcow2 is written |
| `BIB_IMAGE` | `registry.redhat.io/rhel9/bootc-image-builder:latest` | BIB container image |
| `PUSH_CONTAINERDISK` | `true` | Build + push ContainerDisk OCI image |
| `PUSH_OCI` | `true` | Push raw bootc OCI image (enables Quay Clair CVE scan) |
| `PUSH_PVC` | `false` | Upload qcow2 to OCP PVC via CDI / virtctl |
| `REGISTRY` | *(empty)* | Registry host — required for push targets |
| `REGISTRY_NAMESPACE` | `byop` | Registry namespace |
| `SKIP_BUILD` | `false` | Skip `podman build`, reuse cached OCI image |
| `PLATFORM` | `linux/s390x` | Must match target arch |

### upload.sh

| Variable | Default | Description |
|---|---|---|
| `NAMESPACE` | `mongodb-vm-images` | OCP namespace for the source PVC |
| `PVC_NAME` | `mongodb-ea-disk` | PVC name (matches Helm chart default) |
| `DISK_SIZE` | `25Gi` | CDI DataVolume PVC capacity |
| `STORAGE_CLASS` | `ocs-storagecluster-ceph-rbd-virtualization` | OCS storage class |
| `UPLOAD_PROXY_URL` | auto-detected | CDI upload proxy route URL |
| `INSECURE` | `true` | Skip TLS verification on CDI proxy |
| `FORCE_BIND` | `true` | Immediately bind the PVC |

---

## Keeping scripts in sync

`securedimage/scripts/` and `services/mongodb-vm/v1/image-scripts/` must remain
identical. Use `sync-scripts.sh` to check and repair divergence:

```bash
# Check (no changes)
./sync-scripts.sh check
# or: make sync-check

# Copy image-scripts/ → securedimage/scripts/ (chart is source)
./sync-scripts.sh from-chart
# or: make sync-from-chart

# Copy securedimage/scripts/ → image-scripts/ (image is source)
./sync-scripts.sh from-image
# or: make sync-from-image
```

---

## Two deployment paths after build

### Path A — PVC upload (virtctl)

```
build.sh → qcow2 → upload.sh → PVC (mongodb-ea-disk / mongodb-vm-images ns)
           └─ then ─→ Helm: diskImage.sourcePVCName + sourcePVCNamespace
```

### Path B — ContainerDisk (preferred for OCP Virt)

```
build.sh PUSH_CONTAINERDISK=true REGISTRY=<host> → OCI image pushed to registry
           └─ then ─→ Helm: diskImage.sourceContainerDisk: <registry>/byop/mongodb-ea-bootc:<tag>-s390x
```

ContainerDisk is the preferred path: no CDI upload proxy is needed, the image
is versioned and immutable in the registry, and CDI pulls it directly.

---

## Disk layout

| Partition | Min size | Purpose |
|---|---|---|
| `/boot` | 1 GiB | s390-ccw-virtio bootloader (mandatory separate partition on s390x) |
| `/` | 15 GiB | OS + MongoDB EA binaries + pymongo + cloud-init |
| `/var/log` | 3 GiB | `mongod.log` + `audit.json` (compliance Phase 2) |
| `/var/lib/mongo` | 5 GiB | MongoDB data (CDI expands to DataVolume `diskSizeGi`) |

Total minimum = 24 GiB. Default `diskImage.diskSizeGi = 25` in `values.yaml`.
CDI expands automatically — increase for large datasets.

---

## What is baked into the image vs injected at runtime

| Concern | Where | How |
|---|---|---|
| MongoDB EA binaries | **Baked** | `dnf install mongodb-enterprise` |
| pymongo driver | **Baked** | `pip3.12 install pymongo` |
| cloud-init | **Baked** | `dnf install cloud-init` |
| DISA STIG hardening | **Baked** | `oscap --remediate` STIG profile (Mode A Sec 8b) or `customizations.openscap` (Mode B) |
| FIPS 140-3 | **Baked** | `fips-mode-setup` + `update-crypto-policies` (Mode A Sec 8c) or `fips = true` (Mode B) |
| First-boot scripts | **Baked** | `COPY scripts/` in Containerfile |
| systemd units | **Baked** | `COPY units/` in Containerfile |
| SELinux / sshd hardening | **Baked** | Containerfile Sections 8 + 8b |
| AIDE FIM baseline database | **Baked** | `aide --init` in Containerfile Section 9a-aide (mdb-gov-02) |
| AIDE systemd timer + service | **Baked** | `COPY` + `systemctl enable aide-check.timer` (Section 9a-aide) |
| VIP primary probe | **Baked** | `scripts/mongo-primary-probe.py` + `units/mongo-primary-probe.service` |
| MongoDB credentials | **Runtime** (cloud-init) | `/etc/mongo-init-env` written by Helm; **shredded** after use (mdb-enc-06) |
| RS env vars | **Runtime** (cloud-init) | `/etc/mongo-init-env` written by Helm |
| Compliance flags | **Runtime** (cloud-init) | `/etc/mongo-compliance-env` written by Helm |
| mongod.conf | **Runtime** (first-boot) | Rewritten by `mongo-first-boot.sh`; includes `authMechanisms: SCRAM-SHA-256` (mdb-auth-01) |
| Audit log append-only lock | **Runtime** (first-boot) | `chattr +a` on `/var/log/mongodb/audit.json` (mdb-aud-04) |
| NTP stratum check | **Runtime** (first-boot) | `chronyc tracking` checked before sentinel (mdb-vm-01) |

---

## Relationship to `services/mongodb-vm/v1` and values to provide

The `securedimage/` directory only **produces the boot disk**. Once the disk
exists (as a PVC or ContainerDisk), the Helm chart at
`services/mongodb-vm/v1/chart/` deploys the actual MongoDB VirtualMachines.

### Values you must set in the Helm chart after building

#### Path A — PVC upload (`upload.sh` default)

```yaml
# services/mongodb-vm/v1/chart/values.yaml  or  per-instance values override
diskImage:
  sourcePVCName:      "mongodb-ea-disk"       # PVC created by upload.sh
  sourcePVCNamespace: "mongodb-vm-images"     # namespace upload.sh targets
  storageClassName:   "ocs-storagecluster-ceph-rbd-virtualization"  # or -encrypted
  diskSizeGi:         25                       # must be >= qcow2 size
```

#### Path B — ContainerDisk (preferred)

```yaml
diskImage:
  sourceContainerDisk: "<REGISTRY>/byop/mongodb-ea-bootc:8.3.2-s390x"
  pullSecret:          "<secret-name>"   # if registry requires auth
  certConfigMap:       "<cm-name>"       # if registry uses a custom CA
  storageClassName:    "ocs-storagecluster-ceph-rbd-virtualization"
  diskSizeGi:          25
```

#### Mandatory credentials (always required — no defaults)

These are never baked into the image. They are injected by cloud-init at first boot.

```yaml
mongodb:
  rootPassword:     "<strong-password>"   # MongoDB root / admin user
  databaseName:     "<your-db-name>"      # Application database to create
  databaseUser:     "appuser"             # Application DB user (default: appuser)
  databasePassword: "<strong-password>"   # Application DB user password
  vmRootPassword:   "<strong-password>"   # VM OS root console password
```

#### HA Replica Set (optional)

```yaml
ha:
  enabled:        true
  replicaCount:   3          # must be odd: 3, 5, or 7
  replicaSetName: "rs0"
```

#### Compliance flags (optional, Phase 2)

```yaml
compliance:
  enableEncryption: true     # mdb-enc-02 — WiredTiger at-rest encryption
                             # Requires MongoDB EA licence
                             # Pair with storageClassName: ...-encrypted
  auditLog:
    enabled: true            # mdb-aud-01 + mdb-aud-02 — JSON audit log
    path: "/var/log/mongodb/audit.json"
    auditAuthorizationSuccess: true
```

#### VIP Service (optional, HA only)

```yaml
vip:
  enabled:  true
  lb_type:  "local"          # local = NodePort (dev/test), external = MetalLB
  port:     27017
  nodePort: 0                # 0 = OCP auto-assigns
```

### Full example one-liner for Helm render test

```bash
helm template my-mongodb services/mongodb-vm/v1/chart \
  --set diskImage.sourceContainerDisk="<REGISTRY>/byop/mongodb-ea-bootc:8.3.2-s390x" \
  --set diskImage.diskSizeGi=25 \
  --set mongodb.rootPassword=testpass \
  --set mongodb.databaseName=myapp \
  --set mongodb.databasePassword=apppass \
  --set mongodb.vmRootPassword=vmpass \
  --set ha.enabled=true \
  --set compliance.enableEncryption=true \
  --set compliance.auditLog.enabled=true \
  2>&1 | grep "kind:"
# Expected: NetworkPolicy, ServiceAccount, Role, RoleBinding,
#           Service x2 (ClusterIP + headless), DataVolume x3, VirtualMachine x3
```

---

## IBM Sovereign Core Framework (ISCF) compliance controls

### Controls enforced in this image (baked at build time)

| Control | ISCF ref | Enforced by |
|---|---|---|
| `mdb-virt-01` | iscf-ia-04 | `PermitRootLogin no` + `PasswordAuthentication no` (Containerfile Section 8) |
| `mdb-virt-04` | iscf-ai-03 | DISA STIG for RHEL 9 via `oscap --remediate` (Mode A Sec 8b) or `customizations.openscap` (Mode B) |
| `mdb-s390x-03` | iscf-cr-01 | FIPS 140-3 via `fips-mode-setup` (Mode A Sec 8c) or `[customizations] fips = true` (Mode B) |
| `mdb-s390x-02` | iscf-cr-01 | CPACF hardware crypto auto-linked via RHEL openssl on s390x |
| `mdb-gov-02` | iscf-sc-04 | AIDE FIM: `aide --init` baseline at build time + `aide-check.timer` daily (Containerfile Section 9a-aide) |

### Controls enforced in the Helm chart (`services/mongodb-vm/v1/`)

| Control | ISCF ref | Enforced by |
|---|---|---|
| `mdb-net-02` | iscf-dr-03/04/09 | `chart/templates/networkpolicy.yaml` (`networkPolicy.enabled=true` default) |
| `mdb-net-04` | iscf-dr-02/03 | `chart/templates/networkpolicy.yaml` |
| `mdb-net-03` | iscf-dr-03/04 | `chart/templates/kyverno-policy.yaml` (opt-in: `network.blockExternalServices=true`) |
| `mdb-rbac-03` | iscf-ia-01 | `chart/templates/serviceaccount.yaml` (`serviceAccount.enabled=true` default) |
| `mdb-enc-05` | iscf-dr-01/05/06 | `diskImage.storageClassName` (encrypted OCS class) |
| `mdb-rs-01` | iscf-re-01/re-03 | `chart/templates/prometheusrule.yaml` (opt-in: `monitoring.enabled=true`) |
| `mdb-gitops-01` | iscf-ia-10/ia-02 | `gitops/policies/argocd-sa-no-cluster-admin.yaml` (Kyverno ClusterPolicy) |
| `mdb-dr-01` | iscf-dr-05/dr-08/re-01 | `chart/templates/volumesnapshotschedule.yaml` (opt-in: `backup.enabled=true`) |
| `mdb-aud-05` | iscf-mi-01/dr-10 | `chart/templates/fluentbit-daemonset.yaml` (opt-in: `logging.fluentbit.enabled=true`) |

### Controls enforced at runtime (cloud-init / first-boot)

| Control | ISCF ref | Enforced by |
|---|---|---|
| `mdb-auth-01` | iscf-ia-06 | `authMechanisms: SCRAM-SHA-256` in `mongod.conf` (first-boot step 8) — SHA-1 never accepted |
| `mdb-enc-02` | iscf-cr-01/dr-06 | `compliance.enableEncryption=true` → `mongo-first-boot.sh` step 8 |
| `mdb-enc-06` | iscf-cr-01/ia-10 | `shred -u /etc/mongo-init-env` after first-boot (step 13) — no plaintext credentials on disk |
| `mdb-aud-01` | iscf-ia-04/gov-03/dr-10 | `compliance.auditLog.enabled=true` → `mongo-first-boot.sh` step 8 |
| `mdb-aud-02` | iscf-ia-04/gov-02/ai-04 | `compliance.auditLog.auditAuthorizationSuccess=true` |
| `mdb-aud-04` | iscf-ia-11/mi-01 | `chattr +a` on audit log path (step 8) — append-only, mongod cannot delete |
| `mdb-vm-01` | iscf-mi-03 | `chronyc tracking` stratum check before sentinel write (step 11) |

### Controls requiring external tooling

| Control | Tool |
|---|---|
| `mdb-virt-02` | RHACS image signature policy — sign with `cosign` after build |
| `mdb-auth-02` | RHACS — no anonymous DB access |
| `mdb-enc-03` | RHACS + KMIP/Vault — key rotation |
| `mdb-aud-03` | Compliance Operator — log retention ≥ 90 days |
| `mdb-rbac-01/02` | RHACS DB user / role scan |

---

## Signing the image (mdb-virt-02)

```bash
# Install cosign on lpar3
dnf install -y cosign

# Sign after pushing ContainerDisk
cosign sign <registry>/byop/mongodb-ea-bootc:8.3.2-s390x
```

---

## Audit evidence baked into the image

After `build.sh` completes (Mode A), the following files are inside the disk
and can be inspected:

```bash
# Extract the STIG HTML report from the qcow2
virt-cat -a /data/securedimage/output/qcow2/rhel9-mongodb-ea-8.3.2-s390x.qcow2 \
  /root/stig-scan-report.html > /tmp/stig-scan-report.html

# Or inspect via the built OCI container image before BIB conversion
podman run --rm localhost/mongodb-ea-bootc:8.3.2 \
  cat /root/stig-scan-results.xml

# Verify FIPS mode is active inside the image
podman run --rm localhost/mongodb-ea-bootc:8.3.2 \
  cat /etc/system-fips
```

| File | Content |
|---|---|
| `/root/stig-scan-report.html` | Human-readable DISA STIG scan report (Mode A) |
| `/root/stig-scan-results.xml` | Machine-readable XCCDF results (Mode A) |
| `/etc/system-fips` | FIPS mode marker file (present = FIPS enabled) |

---

## Troubleshooting

### Build fails: `oscap exited with code 2`

An evaluation *error* (not a finding) — usually means a required SCAP file is
missing, the scap-security-guide package is not fully installed, or the STIG
profile ID is not present in the installed version of scap-security-guide.

```bash
# Verify SCAP content is present
ls /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

# Check the STIG profile is in the datastream
oscap info /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml \
  | grep stig

# Re-install if missing
dnf reinstall scap-security-guide openscap-scanner
```

### Build fails: `fips-mode-setup: command not found`

`fips-mode-setup` is provided by the `crypto-policies-scripts` package on RHEL 9.
It is a dependency of the `scap-security-guide` RPM but may not be installed
if the base image is minimal.

```bash
dnf install -y crypto-policies-scripts dracut-fips
```

### VM first-boot: MongoDB fails to start after FIPS enabled

FIPS mode enforces minimum key sizes (RSA ≥ 2048, no MD5/SHA-1 for auth).
Check whether the keyFile or TLS certificates use deprecated algorithms:

```bash
# Check FIPS is active inside the running VM
cat /proc/sys/crypto/fips_enabled   # must be 1

# Check mongod log for FIPS-related errors
cat /var/log/mongodb/mongod.log | grep -i fips
```

### Build fails: `/dev/kvm not present`

KVM is required by bootc-image-builder for `qemu-img` operations on s390x.

```bash
# Check the module
lsmod | grep kvm
# Load if not loaded
modprobe kvm
ls /dev/kvm
```

### Build fails: `registry.redhat.io` pull error

The `vismitha.pv` account is already logged in on lpar3. If the session expired:

```bash
podman login registry.redhat.io
# Re-run setup
./setup-lpar3.sh
```

### upload.sh fails: CDI upload proxy not found

```bash
# Find the proxy route manually
oc get route -n cdi
oc get route -n openshift-cnv

# Pass it explicitly
UPLOAD_PROXY_URL=https://<proxy-host> ./upload.sh
```

### First-boot fails: `/etc/mongo-init-env not found`

The cloud-init `write_files` block did not run. Check the cloud-init log inside
the VM:

```bash
# Connect via virsh console or oc debug
cat /var/log/cloud-init-output.log
cat /var/log/mongo-first-boot.log
```

This usually means `mongodb.rootPassword` or another required Helm value was
empty when the chart was rendered.

### Replica Set PRIMARY not elected

Check `mongo-rs-init.log` on member-0:

```bash
cat /var/log/mongo-rs-init.log
```

Common causes:
- One or more RS members are not yet reachable (step 2 timeout)
- `ADMIN_PASS` mismatch between members (check `/etc/mongo-init-env` on each)
- keyFile mismatch — all members must share the same keyFile (injected by Helm via `mongodb.keyFile`)
