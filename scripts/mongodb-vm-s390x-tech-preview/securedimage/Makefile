# =============================================================================
# Makefile — securedimage bootc build pipeline
# =============================================================================
#
# Branch: bootc-approach
# Toolchain: podman build (Containerfile) → bootc-image-builder (BIB) → qcow2
# Compliance: DISA STIG RHEL 9 (profile_stig) + FIPS 140-3
#
# All build targets run ON lpar3 (b39-cp4d3) as root.
# rsync-to-lpar3, sync-*, lint, helm-check run locally.
#
# ── Version management ────────────────────────────────────────────────────────
#   The canonical version lives in VERSION (one line: MAJOR.MINOR.PATCH).
#   IMAGE_TAG is read from VERSION automatically — never hardcoded in this file
#   or in the Containerfile ARG default.
#
#   AUTO-INCREMENT (default behaviour):
#     Every invocation of build-image, build, push, or push-oci automatically
#     increments the patch digit in VERSION before calling build.sh.
#     Example: VERSION contains "8.3.11" → build produces "8.3.12" → VERSION
#     is updated to "8.3.12".  The incremented value is passed to the
#     Containerfile via --build-arg IMAGE_TAG=<new-ver> by build.sh.
#     build.sh performs the actual patch-increment and VERSION file write.
#
#   MANUAL OVERRIDE (use sparingly):
#     make build IMAGE_TAG=8.4.0   — one-off override; does NOT write VERSION
#     make version-bump VERSION_NEW=8.4.0   — sets VERSION to an explicit value
#
#   The Containerfile ARG IMAGE_TAG default is "0.0.0" as a sentinel so that
#   any build NOT using --build-arg is immediately visible in Quay inspection.
#
# ── Step-by-step build (run ON lpar3 as root, in order) ──────────────────────
#   make build-check      Step 1 — validate prerequisites only (dry-check)
#   make build-image      Step 2 — podman build Containerfile → OCI image
#                                  (auto-increments VERSION patch on every run)
#   make build-qcow2      Step 3 — BIB converts OCI image → qcow2
#   ── or run all three at once ──
#   make build            Steps 1 + 2 + 3 (full pipeline, auto-increments)
#
# ── Deploy (run ON lpar3 as root) ─────────────────────────────────────────────
#   make push             build + push BOTH ContainerDisk AND OCI image  ← DEFAULT
#                         REGISTRY=quay.io/yourorg make push
#   make push-oci         push the raw bootc OCI image (enables Quay Clair CVE scan)
#   make push-pvc         upload qcow2 to OCP as a CDI DataVolume PVC  ← LOCAL TEST only
#                         (requires oc + virtctl; qcow2 must already be built)
#
# ── One-time setup ────────────────────────────────────────────────────────────
#   make setup            Bootstrap lpar3 (podman + pull BIB)
#
# ── Local targets ─────────────────────────────────────────────────────────────
#   make rsync-to-lpar3   Sync securedimage/ to lpar3 via rsync
#   make sync-check       Diff securedimage/scripts/ vs image-scripts/
#   make sync-from-chart  Copy image-scripts/ → securedimage/scripts/
#   make sync-from-image  Copy securedimage/scripts/ → image-scripts/
#   make lint             shellcheck all .sh files
#   make helm-check       helm template dry-run against the chart
#   make clean            Remove OUTPUT_DIR/qcow2
#   make version-show     Print the current IMAGE_TAG from VERSION
#   make version-bump     Manually set VERSION to VERSION_NEW=x.y.z
#
# ── Variables (override on command line) ──────────────────────────────────────
#   IMAGE_TAG           read from VERSION file (e.g. 8.3.10); auto-incremented
#                       on each build-image / build / push / push-oci invocation
#   REGISTRY            required for ContainerDisk push (e.g. quay.io/yourorg)
#   REGISTRY_NAMESPACE  byop
#   OUTPUT_DIR          /data/securedimage/output
# =============================================================================

.DEFAULT_GOAL := help

