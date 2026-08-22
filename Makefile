# Pi coding agent on distroless Node 24.
#
#   make build   build the image for this machine's architecture
#   make test    build, then run the integration suite
#   make run     run Pi interactively against the current directory
#   make shell   drop into a shell inside the image (debugging)

ENGINE     ?= podman
REGISTRY   ?= ghcr.io
OWNER      ?= ocramz
NAME       ?= pi-container-distroless-node24
IMAGE      ?= $(REGISTRY)/$(OWNER)/$(NAME)
TAG        ?= dev
REF        := $(IMAGE):$(TAG)

# Single source of truth for the agent version; CI bumps this file, nothing else.
PI_VERSION ?= 0.84.2

ARCH       := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
PLATFORM   ?= linux/$(ARCH)
VCS_REF    := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

BUILD_ARGS := \
	--build-arg PI_VERSION=$(PI_VERSION) \
	--build-arg VCS_REF=$(VCS_REF) \
	--build-arg BUILD_DATE=$(BUILD_DATE)

# Bind-mounted files are owned by the host user while the image runs as uid
# 65532; scripts/user-flags.sh works out the right mapping for this engine. The
# test harness sources the same script, so the two cannot drift apart.
USER_FLAGS := $(shell ENGINE=$(ENGINE) scripts/user-flags.sh)
ifeq ($(ENGINE),podman)
  MOUNT_OPTS := :z
else
  MOUNT_OPTS :=
endif

.PHONY: all build build-multiarch test smoke run shell push size clean help

all: build

## build: build the image for the host architecture
build:
	$(ENGINE) build --platform $(PLATFORM) $(BUILD_ARGS) -t $(REF) .

## build-multiarch: build amd64+arm64 locally under emulation (CI uses native runners)
build-multiarch:
	$(ENGINE) build --platform linux/amd64,linux/arm64 $(BUILD_ARGS) --manifest $(REF) .

## test: build, then run the full integration suite
test: build
	ENGINE=$(ENGINE) IMAGE=$(REF) PI_VERSION=$(PI_VERSION) tests/run.sh

## smoke: the fast subset -- toolchain and CLI only
smoke: build
	ENGINE=$(ENGINE) IMAGE=$(REF) PI_VERSION=$(PI_VERSION) tests/run.sh test_toolchain.sh test_pi_cli.sh

## run: run Pi interactively against the current directory
run:
	$(ENGINE) run --rm -it $(USER_FLAGS) \
		-e ANTHROPIC_API_KEY -e OPENAI_API_KEY -e GEMINI_API_KEY \
		-v "$(CURDIR):/workspace$(MOUNT_OPTS)" \
		-v pi-agent-state:/pi/agent \
		$(REF) $(ARGS)

## shell: drop into a bash shell inside the image
shell:
	$(ENGINE) run --rm -it $(USER_FLAGS) \
		--entrypoint /bin/bash \
		-v "$(CURDIR):/workspace$(MOUNT_OPTS)" \
		$(REF)

## push: push the image to the registry
push:
	$(ENGINE) push $(REF)

## size: report image size and the layers this repo is responsible for
size:
	@echo "total: $$($(ENGINE) image inspect $(REF) --format '{{.Size}}' | awk '{printf "%.0f MB", $$1/1e6}')"
	@$(ENGINE) history --format '{{.Size}}\t{{.CreatedBy}}' $(REF) \
		| awk -F'\t' '$$1!="0B"' | head -5

## clean: remove built images and dangling test state
clean:
	-$(ENGINE) rmi -f $(REF)
	-$(ENGINE) volume rm pi-agent-state

## help: list targets
help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)

# Lets CI read any variable from here rather than duplicating it in YAML,
# e.g. `make -s print-PI_VERSION`.
print-%:
	@echo $($*)
