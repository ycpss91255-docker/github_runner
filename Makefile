SHELL := /bin/bash

# Aligns with ycpss91255-docker/base: same prebuilt test-tools image
# (alpine + shellcheck + bats + hadolint + bats-{support,assert,mock}).
# Override with TEST_TOOLS_IMAGE=... for local rebuild flows.
TEST_TOOLS_IMAGE ?= ghcr.io/ycpss91255-docker/test-tools:latest

SCRIPTS := init.sh add-runner.sh remove-runner.sh status.sh update.sh lib/common.sh

DOCKER_RUN := docker run --rm -v "$$PWD:/source" -w /source $(TEST_TOOLS_IMAGE)

.PHONY: help pull lint test check lint-host test-host

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

pull: ## Pull the test-tools image used by lint / test
	docker pull $(TEST_TOOLS_IMAGE)

lint: ## ShellCheck inside test-tools container
	$(DOCKER_RUN) shellcheck -x $(SCRIPTS)

test: ## Bats smoke tests inside test-tools container
	$(DOCKER_RUN) bats test/smoke/

check: lint test ## lint + test

lint-host: ## ShellCheck on host (requires shellcheck installed locally)
	shellcheck -x $(SCRIPTS)

test-host: ## Bats on host (requires bats installed locally)
	bats test/smoke/