# ── Version: read from VERSION file, allow command-line override ──────────────
# $(file < VERSION) reads the file contents; strip strips trailing newlines.
# IMAGE_TAG is the version as it exists in VERSION RIGHT NOW (before any build).
# build.sh increments the patch digit and writes the new value back to VERSION
# before calling podman build, so the built image always carries a fresh number.
_VERSION_FILE := $(strip $(file < $(dir $(realpath $(firstword $(MAKEFILE_LIST))))VERSION))
IMAGE_TAG           ?= $(_VERSION_FILE)

REGISTRY            ?=
REGISTRY_NAMESPACE  ?= byop
OUTPUT_DIR          ?= /data/securedimage/output

SHELL := /bin/bash

SCRIPT_DIR   := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
CHART_DIR    := $(SCRIPT_DIR)/../s390x/byop-sample-repo/services/mongodb-vm/v1/chart

SSH_CONFIG   ?= $(HOME)/.genericremoteconnect-ssh-config
LPAR3_HOST   ?= lpar3
LPAR3_PATH   ?= /home/cp4d/securedimage

# =============================================================================
# Help
# =============================================================================
.PHONY: help
help:
	@echo ""
	@echo "  securedimage — bootc image pipeline (Containerfile + BIB → qcow2)"
	@echo "  Compliance  : DISA STIG RHEL 9 (profile_stig) + FIPS 140-3"
	@echo ""
	@echo "  ── Step-by-step build (run ON lpar3 as root, in order) ──────────"
	@echo "    make build-check   Step 1 — validate prerequisites"
	@echo "    make build-image   Step 2 — podman build → OCI image (~30-60 min)"
	@echo "                                AUTO-INCREMENTS VERSION patch digit"
	@echo "    make build-qcow2   Step 3 — BIB → qcow2 (~10-20 min)"
	@echo "    ── or all at once ──"
	@echo "    make build         Steps 1 + 2 + 3 (auto-increments VERSION)"
	@echo ""
	@echo "  ── Deploy (run ON lpar3 as root) ────────────────────────────────"
	@echo "    make push REGISTRY=quay.io/yourorg"
	@echo "               DEFAULT — build + push ContainerDisk AND OCI image"
	@echo "               ContainerDisk: <registry>/<ns>/mongodb-ea-bootc-containerdisk:<tag>-s390x"
	@echo "               OCI image:     <registry>/<ns>/mongodb-ea-bootc:<tag>-s390x"
	@echo "               NOTE: OCI image is the Quay Clair scannable artifact."
	@echo ""
	@echo "    make push-oci REGISTRY=quay.io/yourorg"
	@echo "               Push ONLY the raw bootc OCI image (enables Quay CVE scan)"
	@echo ""
	@echo "    make push-pvc    ← LOCAL TEST only"
	@echo "               Upload qcow2 to OCP as CDI DataVolume PVC"
	@echo "               Requires: oc + virtctl on PATH, logged in to cluster"
	@echo "               PVC:   mongodb-ea-disk-<tag>  in NAMESPACE=mongodb-vm-test"
	@echo ""
	@echo "  ── One-time setup ───────────────────────────────────────────────"
	@echo "    make setup         Bootstrap lpar3 (podman + pull BIB)"
	@echo ""
	@echo "  ── Local ────────────────────────────────────────────────────────"
	@echo "    make rsync-to-lpar3   Sync repo to lpar3"
	@echo "    make sync-check       Diff scripts/ vs image-scripts/"
	@echo "    make lint             shellcheck all .sh files"
	@echo "    make helm-check       helm template dry-run"
	@echo "    make clean            Remove $(OUTPUT_DIR)/qcow2"
	@echo ""
	@echo "  ── Version ──────────────────────────────────────────────────────"
	@echo "    make version-show                    Print current version (from VERSION)"
	@echo "    make version-bump VERSION_NEW=x.y.z  Set VERSION to an explicit value"
	@echo "                                         (use sparingly; prefer auto-increment)"
	@echo ""
	@echo "  Variables: IMAGE_TAG=$(IMAGE_TAG)  OUTPUT_DIR=$(OUTPUT_DIR)"
	@echo "             REGISTRY=$(REGISTRY)  REGISTRY_NAMESPACE=$(REGISTRY_NAMESPACE)"
	@echo ""

