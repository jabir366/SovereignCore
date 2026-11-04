# =============================================================================
# Makefile — build the secured MongoDB bootc image (Containerfile -> qcow2)
# =============================================================================
# Run `make help` for the list of targets.
#
# Settings can be given on the command line (make build IMAGE_TAG=1.2.0), in the
# environment, or in config.env (see config.env.example). Command-line values
# are passed on to the scripts automatically.
#
# Build targets need root (rootful podman):  sudo make build
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT_DIR := $(patsubst %/,%,$(dir $(abspath $(firstword $(MAKEFILE_LIST)))))
SHELL_SCRIPTS := $(ROOT_DIR)/build-image.sh $(ROOT_DIR)/setup-host.sh $(ROOT_DIR)/lib/common.sh \
                 $(wildcard $(ROOT_DIR)/scripts/*.sh)

.PHONY: help
help: ## Show this help
	@echo "Usage: make <target> [VAR=value ...]"
	@echo ""
	@echo "Targets:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*## "} {printf "  %-14s %s\n", $$1, $$2}'
	@echo ""
	@echo "Common variables (see config.env.example for all):"
	@echo "  IMAGE_NAME  IMAGE_TAG  BASE_IMAGE  BIB_IMAGE  OUTPUT_DIR"
	@echo "  REGISTRY  REGISTRY_NAMESPACE (push only)"
	@echo ""
	@echo "Build targets need root: sudo make build"

.PHONY: setup
setup: ## One-time host setup: install podman/skopeo/bootc, pull bootc-image-builder
	"$(ROOT_DIR)/setup-host.sh"

.PHONY: check
check: ## Validate prerequisites (root, s390x, podman, /dev/kvm, registry login, disk space)
	"$(ROOT_DIR)/build-image.sh" check

.PHONY: build-image
build-image: ## Build the OCI image from the Containerfile (longest step)
	"$(ROOT_DIR)/build-image.sh" image

.PHONY: build-qcow2
build-qcow2: ## Convert the local OCI image to a qcow2 disk image
	"$(ROOT_DIR)/build-image.sh" qcow2

.PHONY: build
build: ## Run check + build-image + build-qcow2 (full pipeline)
	"$(ROOT_DIR)/build-image.sh" all

.PHONY: push
push: ## Push the qcow2 (ContainerDisk) and OCI image to REGISTRY (requires REGISTRY=...)
	"$(ROOT_DIR)/build-image.sh" push

.PHONY: verify
verify: ## Static checks on any host: bash -n, shellcheck (if installed), Containerfile sources
	@set -e; \
	for f in $(SHELL_SCRIPTS); do bash -n "$$f"; echo "  bash -n OK  $${f#$(ROOT_DIR)/}"; done; \
	if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -x -S warning $(SHELL_SCRIPTS); echo "  shellcheck OK"; \
	else \
	  echo "  shellcheck not installed - skipped (dnf install ShellCheck, or brew install shellcheck)"; \
	fi; \
	if command -v python3 >/dev/null 2>&1; then \
	  python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], "rb").read())' \
	    "$(ROOT_DIR)/scripts/mongo-primary-probe.py" && echo "  python syntax OK  scripts/mongo-primary-probe.py"; \
	else \
	  echo "  python3 not installed - skipped"; \
	fi; \
	grep -E '^COPY ' "$(ROOT_DIR)/Containerfile" | awk '{print $$2}' | while read -r f; do \
	  [ -f "$(ROOT_DIR)/$$f" ] || { echo "  MISSING Containerfile source: $$f"; exit 1; }; \
	done; \
	echo "  Containerfile COPY sources OK"

.PHONY: clean
clean: ## Remove build outputs (qcow2 files and logs in OUTPUT_DIR); may need sudo
	"$(ROOT_DIR)/build-image.sh" clean
