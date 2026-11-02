# Security Hardening Reference — bootc MongoDB EA on RHEL 9 (s390x)

**Repos:** `securedimage/` · `s390x/byop-sample-repo/services/mongodb-vm/v1/`  
**Image:** `mongodb-ea-rhel9-bootc` · MongoDB Enterprise Advanced 8.x · RHEL 9 · IBM Z (s390x)  
**Framework:** IBM Sovereign Core Framework (ISCF) · DISA STIG RHEL 9 · FIPS 140-3

---

## How to read this document

Every control listed here has:
- **Control ID** — the internal `mdb-*` identifier from the ISCF label set.
- **ISCF cross-references** — the sovereign framework node(s) this maps to.
- **Where enforced** — which layer applies the control.
- **What it does** — a plain description of the concrete action taken.
- **Extra component required** — any external tooling, licence, or infrastructure needed.

Layer abbreviations:

| Layer | Means |
|---|---|
| **IMAGE** | Baked into the bootc OCI image at `podman build` time (`Containerfile`) |
| **CHART** | Applied by Helm at deploy time (Kubernetes resources in `chart/templates/`) |
| **RUNTIME** | Applied at VM first-boot via `mongo-first-boot.sh` + cloud-init |
| **EXTERNAL** | Requires tooling outside this repo (RHACS, Compliance Operator, Vault, etc.) |

---

## Quick-Reference Status Table

Click any control name to jump to its full description below.