# =============================================================================
# Remote sync  (run locally)
# =============================================================================
.PHONY: rsync-to-lpar3
rsync-to-lpar3:
	@echo "[make] Syncing securedimage/ → $(LPAR3_HOST):$(LPAR3_PATH) ..."
	rsync -av --delete \
	  -e "ssh -F $(SSH_CONFIG)" \
	  "$(SCRIPT_DIR)/" \
	  "$(LPAR3_HOST):$(LPAR3_PATH)/"
	@echo "[make] Sync complete."

# =============================================================================
# Version management  (run locally)
# =============================================================================
.PHONY: version-show
version-show:
	@echo "$(IMAGE_TAG)"

# version-bump: manually set VERSION to an explicit value.
# Use this only when you need a non-sequential jump (e.g. a new minor release).
# Normal builds auto-increment the patch digit via build.sh — do not use
# version-bump for routine builds.
#
# NOTE: The Containerfile no longer contains a hardcoded ARG IMAGE_TAG default
# with a real version number. version-bump therefore only updates VERSION.
# The next `make build-image` will read the new value from VERSION, increment
# the patch digit, and pass the resolved version to the Containerfile via
# --build-arg IMAGE_TAG=<ver>.
.PHONY: version-bump
version-bump:
	@if [ -z "$(VERSION_NEW)" ]; then \
	  echo "[make] ERROR: VERSION_NEW is required. Example:"; \
	  echo "  make version-bump VERSION_NEW=8.4.0"; \
	  exit 1; \
	fi
	@echo "$(VERSION_NEW)" > "$(SCRIPT_DIR)/VERSION"
	@echo "[make] ✓ Version set → $(VERSION_NEW)"
	@echo "[make]   VERSION file : $(SCRIPT_DIR)/VERSION"
	@echo "[make]   The next 'make build-image' will auto-increment to the next patch."
	@echo "[make]   To commit: git add VERSION && git commit -m 'chore: set version to $(VERSION_NEW)'"

# =============================================================================
# Setup  (run on lpar3 — once)
# =============================================================================
.PHONY: setup
setup:
	@echo "[make] Running one-time lpar3 setup (podman + BIB) ..."
	@chmod +x "$(SCRIPT_DIR)/setup-lpar3.sh"
	OUTPUT_DIR="$(OUTPUT_DIR)" \
	  "$(SCRIPT_DIR)/setup-lpar3.sh"

# =============================================================================
# Build steps  (run on lpar3 as root)
# =============================================================================

# -----------------------------------------------------------------------------
# Step 1 — validate prerequisites
# -----------------------------------------------------------------------------
# Checks: root, s390x arch, podman, /dev/kvm, registry.redhat.io auth,
#         BIB image present, Containerfile COPY sources present, disk space ≥10 GiB.
# Safe to run at any time — makes no changes to the system.
.PHONY: build-check
build-check:
	@echo "[make] Step 1: Validating prerequisites ..."
	@chmod +x "$(SCRIPT_DIR)/build.sh"
	IMAGE_TAG="$(IMAGE_TAG)" \
	OUTPUT_DIR="$(OUTPUT_DIR)" \
	BUILD_STEP=check \
	  "$(SCRIPT_DIR)/build.sh"

