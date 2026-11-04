# Secured MongoDB bootc image for s390x

Builds a hardened MongoDB Enterprise 8.x image on RHEL 9 bootc for IBM Z (s390x) from a `Containerfile`, then converts it to a bootable `qcow2` disk with bootc-image-builder.

## Prerequisites

- An **s390x** RHEL 9 VM (`uname -m` must print `s390x`) with an active RHEL subscription.
- Root access (`sudo`): the build uses rootful podman.
- `/dev/kvm` available in the VM.
- Packages: `make`, `git`, `podman`, `skopeo`, `bootc`, `gawk`. `sudo make setup` installs the missing ones.
- A Red Hat registry login: `sudo podman login registry.redhat.io`
- Outbound HTTPS access to `registry.redhat.io`, `repo.mongodb.com` and `pgp.mongodb.com`. To use a mirror instead, set `MONGODB_REPO_BASEURL` and `MONGODB_GPG_KEY_URL` (see `config.env.example`).
- At least 10 GiB free disk space in the output directory. 30 GiB or more is recommended.

## Build steps

```bash
# 1. Clone and enter the repository
git clone <repository-url> securedimage
cd securedimage

# 2. (Optional) override defaults such as IMAGE_NAME, IMAGE_TAG, BASE_IMAGE, OUTPUT_DIR
cp config.env.example config.env
vi config.env

# 3. One-time host preparation (installs tools, pulls bootc-image-builder)
sudo make setup

# 4. Build the OCI image and convert it to qcow2
sudo make build
```

Individual steps: `sudo make check`, `sudo make build-image`, `sudo make build-qcow2`.
Settings can also be passed on the command line, for example `sudo make build IMAGE_TAG=1.2.0`.

### Make targets

| Target | Description |
|---|---|
| `help` | Show targets and common variables |
| `setup` | One-time host setup: install podman/skopeo/bootc, pull bootc-image-builder |
| `check` | Validate prerequisites (root, s390x, podman, `/dev/kvm`, registry login, disk space) |
| `build-image` | Build the OCI image from the `Containerfile` (longest step) |
| `build-qcow2` | Convert the local OCI image to a qcow2 disk image |
| `build` | Run `check`, `build-image` and `build-qcow2` |
| `push` | Optional: push the qcow2 (ContainerDisk) and OCI image to `REGISTRY` |
| `verify` | Static checks that run on any host (`bash -n`, shellcheck, Containerfile sources) |
| `clean` | Remove qcow2 files and logs from the output directory |

### Output

- Disk image: `output/qcow2/mongodb-bootc-<tag>-s390x.qcow2` (`<tag>` defaults to the contents of `VERSION`)
- Local container image: `localhost/mongodb-bootc:<tag>`
- Build log: `output/logs/build-image.log`

Set `OUTPUT_DIR` to write somewhere else.

### Upload (optional)

To publish the results to a container registry:

```bash
# 1. Log in to the target registry (as root — the build runs rootful)
sudo podman login registry.example.com

# 2. Push (requires a completed build)
sudo make push REGISTRY=registry.example.com REGISTRY_NAMESPACE=myorg
```

By default this pushes both artifacts, tagged `<tag>-s390x`:

- ContainerDisk (qcow2 wrapped for KubeVirt/CDI import): `registry.example.com/myorg/mongodb-bootc-containerdisk:<tag>-s390x`
- bootc OCI image: `registry.example.com/myorg/mongodb-bootc:<tag>-s390x`

`REGISTRY` is required. `REGISTRY_NAMESPACE`, `PUSH_CONTAINERDISK` / `PUSH_OCI`
(set `false` to skip one of the two artifacts), and `PUSH_TLS_VERIFY`
(set `false` for self-signed registry certificates) are optional — see
`config.env.example`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `podman`, `skopeo`, `bootc` or `make` not found | Run `sudo make setup`, or `sudo dnf install -y podman skopeo bootc make gawk`. |
| `This build must run on an s390x host` | The build only runs on an s390x host. Check with `uname -m`. |
| `Must run as root` or permission denied | Run with `sudo`, for example `sudo make build`. If `make clean` fails on root-owned files, use `sudo make clean`. |
| `/dev/kvm` missing | Enable nested virtualization / KVM for the VM, then check `ls -l /dev/kvm`. |
| Pull fails: `unauthorized`, `denied` or timeout | Run `sudo podman login registry.redhat.io` (root's credentials are separate from your user's). Check DNS, proxy and firewall access to `registry.redhat.io`. |
| `podman push` fails: `unauthorized` or TLS errors | Run `sudo podman login <registry>` first (the build runs as root, so root's credentials are used). For self-signed registry certificates set `PUSH_TLS_VERIFY=false`. |
| MongoDB package or key download fails | Check access to `repo.mongodb.com` and `pgp.mongodb.com`, or set `MONGODB_REPO_BASEURL` and `MONGODB_GPG_KEY_URL` to a mirror. |
| `No space left on device` or the free-space check fails | Free space in `OUTPUT_DIR` and `/var/lib/containers`, run `sudo podman system prune`, or set `OUTPUT_DIR` to a larger filesystem. |
| bootc-image-builder fails with `acquiring lock` errors | Re-run with `PRUNE_STALE=true`. This removes all stopped podman containers and unused volumes on the host. |
| Build failed for another reason | Read `output/logs/build-image.log` (or `$LOG_DIR/build-image.log`). Re-run only the failed step, for example `sudo make build-qcow2`. |