| # | Control | Plain-English Summary | Layer | Status | ISCF Refs |
|---|---|---|---|---|---|
| 1 | [mdb-virt-01 — Root SSH disabled](#mdb-virt-01----disable-root-ssh-login-and-password-authentication) | Root SSH login and password auth turned off; root OS password locked | IMAGE | ✅ Applied | iscf-ia-04 |
| 2 | [mdb-virt-04 — SELinux enforcing](#mdb-virt-04----selinux-enforcing-mode--mongodb-type-enforcement) | SELinux set to enforcing; `mongod` confined to its own data/log dirs only | IMAGE | ✅ Applied | iscf-ai-03 |
| 3 | [mdb-s390x-02 — CPACF hardware crypto](#mdb-s390x-02----cpacf-hardware-crypto-awareness) | AES/SHA ops routed to IBM Z CPACF co-processor when FIPS is active | IMAGE | ✅ Applied | — |
| 4 | [STIG automated remediation — OpenSCAP](#stig-automated-remediation-via-openscap) | Full DISA STIG profile applied at build time; scan report baked into image | IMAGE | ✅ Applied | iscf-ai-03, iscf-gov-02/03 |
| 5 | [FIPS 140-3 mode](#fips-140-3-mode) | All crypto restricted to FIPS-approved algorithms; `fips=1` kernel arg pinned | IMAGE | ✅ Applied | iscf-cr-01, iscf-dr-06, iscf-ai-03 |
| 6 | [FIPS marker files](#fips-marker-files) | `/etc/system-fips` and `/etc/fips_enabled` created so apps detect FIPS mode | IMAGE | ✅ Applied | — |
| 7 | [auditd — full STIG config rewrite](#auditd-configuration----full-stig-compliant-rewrite) | All 13 STIG-required auditd fields set (disk-full=HALT, space alerts, enriched format) | IMAGE | ✅ Applied | iscf-ia-04, iscf-gov-02/03 |
| 8 | [auditd — 74 STIG syscall rules](#auditd-rule-loading-via-systemd-drop-in) | Audit rules for DAC changes, file deletion, denied access, kmod, sudoers, SELinux, privilege | IMAGE | ✅ Applied | iscf-ia-04, iscf-gov-02/03 |
| 9 | [Password ageing + hashing rounds](#password-ageing-and-hashing-rounds) | Min length 15, max age 60 days, 5000 SHA rounds enforced in `/etc/login.defs` | IMAGE | ✅ Applied | — |
| 10 | [Service masking — cockpit, debug-shell, kdump](#service-masking----cockpit-debug-shell-kdump) | Three dangerous/unneeded services permanently masked (symlinked to `/dev/null`) | IMAGE | ✅ Applied | — |
| 11 | [Audit file permissions](#audit-file-permissions) | `auditd.conf` → 0640; rules files → 0600/0640 | IMAGE | ✅ Applied | — |
| 12 | [Postfix relay restriction](#postfix-relay-restriction) | Postfix blocked from acting as open mail relay | IMAGE | ✅ Applied | — |
| 13 | [Chrony NTP server directive](#chrony-ntp-server-directive) | `server` directive replaces `pool`; accurate time for audit timestamps | IMAGE | ✅ Applied | — |
| 14 | [Crypto policy — FIPS](#system-wide-crypto-policy----fips) | System-wide FIPS policy covers OpenSSL, GnuTLS, NSS, OpenSSH, curl | IMAGE | ✅ Applied | — |
| 15 | [SSH host key permissions fix](#ssh-host-key-permissions-fix-at-boot) | systemd drop-in sets `0600 root:root` on SSH host keys at every boot | IMAGE | ✅ Applied | — |
| 16 | [Root init file permissions](#root-init-file-permissions) | `.bashrc`, `.bash_profile` etc. set to `0640` (STIG max `0740`) | IMAGE | ✅ Applied | — |
| 17 | [SELinux sudo role expansion](#selinux-sudo-role-expansion) | `staff_u` gains `staff_r`+`sysadm_r` roles for sudo context elevation | IMAGE | ✅ Applied | — |
| 18 | [Kernel sysctl hardening](#kernel-hardening-via-sysctl) | Hardlinks, symlinks, dmesg, kptr, full ASLR — all locked down | IMAGE | ✅ Applied | — |
| 19 | [Secure mount options — /dev/shm, /tmp](#secure-mount-options----devshm-and-tmp) | `nosuid,nodev,noexec` on `/dev/shm`; `noexec` on `/tmp` | IMAGE | ✅ Applied | — |
| 20 | [Separate partitions — /home, /var/log, /var/log/audit, /var/tmp](#separate-partitions----home-varlog-varlogaudit-vartmp) | Four separate partitions; audit data cannot fill root disk | IMAGE + BIB | ✅ Applied | — |
| 21 | [Postfix mail aliases](#postfix-mail-aliases) | `root@localhost` and `postmaster: root` set for audit alert delivery | IMAGE | ✅ Applied | — |
| 22 | [mdb-net-02 — Restrict MongoDB ingress to namespace](#mdb-net-02----restrict-ingress-to-mongodb-port-within-namespace) | NetworkPolicy blocks port 27017 from all sources outside the namespace | CHART | ✅ Applied | iscf-dr-03/04/09 |
| 23 | [mdb-net-04 — Block all MongoDB egress](#mdb-net-04----block-all-egress-from-mongodb-vms) | Empty egress rules prevent MongoDB VM from making any outbound connection | CHART | ✅ Applied | iscf-dr-02/03 |
| 24 | [mdb-rbac-03 — Dedicated OCP ServiceAccount](#mdb-rbac-03----dedicated-serviceaccount-with-minimal-ocp-rbac) | Dedicated SA + Role (read-only pods/configmaps/secrets only); no cluster perms | CHART | ✅ Applied | iscf-ia-10, iscf-ia-12 |
| 25 | [mdb-enc-05 — ODF encrypted storage](#mdb-enc-05----odf-encrypted-storage-class-for-boot-pvc) | Boot PVC on ODF encrypted Ceph RBD (AES-256 block layer) — opt-in per instance | CHART | ⚠️ Off by default | iscf-dr-01/05/06 |
| 26 | [MongoDB no credentials baked in](#mongodb-no-credentials-baked-in) | All secrets injected at first boot via cloud-init; nothing in the image | RUNTIME | ✅ Applied | — |
| 27 | [MongoDB auth + keyFile](#mongodb-authentication--keyfile-mandatory) | mongod starts with `authorization: enabled` + keyFile after setup; setup window loopback-only | RUNTIME | ✅ Applied | iscf-ia-01/04 |
| 28 | [mdb-enc-02 — WiredTiger encryption-at-rest](#mdb-enc-02----wiredtiger-encryption-at-rest) | `security.enableEncryption: true` + `security.encryptionKeyFile` written into the `security:` block of `mongod.conf` at first boot (local per-node key) | RUNTIME | ⚠️ Off by default | iscf-cr-01, iscf-dr-06 |
| 29 | [mdb-aud-01 — MongoDB JSON audit log](#mdb-aud-01----mongodb-json-audit-log) | JSON audit log written to `/var/log/mongodb/audit.json` | RUNTIME | ⚠️ Off by default | iscf-ia-04, iscf-ia-11, iscf-gov-03, iscf-dr-10 |
| 30 | [mdb-aud-02 — Audit all auth decisions](#mdb-aud-02----audit-all-authorization-decisions-not-just-failures) | `auditAuthorizationSuccess: true` — successful auths logged too | RUNTIME | ⚠️ Off by default | iscf-ia-11, iscf-mi-01, iscf-gov-02, iscf-ai-04 |
| 31 | [rsyslog forwarding to SIEM](#rsyslog-forwarding-to-siem) | mongod.log + audit.json tailed and forwarded to remote syslog/SIEM | RUNTIME | ⚠️ Off by default | — |
| 32 | [mdb-aud-03 — Log retention ≥ 90 days](#) | Requires Compliance Operator log retention policy | EXTERNAL | ❌ Not implemented | iscf-ia-04, iscf-mi-01 |
| 33 | [mdb-auth-02 — No anonymous DB access](#) | Requires RHACS policy scanning MongoDB users collection | EXTERNAL | ❌ Not implemented | iscf-ia-06 |
| 34 | [mdb-enc-01 — TLS in-transit](#) | Requires TLS certs + Phase 3 chart work | EXTERNAL | ❌ Phase 3 planned | iscf-cr-03, iscf-dr-07, iscf-ai-03 |
| 35 | [mdb-enc-03 — Key rotation < 365 days](#) | Requires RHACS + KMIP/Vault | EXTERNAL | ❌ Not implemented | iscf-cr-01, iscf-cr-02 |
| 35b | [mdb-enc-03b — KMIP key server configured](#) | Requires cluster-level KMIP infrastructure | EXTERNAL | ❌ Not implemented | iscf-cr-01, iscf-cr-02 |
| 36 | [mdb-enc-06 — No plaintext credentials world-readable](#) | `/etc/mongo-init-env` must be 0600 + shredded after use | RUNTIME | ✅ Applied | iscf-cr-01, iscf-ia-10 |
| 37 | [mdb-rbac-01 — Least-privilege DB roles](#) | Requires RHACS DB user scan policy | EXTERNAL | ❌ Not implemented | iscf-ia-10 |
| 38 | [mdb-rbac-02 — No root role in production](#) | Requires RHACS role scan | EXTERNAL | ❌ Not implemented | iscf-ia-10, iscf-ia-02 |
| 39 | [mdb-rbac-04 — VM RBAC approved users](#) | Requires Compliance Operator namespace policy | EXTERNAL | ❌ Not implemented | iscf-ia-11, iscf-ia-03 |
| 40 | [mdb-virt-02 — Boot image signed](#) | Requires RHACS image signature policy (cosign) | EXTERNAL | ❌ Not implemented | — |
| 41 | [mdb-auth-03a — keyFile RS inter-member auth](#) | keyFile `/etc/mongodb-keyfile` — all RS members share the same keyFile (HA mode) | RUNTIME | ✅ Applied | iscf-dr-07, iscf-cr-03 |
| 42 | [mdb-auth-03b — mTLS client auth](#) | Requires mdb-enc-01 first; Phase 3 planned | EXTERNAL | ❌ Phase 3 planned | iscf-cr-03, iscf-dr-07 |

**Legend:** ✅ Applied and active &nbsp;·&nbsp; ⚠️ Code exists, switched off by default &nbsp;·&nbsp; ❌ Not yet implemented

---

## Part 1 — Controls Applied

### 1.1 OS Hardening (IMAGE layer)

---

#### `mdb-virt-01` — Disable root SSH login and password authentication
**ISCF:** `iscf-ia-04`  
**Layer:** IMAGE · `Containerfile` §8  
**Source file:** [`Containerfile:169`](securedimage/Containerfile)

Sets `PermitRootLogin no` and `PasswordAuthentication no` in `/etc/ssh/sshd_config`.  
Root's OS password is locked with `passwd -l root`.  
The setup window inside `mongo-first-boot.sh` only listens on loopback `127.0.0.1`, so no unauthenticated service is ever reachable from the pod network.

> **Extra component:** None. Baked in unconditionally.

---

#### `mdb-virt-04` — SELinux enforcing mode + MongoDB type enforcement
**ISCF:** `iscf-ai-03`  
**Layer:** IMAGE · `Containerfile` §8  
**Source file:** [`Containerfile:183`](securedimage/Containerfile)

Forces `SELINUX=enforcing` in `/etc/selinux/config`.  
Applies custom SELinux file-context labels:
- `/var/lib/mongo(/.*)?` → `mongod_db_t`
- `/var/log/mongodb(/.*)?` → `mongod_log_t`

This confines the `mongod` process so it can only read/write its own data and log directories. Attempts to access other paths are denied by the kernel MAC layer, independent of DAC (Unix permission) checks.

> **Extra component:** `policycoreutils-python-utils` package (installed in §2).

---

#### `mdb-s390x-02` — CPACF hardware crypto awareness
**ISCF:** Referenced via `com.ibm.sovereigncore.compliance.in-image` label  
**Layer:** IMAGE · build target architecture  
**Source file:** [`Containerfile:25`](securedimage/Containerfile)

The base image is `registry.redhat.io/rhel9/rhel-bootc:9.6` built for `linux/s390x`. On IBM Z, the CPACF co-processor is available in the hardware and OpenSSL's FIPS mode (enabled in §8c) automatically routes AES, SHA-2, and RNG operations to CPACF instructions (`km`, `kmc`, `kimd`, `klmd`). No software-only fallback is used when FIPS mode is active.

> **Extra component:** IBM Z LPAR with CPACF enabled (standard on all z15/z16). Verification script reports to Concert API.

---

### 1.2 DISA STIG RHEL 9 Automated Remediation (IMAGE layer)

---

#### STIG automated remediation via OpenSCAP
**Control name:** DISA STIG RHEL 9 baseline  
**ISCF:** `iscf-ai-03`, `iscf-gov-02`, `iscf-gov-03`  
**Layer:** IMAGE · `Containerfile` §8b  
**Source file:** [`Containerfile:232`](securedimage/Containerfile)

Runs `oscap xccdf eval --remediate` with the full DISA STIG profile (`xccdf_org.ssgproject.content_profile_stig`) against the RHEL 9 SCAP data stream at build time.

**What it fixes automatically:**
- Service masking (unnecessary daemons disabled)
- PAM configuration (password quality, account locking)
- SSH hardening (cipher suites, MACs, timeouts)
- Filesystem permissions across `/etc`, `/var`, `/tmp`
- Kernel parameter files in `/etc/sysctl.d/`
- Audit rules written to `/etc/audit/rules.d/`
- `/etc/login.defs` password ageing defaults

The scan report is saved as `/root/stig-scan-report.html` and results XML as `/root/stig-scan-results.xml` inside the image for audit evidence.

> **Extra component:** `openscap-scanner` + `scap-security-guide` packages (installed in §2).

---

#### FIPS 140-3 mode
**Control name:** FIPS 140-3 cryptographic module enforcement  
**ISCF:** `iscf-cr-01`, `iscf-dr-06`, `iscf-ai-03`  
**Layer:** IMAGE · `Containerfile` §8c  
**Source file:** [`Containerfile:263`](securedimage/Containerfile)

Runs `fips-mode-setup --enable` and `update-crypto-policies --set FIPS`.  
Creates marker files `/etc/system-fips` and `/etc/fips_enabled`.  
The `fips=1` kernel argument is pinned in the bootc install config at `/usr/lib/bootc/install/10-disk-layout.toml` so it survives `bootc upgrade` across OCI updates.

**Effect:** All cryptographic operations — OpenSSL, GnuTLS, libgcrypt, OpenSSH — are restricted to FIPS 140-3 approved algorithms only. Non-approved ciphers (DES, RC4, MD5 for signatures, SHA-1 for signing) are rejected at the library level.

On IBM Z, FIPS mode additionally enables routing of approved operations through the CPACF co-processor.

> **Extra component:** `dracut-fips` package (installed in §2).

---

#### FIPS marker files
**Control name:** `fips-mode-setup --check` sentinel files  
**Layer:** IMAGE · `Containerfile` §8d/§12.1  
**Source file:** [`Containerfile:281`](securedimage/Containerfile)

`fips-mode-setup --enable` inside a container rootfs cannot set kernel boot args, so the `/etc/system-fips` and `/etc/fips_enabled` marker files are created explicitly. FIPS-aware applications (including MongoDB `mongocryptd`) check these files at startup to confirm FIPS mode is active.

---

#### auditd configuration — full STIG-compliant rewrite
**Control name:** Multiple STIG `auditd_*` rules  
**Layer:** IMAGE · `Containerfile` §8d/§12.2  
**Source file:** [`Containerfile:296`](securedimage/Containerfile)

Writes a complete `/etc/audit/auditd.conf` covering all 13 STIG-required fields:

| Field | Value | Why |
|---|---|---|
| `log_format` | `ENRICHED` | Adds UID/GID resolution to log entries |
| `name_format` | `HOSTNAME` | Identifies origin host in distributed deployments |
| `space_left` | `25%` | Triggers email alert at 25 % disk remaining |
| `space_left_action` | `email` | Notify `root` when space is low |
| `admin_space_left` | `5%` | Emergency threshold |
| `admin_space_left_action` | `SINGLE` | Drop to single-user mode at critical low disk |
| `disk_full_action` | `HALT` | Halt the system rather than lose audit data |
| `disk_error_action` | `HALT` | Same for I/O errors on the audit log device |
| `action_mail_acct` | `root` | Destination for administrative alerts |
| `overflow_action` | `SYSLOG` | Overflow events go to syslog, not silently dropped |
| `freq` | `50` | Flush audit buffer every 50 records |
| `local_events` | `yes` | Record events originating on this host |
| `max_log_file_action` | `rotate` | Rotate rather than halt on log file size limit |

---

#### auditd rule loading via systemd drop-in
**Control name:** `audit_rules_*` — 74 STIG syscall rules  
**Layer:** IMAGE · `Containerfile` §8d/§12.3 + §8e-A  
**Source file:** [`Containerfile:355`](securedimage/Containerfile) · [`scripts/write-audit-rules.sh`](securedimage/scripts/write-audit-rules.sh)

A systemd drop-in at `/etc/systemd/system/auditd.service.d/10-load-rules.conf` runs `augenrules --load` after `auditd` starts, merging all rules from `/usr/share/audit/rules.d/` and `/etc/audit/rules.d/`.

**Rule files written by [`write-audit-rules.sh`](securedimage/scripts/write-audit-rules.sh):**

| File | Key | What is audited |
|---|---|---|
| `20-syscall-dac.rules` | `perm_mod` | `chmod`, `chown`, `setxattr`, `umount` — DAC permission changes |
| `21-syscall-delete.rules` | `delete` | `rename`, `rmdir`, `unlink` — file deletion events |
| `22-syscall-open.rules` | `access` | `open`, `creat`, `truncate` with `-EACCES`/`-EPERM` — denied file access |
| `23-syscall-kmod.rules` | `modules` | `init_module`, `delete_module` — kernel module load/unload |
| `24-usergroup.rules` | `identity` | Writes to `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow` |
| `25-login.rules` | `logins` | Writes to `/var/log/faillock`, `/var/log/lastlog` |
| `26-sudoers.rules` | `actions` | Writes to `/etc/sudoers`, `/etc/sudoers.d/` |
| `27-selinux.rules` | `MAC-policy` | Execution of `chcon`, `semanage`, `setfiles`, `setsebool`, `setfacl` |
| `28-privileged.rules` | `privileged` | Execution of `sudo`, `su`, `passwd`, `mount`, `poweroff`, `usermod`, and 18 others |
| `29-suid.rules` | `setuid`/`setgid` | Any `execve` where UID or GID changes (SUID/SGID bit execution) |
| `30-shutdown.rules` | — | `-f 2` kernel audit failure mode: panic on audit subsystem failure |
| `31-cron.rules` | `cron` | Writes to all `/etc/cron.*` directories and `/etc/crontab` |
| `99-finalize.rules` | — | `-e 2` immutable flag: locks audit config until reboot |

Rules are also copied to `/etc/audit/rules.d/` so OpenSCAP OVAL checks (which read rule files directly without calling `auditctl`) pass at scan time.

---

#### Password ageing and hashing rounds
**Control name:** `accounts_password_minlen_login_defs`, `accounts_password_set_max_life_existing`, `set_password_hashing_min_rounds_logindefs`  
**Layer:** IMAGE · `Containerfile` §8d/§12.4  
**Source file:** [`Containerfile:365`](securedimage/Containerfile)

Sets in `/etc/login.defs`:
- `PASS_MIN_LEN 15` — minimum password length
- `PASS_MAX_DAYS 60` — maximum password age (60 days)
- `PASS_MIN_DAYS 1` — minimum days before password change
- `SHA_CRYPT_MIN_ROUNDS 5000` — minimum bcrypt/SHA rounds (slows brute-force)

`chage` is run against all non-system accounts and root to apply the new max/min ages immediately.

---

#### Service masking — cockpit, debug-shell, kdump
**Control name:** `service_cockpit_disabled`, `service_debug-shell_disabled`, `service_kdump_disabled`  
**Layer:** IMAGE · `Containerfile` §8d/§12.5  
**Source file:** [`Containerfile:381`](securedimage/Containerfile)

Three services with no operational purpose in a headless production VM are masked (symlinked to `/dev/null`):
- `cockpit.service` — web-based OS management console (attack surface, not needed)
- `debug-shell.service` — opens a root shell on `tty9` (severe privilege escalation risk)
- `kdump.service` — kernel crash dump (not needed; crash dumps can leak sensitive memory)

---

#### Audit file permissions
**Control name:** `file_permissions_audit_configuration`, `file_permissions_audit_configuration_stig`  
**Layer:** IMAGE · `Containerfile` §8d/§12.6  
**Source file:** [`Containerfile:386`](securedimage/Containerfile)

- `/etc/audit/auditd.conf` → mode `0640`
- All `/etc/audit/rules.d/*.rules` → mode `0600`
- All `/etc/audit/*.conf` → mode `0640`

---

#### Postfix relay restriction
**Control name:** `postfix_prevent_unrestricted_relay`  
**Layer:** IMAGE · `Containerfile` §8e-C  
**Source file:** [`Containerfile:448`](securedimage/Containerfile)

Sets `smtpd_relay_restrictions = permit_mynetworks, reject` in Postfix configuration via `postconf -e`. This prevents the postfix daemon (present in the RHEL 9 base) from acting as an open mail relay.

> **Extra component:** None. Postfix is in the RHEL 9 base image.

---

#### Chrony NTP server directive
**Control name:** `chronyd_server_directive`  
**Layer:** IMAGE · `Containerfile` §8e-D  
**Source file:** [`Containerfile:456`](securedimage/Containerfile)

Replaces the default `pool` directive in `/etc/chrony.conf` with a `server` directive pointing to `0.rhel.pool.ntp.org iburst maxpoll 16`. DISA STIG requires an explicit `server` line, not a `pool` line. Accurate time is critical for audit log timestamps and TLS certificate validation.

> **Production note:** Override `/etc/chrony.conf` via cloud-init `runcmd` with your site-specific internal NTP server.

---

#### System-wide crypto policy — FIPS
**Control name:** `configure_crypto_policy`  
**Layer:** IMAGE · `Containerfile` §8e-E  
**Source file:** [`Containerfile:468`](securedimage/Containerfile)

`update-crypto-policies --set FIPS` enforces FIPS-approved algorithms across all applications that respect the system crypto policy (OpenSSL, GnuTLS, NSS, OpenSSH, curl, etc.).

> **Accepted finding:** DISA STIG expects `FIPS:STIG`. The STIG sub-policy removes RSA-SHA2-256/512 from `PubkeyAcceptedAlgorithms`, which causes `sshd` to fail to load RSA host keys on first boot. The build uses `FIPS` (without `:STIG`) as an operational safety exception. This is a single documented accepted finding.

---

#### SSH host key permissions fix at boot
**Control name:** `file_permissions_sshd_private_key`  
**Layer:** IMAGE · `Containerfile` §8e-F  
**Source file:** [`Containerfile:478`](securedimage/Containerfile)

A systemd drop-in at `/etc/systemd/system/sshd.service.d/10-key-perms.conf` runs `/usr/libexec/sshd-fixperms/fix-host-key-perms.sh` before `sshd` starts on every boot. The script sets `chmod 0600 root:root` on all SSH host private key files. RHEL 9 generates keys at `0640 root:ssh_keys`; STIG requires `0600 root:root`.

---

#### Root init file permissions
**Control name:** `file_permission_user_init_files_root`  
**Layer:** IMAGE · `Containerfile` §8e-G  
**Source file:** [`Containerfile:491`](securedimage/Containerfile)

Sets all of root's shell init files (`.bashrc`, `.bash_profile`, `.bash_logout`, `.profile`, `.cshrc`, `.tcshrc`) to mode `0640`. STIG requires these files to be no more permissive than `0740`.

---

#### SELinux sudo role expansion
**Control name:** `selinux_context_elevation_for_sudo`  
**Layer:** IMAGE · `Containerfile` §8e-H  
**Source file:** [`Containerfile:506`](securedimage/Containerfile)

Adds `staff_r` and `sysadm_r` roles to the `staff_u` SELinux user mapping via `semanage user -m -R`. This allows users mapped to `staff_u` to elevate to `sysadm_r` via `sudo` in confined contexts.

> **Accepted finding:** The `__default__` → `staff_u` login mapping is intentionally omitted. Mapping all users to `staff_u` breaks OpenSCAP's ability to audit rule verification because `staff_t` processes cannot traverse `auditd_conf_t:0700` directories. The login mapping is an accepted finding (1 rule).

---

#### Kernel hardening via sysctl
**Control name:** `sysctl_fs_protected_hardlinks`, `sysctl_fs_protected_symlinks`, `sysctl_kernel_dmesg_restrict`, `sysctl_kernel_kptr_restrict`, `sysctl_kernel_randomize_va_space`  
**Layer:** IMAGE · `Containerfile` §8e-I  
**Source file:** [`Containerfile:516`](securedimage/Containerfile)

Writes `/etc/sysctl.d/99-stig-hardening.conf`:

| Parameter | Value | Effect |
|---|---|---|
| `fs.protected_hardlinks` | `1` | Prevents hard-link attacks (CVE-style privilege escalation via `/tmp`) |
| `fs.protected_symlinks` | `1` | Prevents symlink attacks in sticky-bit directories |
| `kernel.dmesg_restrict` | `1` | Restricts `dmesg` to processes with `CAP_SYSLOG` (hides kernel pointers from unprivileged users) |
| `kernel.kptr_restrict` | `1` | Hides kernel symbol addresses in `/proc/kallsyms` from non-root |
| `kernel.randomize_va_space` | `2` | Full ASLR — randomises stack, heap, and shared library base addresses |

---

#### Secure mount options — /dev/shm and /tmp
**Control name:** `mount_option_dev_shm_nodev/noexec/nosuid`, `mount_option_tmp_noexec`  
**Layer:** IMAGE · `Containerfile` §8e-J  
**Source file:** [`Containerfile:533`](securedimage/Containerfile)

Systemd mount drop-ins override default options for the two ephemeral filesystems:

| Mount | Options set | Effect |
|---|---|---|
| `/dev/shm` | `nosuid,nodev,noexec` | Shared memory cannot contain setuid binaries or be executed directly |
| `/tmp` | `mode=1777,strictatime,nosuid,nodev,noexec` | `/tmp` cannot be used to stage and execute attack payloads |

---

#### Separate partitions — /home, /var/log, /var/log/audit, /var/tmp
**Control name:** `partition_for_home`, `partition_for_var_log`, `partition_for_var_log_audit`, `partition_for_var_tmp`  
**Layer:** IMAGE · `Containerfile` §8e-L  
**Source file:** [`Containerfile`](securedimage/Containerfile)

`/etc/fstab` entries are written in the OCI layer for `/home`, `/var/log`, `/var/log/audit` (bind mounts) and `/var/tmp` (tmpfs) so the STIG `partition_for_*` rules pass at scan time.

---

#### Postfix mail aliases
**Control name:** `postfix_client_configure_mail_alias`, `postfix_client_configure_mail_alias_postmaster`  
**Layer:** IMAGE · `Containerfile` §8e-K  
**Source file:** [`Containerfile:599`](securedimage/Containerfile)

Ensures `/etc/aliases` contains:
- `root: root@localhost`
- `postmaster: root`

`newaliases` is run to rebuild the alias database. STIG requires these entries so audit daemon email alerts (triggered by low-disk `space_left_action = email`) are delivered correctly.

---

### 1.3 Network Controls (CHART layer)

---

#### `mdb-net-02` — Restrict ingress to MongoDB port within namespace
**ISCF:** `iscf-dr-03`, `iscf-dr-04`, `iscf-dr-09`  
**Layer:** CHART · `chart/templates/networkpolicy.yaml`  
**Source file:** [`chart/templates/networkpolicy.yaml:59`](s390x/byop-sample-repo/services/mongodb-vm/v1/chart/templates/networkpolicy.yaml)

A `NetworkPolicy` allows inbound TCP connections to port `27017` only from pods within the same namespace (`podSelector: {}`). All other ingress — from other namespaces, external LoadBalancers, or node-local processes outside the namespace — is denied at the OVN-Kubernetes network layer before packets reach the VM.

**Controlled by:** `networkPolicy.enabled` in `values.yaml` (default: `true`).

> **Extra component:** OCP Virt with OVN-Kubernetes CNI (the default on OCP 4.14+).

---

#### `mdb-net-04` — Block all egress from MongoDB VMs
**ISCF:** `iscf-dr-02`, `iscf-dr-03`  
**Layer:** CHART · `chart/templates/networkpolicy.yaml`  
**Source file:** [`chart/templates/networkpolicy.yaml:66`](s390x/byop-sample-repo/services/mongodb-vm/v1/chart/templates/networkpolicy.yaml)

The `NetworkPolicy` specifies `egress: []` (empty rules), which blocks all outbound connections from MongoDB VM pods. MongoDB replica-set inter-member traffic stays within the cluster overlay pod CIDR and is allowed implicitly within the same namespace by OVN-Kubernetes without an explicit egress rule.

This prevents a compromised MongoDB process from exfiltrating data to an external destination or reaching internal services it should not access.

---

### 1.4 OCP RBAC Controls (CHART layer)

---

#### `mdb-rbac-03` — Dedicated ServiceAccount with minimal OCP RBAC
**ISCF:** `iscf-ia-01`  
**Layer:** CHART · `chart/templates/serviceaccount.yaml`  
**Source file:** [`chart/templates/serviceaccount.yaml:26`](s390x/byop-sample-repo/services/mongodb-vm/v1/chart/templates/serviceaccount.yaml)

Creates three Kubernetes resources:
- `ServiceAccount` — `<instance>-mongo`, namespaced
- `Role` — grants **read-only** `get`/`list` on `pods`, `configmaps`, `secrets` within the namespace only. No `create`, `delete`, or `patch` verbs. No cluster-scoped resources.
- `RoleBinding` — binds the Role to the ServiceAccount

The `virt-launcher` pod runs under this SA. If the pod is compromised, the attacker cannot escalate to cluster-admin or modify workloads.

**Controlled by:** `serviceAccount.enabled` in `values.yaml` (default: `true`).

---

### 1.5 Encrypted Storage (CHART layer)

---

#### `mdb-enc-05` — ODF encrypted storage class for boot PVC
**ISCF:** `iscf-dr-01`, `iscf-dr-05`, `iscf-dr-06`  
**Layer:** CHART · `chart/templates/datavolume.yaml` via `values.yaml`  
**Source file:** [`values.yaml:99`](s390x/byop-sample-repo/services/mongodb-vm/v1/chart/values.yaml)

When `diskImage.storageClassName` is set to `ocs-storagecluster-ceph-rbd-encrypted`, CDI provisions the VM boot PVC using ODF's Ceph RBD encrypted storage class. This enables AES-256 encryption of the data at the block layer, managed by the ODF cluster (Ceph `dm-crypt`). The encryption key is managed by ODF's internal key management.

> **Default value is the non-encrypted class** (`ocs-storagecluster-ceph-rbd-virtualization`). Must be explicitly set per instance via the BYOP broker `storage_class_name` parameter to enable this control.
>
> **Extra component:** OpenShift Data Foundation (ODF) with the encrypted RBD storage class provisioned.

---

### 1.6 MongoDB Database Security (RUNTIME layer — cloud-init injected)

---

#### MongoDB no-credentials baked in
**Layer:** IMAGE design principle  
**Source file:** [`Containerfile:14`](securedimage/Containerfile)

No passwords, keyFiles, or secrets are written into the OCI image. The skeleton `mongod.conf` in the image binds only to `127.0.0.1` with no authentication. All credentials are injected at first boot via `/etc/mongo-init-env` written by cloud-init from Helm-rendered values.

---

#### MongoDB authentication + keyFile (mandatory)
**Layer:** RUNTIME · `scripts/mongo-first-boot.sh`  
**Source file:** [`scripts/mongo-first-boot.sh:260`](securedimage/scripts/mongo-first-boot.sh)

At first boot, `mongo-first-boot.sh` performs the setup sequence:
1. Generates or reads the keyFile (`openssl rand -base64 756`, mode `0400 mongod:mongod`)
2. Starts `mongod` bound to loopback only — the unauthenticated setup window is never exposed to the pod network
3. Creates admin user and application DB user using `python3`/`pymongo` (no `mongosh` on s390x)
4. Rewrites `mongod.conf` with `security.authorization: enabled` and `security.keyFile: /etc/mongodb-keyfile`
5. Restarts `mongod` — the first externally-facing start already has full authentication

---

#### `mdb-enc-02` — WiredTiger encryption-at-rest
**ISCF:** `iscf-cr-01`, `iscf-dr-06`  
**Layer:** RUNTIME · `scripts/mongo-first-boot.sh` §6b  
**Source file:** [`scripts/mongo-first-boot.sh:269`](securedimage/scripts/mongo-first-boot.sh)

When `compliance.enableEncryption: true` is set in `values.yaml`, the first-boot script generates a per-node local key file `/etc/mongodb-encryption-key` (`openssl rand -base64 32`, mode `0400`, owner `mongod`) and writes `security.enableEncryption: true` and `security.encryptionKeyFile` into the `security:` block of `mongod.conf`. Encryption is on from the very first data file: the key is created and the setting applied before the first (standalone) mongod start, because WiredTiger encryption cannot be enabled on a dbPath that already holds data. First boot aborts with an error if `/var/lib/mongo/WiredTiger.wt` already exists without a key, so a redeploy with encryption **must use a fresh data disk**. The key is **not** derived from the replica-set keyFile.

> **Limitation:** the local key file lives on the root disk of the same VM. It protects a stolen or cloned data volume only if the root disk is not taken with it. Use KMIP (section 3.2, `mdb-enc-03b`) to keep the key off the VM.
>
> **Wrong placement fails:** `enableEncryption` under `setParameter:` makes mongod exit with `Unknown --setParameter 'enableEncryption'`.
>
> **Not verified:** the SELinux `mongod_t` access to `/etc/mongodb-encryption-key` has not been confirmed on a running VM yet.

**Controlled by:** `compliance.enableEncryption` in `values.yaml` (default: `false`).

> **Extra component:** MongoDB Enterprise Advanced licence (not available in Community Edition).  
> **Pair with:** `diskImage.storageClassName = ocs-storagecluster-ceph-rbd-encrypted` for defence-in-depth (block layer + application layer encryption).

---

#### `mdb-aud-01` — MongoDB JSON audit log
**ISCF:** `iscf-ia-04`, `iscf-gov-03`, `iscf-dr-10`  
**Layer:** RUNTIME · `scripts/mongo-first-boot.sh` §6c  
**Source file:** [`scripts/mongo-first-boot.sh:284`](securedimage/scripts/mongo-first-boot.sh)

When `compliance.auditLog.enabled: true` is set, the first-boot script appends an `auditLog` block to `mongod.conf`:
```yaml
auditLog:
  destination: file
  format: JSON
  path: /var/log/mongodb/audit.json
```
This creates a structured JSON audit log recording all administrative operations, authentication events, schema changes, and privilege escalation attempts.

**Controlled by:** `compliance.auditLog.enabled` in `values.yaml` (default: `false`).

> **Extra component:** MongoDB Enterprise Advanced licence.

---

#### `mdb-aud-02` — Audit all authorization decisions (not just failures)
**ISCF:** `iscf-ia-04`, `iscf-gov-02`, `iscf-ai-04`  
**Layer:** RUNTIME · `scripts/mongo-first-boot.sh` §6c  
**Source file:** [`scripts/mongo-first-boot.sh:300`](securedimage/scripts/mongo-first-boot.sh)

When `compliance.auditLog.enabled: true`, also sets `setParameter.auditAuthorizationSuccess: true` in `mongod.conf`. This causes MongoDB to log **every** authorization decision — not just denied ones. This is required for forensic traceability: an attacker who successfully authenticates will still produce a trail.

**Controlled by:** `compliance.auditLog.auditAuthorizationSuccess` in `values.yaml` (default: `true`).

> **Extra component:** MongoDB Enterprise Advanced licence.

---

### 1.7 Log Forwarding — rsyslog (RUNTIME layer, optional)

---

#### rsyslog forwarding to SIEM
**Layer:** RUNTIME · `scripts/mongo-first-boot.sh` §8  
**Source file:** [`scripts/mongo-first-boot.sh:346`](securedimage/scripts/mongo-first-boot.sh)

When `logging.rsyslog.enabled: true`, the first-boot script generates `/etc/rsyslog.d/60-mongodb.conf` using `imfile` to tail:
- `/var/log/mongodb/mongod.log` — tagged `mongodb-mongod` on facility `local6`
- `/var/log/mongodb/audit.json` — tagged `mongodb-audit` on facility `local7` (when audit is enabled)

Both streams can be forwarded to a remote syslog server (SIEM) over TCP or UDP, in RFC-5424, RFC-3164, or JSON format. Rate limiting (`intervalSeconds`/`burstCount`) prevents log-storm conditions from exhausting the syslog buffer.

**Controlled by:** `logging.rsyslog.*` in `values.yaml`.

> **Extra component:** A reachable syslog/SIEM receiver endpoint (Splunk, QRadar, Elasticsearch, etc.).

---

## Part 2 — Compliance Controls Present But Not Applied

These controls are defined in the ISCF label set and documented in the codebase but are **not yet active by default**. They require either additional infrastructure, a licence, or are pending a future implementation phase.

| Control ID | ISCF Refs | Status | What it requires |
|---|---|---|---|
| `mdb-enc-02` | `iscf-cr-01`, `iscf-dr-06` | ⚠️ Off by default | Set `compliance.enableEncryption: true`. Requires MongoDB EA licence + `mongocryptd` daemon. |
| `mdb-aud-01` | `iscf-ia-04`, `iscf-gov-03`, `iscf-dr-10` | ⚠️ Off by default | Set `compliance.auditLog.enabled: true`. Requires MongoDB EA licence. |
| `mdb-aud-02` | `iscf-ia-04`, `iscf-gov-02`, `iscf-ai-04` | ⚠️ Off by default | Same as `mdb-aud-01`. Enabled automatically when audit is on. |
| `mdb-aud-03` | `iscf-ia-04`, `iscf-mi-01` | ❌ Not implemented | Log retention ≥ 90 days. Requires **Compliance Operator** with a log volume retention policy attached to `/var/log/mongodb`. |
| `mdb-auth-02` | `iscf-ia-06` | ❌ Not implemented | No anonymous MongoDB DB access. Requires **RHACS** policy scanning the `users` collection for anonymous roles. |
| `mdb-enc-01` | `iscf-cr-03`, `iscf-dr-07`, `iscf-ai-03` | ❌ Phase 3 planned | TLS in-transit for MongoDB connections. Requires TLS certificates as a Kubernetes Secret. Phase 3 work — `compliance.tls.*` values block is stubbed but not active. |
| `mdb-enc-03` | `iscf-cr-01`, `iscf-cr-02` | ❌ Not implemented | Encryption key rotation < 365 days. Requires **RHACS** + **KMIP server** (HashiCorp Vault or IBM Key Protect). |
| `mdb-enc-03b` | `iscf-cr-01`, `iscf-cr-02` | ❌ Not implemented | KMIP key server configured. Requires cluster-level KMIP infrastructure. Previously mislabelled as `mdb-enc-06`. |
| `mdb-enc-06` | `iscf-cr-01`, `iscf-ia-10` | ✅ Applied (CLOUDPAKS-4607) | No plaintext credentials world-readable in VM. `/etc/mongo-init-env` written `0600` by cloud-init; shredded after first-boot. On member-0 a `0600` copy `/etc/mongo-rs-init.env` is kept only until `mongo-rs-init.service` has a PRIMARY, then shredded (the former plaintext `/tmp/mongo-init-env.bak` no longer exists). Previously misdefined as KMIP — corrected per CLOUDPAKS-4603. |
| `mdb-enc-05` | `iscf-dr-01`, `iscf-dr-05`, `iscf-dr-06` | ⚠️ Off by default | Set `diskImage.storageClassName: ocs-storagecluster-ceph-rbd-encrypted`. Default uses non-encrypted class. Requires **ODF** encrypted storage class. |
| `mdb-rbac-01` | `iscf-ia-10` | ❌ Not implemented | Least-privilege MongoDB DB roles (no `root` role for app users). Requires **RHACS** DB user scan policy. |
| `mdb-rbac-02` | `iscf-ia-10`, `iscf-ia-02` | ❌ Not implemented | No `root` role in production MongoDB users. Requires **RHACS** role scan. |
| `mdb-rbac-04` | `iscf-ia-11`, `iscf-ia-03` | ❌ Not implemented | VM RBAC approved users only. Requires **Compliance Operator** policy on VM namespace access. |
| `mdb-virt-02` | — | ❌ Not implemented | Boot image signed and signature verified before VM start. Requires **RHACS** image signature policy (cosign/sigstore). |
| `mdb-auth-03a` | `iscf-dr-07`, `iscf-cr-03` | ✅ Applied (HA mode) | keyFile inter-member auth — all RS members share `/etc/mongodb-keyfile`. Active when `ha.enabled=true`. Previously mislabelled as `mdb-auth-03` (same ID as mTLS). |
| `mdb-auth-03b` | `iscf-cr-03`, `iscf-dr-07` | ❌ Phase 3 planned | mTLS client certificate authentication for MongoDB. Depends on `mdb-enc-01` being implemented first. Previously mislabelled as `mdb-auth-03` (same ID as keyFile). |
| configure_crypto_policy (FIPS:STIG) | — | ⚠️ Accepted finding | `FIPS:STIG` sub-policy breaks `sshd` on first boot. Currently using `FIPS` only. Documented accepted finding. |
| selinux_context_elevation (login mapping) | — | ⚠️ Accepted finding | `__default__ → staff_u` login mapping breaks OpenSCAP audit rule verification. Documented accepted finding. |

---

## Part 3 — Suggested Additional Controls

The following are not currently implemented and are not in the existing control set. They are recommended based on the threat model for a production database VM on IBM Z running sensitive workloads.

---

### 3.1 In-transit TLS for MongoDB (Phase 3 — already planned)

**What:** Enable `net.tls.mode: requireTLS` in `mongod.conf` with CA-signed certificates.  
**Why:** All current MongoDB connections between the application and the database are unencrypted. An attacker with network access inside the namespace can eavesdrop on queries and results, including any data that passes through the connection.  
**How:** The `values.yaml` already has a stubbed `compliance.tls` block. Implement Phase 3:
1. Issue TLS certificates per VM via cert-manager (or mount from a Kubernetes Secret).
2. Add `net.tls.mode: requireTLS`, `net.tls.certificateKeyFile`, `net.tls.CAFile` to `mongod.conf` in the first-boot script.
3. Set `net.tls.minimumProtocolVersion: TLS1_2` (IBM security policy minimum; TLS 1.3 preferred).

**Maps to:** `mdb-enc-01` (iscf-cr-03/dr-07/ai-03), `mdb-auth-03b` (iscf-cr-03/dr-07)
**Extra component:** cert-manager or an internal PKI.

---

### 3.2 KMIP External Key Management for WiredTiger Encryption

**What:** Configure MongoDB's `security.kmip.*` block to delegate encryption key storage to an external KMIP server (HashiCorp Vault with KV engine + KMIP plugin, or IBM Key Protect).  
**Why:** Without KMIP, the WiredTiger encryption key is a local key file (`/etc/mongodb-encryption-key`) on the VM's root disk, next to the data. A physical disk theft or snapshot clone gives an attacker both the key and the ciphertext. An external KMIP server means the key is never co-located with the data.
**How:** Add to `mongod.conf` (via first-boot compliance env):
```yaml
security:
  enableEncryption: true
  kmip:
    serverName: vault.example.com
    port: 5696
    clientCertificateFile: /etc/mongodb/kmip-client.pem
    serverCAFile: /etc/mongodb/kmip-ca.pem
```

**Maps to:** `mdb-enc-03` (key rotation), `mdb-enc-06` (KMIP configured)  
**Extra component:** HashiCorp Vault Enterprise or IBM Key Protect with KMIP endpoint.

---

### 3.3 RHACS Admission Policy — Block Non-Signed Images

**What:** Add a RHACS `Policy` that prevents any VirtualMachine from booting a `DataVolume` sourced from an image that lacks a valid cosign signature from your build pipeline.  
**Why:** Anyone with access to the registry or namespace could substitute a malicious image. Image signing creates a cryptographic chain of custody: only images built by the official pipeline (which runs the STIG scan and FIPS setup) can boot.  
**How:**
1. Sign the bootc OCI image in `build.sh` with `cosign sign --key cosign.key`.
2. Create a RHACS `Policy` of type `image_signature` requiring a valid signature from the build pipeline's public key.
3. Attach the policy to the MongoDB VM namespace with enforcement action `FAIL_DEPLOYMENT`.

**Maps to:** `mdb-virt-02`  
**Extra component:** RHACS Advanced Cluster Security + cosign + your build pipeline signing key.

---

### 3.4 Automatic STIG Re-scan via Compliance Operator

**What:** Deploy an OpenShift Compliance Operator `ScanSettingBinding` targeting the MongoDB VM namespace with the DISA STIG profile, running on a daily schedule.  
**Why:** The STIG scan in the Containerfile runs once at build time. Kernel parameters and runtime state can drift after VM updates or configuration changes. A scheduled scan detects drift and reports it to the Compliance Operator dashboard, which can trigger remediation.  
**How:**
```yaml
apiVersion: compliance.openshift.io/v1alpha1
kind: ScanSettingBinding
metadata:
  name: mongodb-vm-stig
spec:
  profiles:
    - kind: Profile
      apiGroup: compliance.openshift.io/v1alpha1
      name: rhcos4-moderate
  settingsRef:
    kind: ScanSetting
    apiGroup: compliance.openshift.io/v1alpha1
    name: default
```

**Maps to:** `mdb-virt-04` (runtime compliance verification), `mdb-rbac-04`  
**Extra component:** OpenShift Compliance Operator (available from OperatorHub).

---

### 3.5 Audit Log Retention Policy — 90 Days Minimum

**What:** Attach a PersistentVolumeClaim with a lifecycle policy to `/var/log/mongodb` that retains audit logs for at least 90 days before deletion, and forward logs off-VM to a SIEM with its own retention policy.  
**Why:** `mdb-aud-03` is currently not implemented. Without a retention policy, audit logs can be overwritten or deleted, destroying forensic evidence. Regulatory frameworks (SOC 2, PCI-DSS, HIPAA) typically require 90–365 day log retention.  
**How:**
1. Enable `logging.rsyslog.enabled: true` and configure `logging.rsyslog.forwarding` to your SIEM.
2. Deploy a Compliance Operator `ComplianceRemediation` or a custom `CronJob` that rotates and archives `/var/log/mongodb/audit.json` to S3/ODF Object Bucket with a 90-day lifecycle rule.

**Maps to:** `mdb-aud-03` (iscf-gov-01/ai-13)  
**Extra component:** ODF Object Bucket or external S3-compatible storage + rsyslog forwarding.

---

### 3.6 Network Policy — Explicit Replica Set Egress Allowlist

**What:** Replace the current `egress: []` (block all) with an explicit egress rule that allows only RS member-to-member traffic on port 27017 within the namespace, and blocks everything else.  
**Why:** The current empty egress rule technically blocks all outbound connections, including RS member communication. The README notes this works because OVN-Kubernetes allows intra-namespace traffic implicitly — but this behaviour is CNI-specific and not guaranteed across cluster upgrades or CNI changes. Making the RS egress explicit makes the intent auditable and portable.  
**How:** Add an egress rule to `networkpolicy.yaml`:
```yaml
egress:
  - to:
      - podSelector:
          matchLabels:
            app.kubernetes.io/instance: "{{ include "mongodb-vm.fullname" . }}"
    ports:
      - port: 27017
        protocol: TCP
```

**Maps to:** `mdb-net-04` (strengthens existing control)  
**Extra component:** None.

---

### 3.7 Immutable VM Boot via Secure Boot / vTPM

**What:** Enable Secure Boot and a virtual TPM (vTPM) in the `VirtualMachine` spec.  
**Why:** Without Secure Boot, the VM firmware can load any bootloader — including a malicious one injected into the boot partition. vTPM allows sealing the LUKS/dm-crypt keys to the TPM's PCR state, so the keys are released only when the firmware chain matches the expected state.  
**How:** Add to `domain.firmware` in `virtualmachine.yaml`:
```yaml
domain:
  firmware:
    bootloader:
      efi:
        secureBoot: true
  features:
    smm:
      enabled: true
  tpm: {}
```
Note: requires OCP Virt with UEFI firmware support on s390x (check OCP Virt release notes for s390x EFI support status).

**Maps to:** `mdb-virt-01`, `mdb-virt-02` (boot integrity)  
**Extra component:** OCP Virt UEFI firmware for s390x (verify availability in your OCP version).

---

### 3.8 Falco Runtime Threat Detection

**What:** Deploy Falco as a DaemonSet on s390x worker nodes with rules targeting MongoDB-specific threat patterns.  
**Why:** The current controls are preventive (deny) and audit-trail (log). Falco adds **detection** — it alerts in real time when a MongoDB process opens an unexpected file, spawns a shell, or makes a network connection outside the normal pattern.  
**Example rules to add:**
- Alert when `mongod` spawns a child process (shell injection)
- Alert when a file is written outside `/var/lib/mongo`, `/var/log/mongodb`, `/etc/mongod.conf`
- Alert when a network connection from the MongoDB VM process reaches a destination not in the cluster pod CIDR

**Maps to:** No existing control — new detection layer  
**Extra component:** Falco (available from OperatorHub or as a Helm chart). Verify s390x build availability.

---

*Document generated from source code analysis of `securedimage/Containerfile`, `securedimage/scripts/`, `s390x/byop-sample-repo/services/mongodb-vm/v1/chart/templates/`, and `s390x/byop-sample-repo/services/mongodb-vm/v1/chart/values.yaml`.*