# -----------------------------------------------------------------------------
# Step 2 — podman build: Containerfile → OCI container image
# -----------------------------------------------------------------------------
# Runs: podman build --platform linux/s390x → localhost/mongodb-ea-bootc:<tag>
# Applies inside the image:
#   • DISA STIG RHEL 9 (oscap --remediate profile_stig)
#   • FIPS 140-3 (fips-mode-setup + update-crypto-policies FIPS)
# This is the long step (~30-60 min depending on network + OSCAP remediation).
# Requires: build-check to have passed first.
# Re-run with SKIP_BUILD=true to reuse a cached image and jump straight to step 3.
.PHONY: build-image
build-image:
	@echo "[make] Step 2: podman build → OCI image (DISA STIG + FIPS 140-3) ..."
	@chmod +x "$(SCRIPT_DIR)/build.sh"
	IMAGE_TAG="$(IMAGE_TAG)" \
	OUTPUT_DIR="$(OUTPUT_DIR)" \
	BUILD_STEP=image \
	  "$(SCRIPT_DIR)/build.sh"

# -----------------------------------------------------------------------------
# Step 3 — bootc-image-builder: OCI image → qcow2
# -----------------------------------------------------------------------------
# Runs BIB container against the locally built OCI image.
# Produces: OUTPUT_DIR/qcow2/rhel9-mongodb-ea-<IMAGE_TAG>-s390x.qcow2
# Requires: build-image to have completed (OCI image must exist in podman storage).
# Skips the podman build by setting SKIP_BUILD=true internally.
.PHONY: build-qcow2
build-qcow2:
	@echo "[make] Step 3: BIB → qcow2 ..."
	@chmod +x "$(SCRIPT_DIR)/build.sh"
	IMAGE_TAG="$(IMAGE_TAG)" \
	OUTPUT_DIR="$(OUTPUT_DIR)" \
	BUILD_STEP=qcow2 \
	  "$(SCRIPT_DIR)/build.sh"

# -----------------------------------------------------------------------------
# build — all three steps at once (convenience shortcut)
# -----------------------------------------------------------------------------
.PHONY: build
build: build-check build-image build-qcow2
	@echo ""
	@echo "[make] ✓ Build complete: $(OUTPUT_DIR)/qcow2/rhel9-mongodb-ea-$(IMAGE_TAG)-s390x.qcow2"

# =============================================================================
# Push targets  (run on lpar3 as root)
# =============================================================================

# -----------------------------------------------------------------------------
# push — ContainerDisk  (DEFAULT deploy path)
# -----------------------------------------------------------------------------
# Wraps the qcow2 in a scratch OCI image and pushes it to the registry.
# OCP Virt / CDI mounts it directly as a VM disk — no PVC upload needed.
# The ContainerDisk (FROM scratch + blob) has NO RPM DB, so Quay will not
# produce a CVE scan for it. Use push-oci if you need CVE scanning.
#
# Produces:
#   <registry>/<ns>/mongodb-ea-bootc-containerdisk:<IMAGE_TAG>-s390x  (ContainerDisk)
#   <registry>/<ns>/mongodb-ea-bootc:<IMAGE_TAG>-s390x                (OCI build image)
# Requires: REGISTRY to be set.
# Example:  make push REGISTRY=quay.io/yourorg
.PHONY: push
push:
	@if [ -z "$(REGISTRY)" ]; then \
	  echo "[make] ERROR: REGISTRY is required."; \
	  echo "  Usage: make push REGISTRY=quay.io/yourorg"; \
	  exit 1; \
	fi
	@echo "[make] Building + pushing ContainerDisk AND OCI image ..."
	@echo "[make]   ContainerDisk : $(REGISTRY)/$(REGISTRY_NAMESPACE)/mongodb-ea-bootc-containerdisk:$(IMAGE_TAG)-s390x"
	@echo "[make]   OCI image     : $(REGISTRY)/$(REGISTRY_NAMESPACE)/mongodb-ea-bootc:$(IMAGE_TAG)-s390x"
	@chmod +x "$(SCRIPT_DIR)/build.sh"
	IMAGE_TAG="$(IMAGE_TAG)" \
	OUTPUT_DIR="$(OUTPUT_DIR)" \
	PUSH_CONTAINERDISK=true \
	PUSH_OCI=true \
	PUSH_PVC=false \
	REGISTRY="$(REGISTRY)" \
	REGISTRY_NAMESPACE="$(REGISTRY_NAMESPACE)" \
	  "$(SCRIPT_DIR)/build.sh"

# -----------------------------------------------------------------------------
# push-oci — push the raw bootc OCI build image  (enables Quay CVE scanning)
# -----------------------------------------------------------------------------
# Pushes localhost/mongodb-ea-bootc:<tag> to the registry under the name
# mongodb-ea-bootc:<tag>-s390x.  This image contains the full RPM DB and is
# the only image Quay / Clair can scan for CVEs.
#
# Produces: <registry>/<ns>/mongodb-ea-bootc:<IMAGE_TAG>-s390x
# Requires: REGISTRY to be set.
# Example:  make push-oci REGISTRY=quay.io/yourorg
.PHONY: push-oci
push-oci:
	@if [ -z "$(REGISTRY)" ]; then \
	  echo "[make] ERROR: REGISTRY is required."; \
	  echo "  Usage: make push-oci REGISTRY=quay.io/yourorg"; \
	  exit 1; \
	fi
	@echo "[make] Building OCI image + pushing to registry ..."
	@echo "[make]   Tag: $(REGISTRY)/$(REGISTRY_NAMESPACE)/mongodb-ea-bootc:$(IMAGE_TAG)-s390x"
	@chmod +x "$(SCRIPT_DIR)/build.sh"
	IMAGE_TAG="$(IMAGE_TAG)" \
	OUTPUT_DIR="$(OUTPUT_DIR)" \
	PUSH_CONTAINERDISK=false \
	PUSH_OCI=true \
	REGISTRY="$(REGISTRY)" \
	REGISTRY_NAMESPACE="$(REGISTRY_NAMESPACE)" \
	BUILD_STEP=image \
	  "$(SCRIPT_DIR)/build.sh"

# -----------------------------------------------------------------------------
# push-pvc — upload qcow2 to OCP as a CDI DataVolume PVC
# -----------------------------------------------------------------------------
# Calls upload.sh to stream the qcow2 directly to an OCP cluster via virtctl.
# Requires: oc + virtctl on PATH, logged in to the target cluster.
# The build must have already run (qcow2 must exist in OUTPUT_DIR/qcow2/).
# Skips the podman build and BIB steps (SKIP_BUILD=true, BUILD_STEP=qcow2).
#
# PVC name defaults to mongodb-ea-disk-<IMAGE_TAG> (versioned, auto).
# Override: make push-pvc PVC_NAME=mongodb-ea-disk NAMESPACE=my-ns
#
# Environment overrides passed to upload.sh:
#   NAMESPACE, PVC_NAME, DISK_SIZE, STORAGE_CLASS, UPLOAD_PROXY_URL
.PHONY: push-pvc
push-pvc:
	@echo "[make] Uploading qcow2 to OCP PVC via CDI / virtctl ..."
	@echo "[make]   PVC: mongodb-ea-disk-$(IMAGE_TAG) (default)"
	@chmod +x "$(SCRIPT_DIR)/build.sh"
	IMAGE_TAG="$(IMAGE_TAG)" \
	OUTPUT_DIR="$(OUTPUT_DIR)" \
	PUSH_CONTAINERDISK=false \
	PUSH_OCI=false \
	PUSH_PVC=true \
	SKIP_BUILD=true \
	BUILD_STEP=qcow2 \
	  "$(SCRIPT_DIR)/build.sh"

# -----------------------------------------------------------------------------
# push-all — ContainerDisk + OCI push + PVC upload (all three)
# -----------------------------------------------------------------------------
# Runs the full build pipeline and triggers all three push paths.
# Requires: REGISTRY to be set, oc + virtctl on PATH, logged in to cluster.
# Example:  make push-all REGISTRY=quay.io/yourorg
.PHONY: push-all
push-all:
	@if [ -z "$(REGISTRY)" ]; then \
	  echo "[make] ERROR: REGISTRY is required."; \
	  echo "  Usage: make push-all REGISTRY=quay.io/yourorg"; \
	  exit 1; \
	fi
	@echo "[make] Building + pushing ContainerDisk + OCI + uploading PVC ..."
	@chmod +x "$(SCRIPT_DIR)/build.sh"
	IMAGE_TAG="$(IMAGE_TAG)" \
	OUTPUT_DIR="$(OUTPUT_DIR)" \
	PUSH_CONTAINERDISK=true \
	PUSH_OCI=true \
	PUSH_PVC=true \
	REGISTRY="$(REGISTRY)" \
	REGISTRY_NAMESPACE="$(REGISTRY_NAMESPACE)" \
	  "$(SCRIPT_DIR)/build.sh"

# =============================================================================
# Script sync  (run locally)
# =============================================================================
.PHONY: sync-check
sync-check:
	@chmod +x "$(SCRIPT_DIR)/sync-scripts.sh"
	"$(SCRIPT_DIR)/sync-scripts.sh" check

.PHONY: sync-from-chart
sync-from-chart:
	@chmod +x "$(SCRIPT_DIR)/sync-scripts.sh"
	"$(SCRIPT_DIR)/sync-scripts.sh" from-chart

.PHONY: sync-from-image
sync-from-image:
	@chmod +x "$(SCRIPT_DIR)/sync-scripts.sh"
	"$(SCRIPT_DIR)/sync-scripts.sh" from-image

# =============================================================================
# Lint  (run locally)
# =============================================================================
.PHONY: lint
lint:
	@echo "[make] Running shellcheck ..."
	@if ! command -v shellcheck &>/dev/null; then \
	  echo "  shellcheck not installed: brew install shellcheck"; exit 1; \
	fi
	@EXIT_CODE=0; \
	find "$(SCRIPT_DIR)" -name "*.sh" | sort | while read -r f; do \
	  echo "  $$f"; \
	  shellcheck -S warning "$$f" || EXIT_CODE=1; \
	done; \
	exit $$EXIT_CODE

# =============================================================================
# Helm dry-run  (run locally)
# =============================================================================
.PHONY: helm-check
helm-check:
	@echo "[make] Helm template dry-run ..."
	@if ! command -v helm &>/dev/null; then \
	  echo "  helm not installed: https://helm.sh/docs/intro/install/"; exit 1; \
	fi
	helm template test-render "$(CHART_DIR)" \
	  --set diskImage.sourceContainerDisk="test-registry/byop/mongodb-ea-bootc:$(IMAGE_TAG)-s390x" \
	  --set diskImage.diskSizeGi=25 \
	  --set mongodb.rootPassword=testpass \
	  --set mongodb.databaseName=myapp \
	  --set mongodb.databasePassword=apppass \
	  --set mongodb.vmRootPassword=vmpass \
	  2>&1 | grep "^kind:" | sort | uniq -c | sort -rn
	@echo ""
	@echo "[make] HA + compliance dry-run:"
	helm template test-render-ha "$(CHART_DIR)" \
	  --set diskImage.sourceContainerDisk="test-registry/byop/mongodb-ea-bootc:$(IMAGE_TAG)-s390x" \
	  --set diskImage.diskSizeGi=25 \
	  --set mongodb.rootPassword=testpass \
	  --set mongodb.databaseName=myapp \
	  --set mongodb.databasePassword=apppass \
	  --set mongodb.vmRootPassword=vmpass \
	  --set ha.enabled=true \
	  --set ha.replicaCount=3 \
	  --set compliance.enableEncryption=true \
	  --set compliance.auditLog.enabled=true \
	  2>&1 | grep "^kind:" | sort | uniq -c | sort -rn
	@echo "[make] helm-check complete"

# =============================================================================
# Clean
# =============================================================================
.PHONY: clean
clean:
	@echo "[make] Removing $(OUTPUT_DIR)/qcow2 ..."
	rm -rf "$(OUTPUT_DIR)/qcow2"
	@echo "[make] Done."
