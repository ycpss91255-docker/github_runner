SHELL := /bin/bash

SCRIPTS := init.sh add-runner.sh remove-runner.sh status.sh update.sh lib/common.sh

.PHONY: lint test check help

help:
	@echo "targets:"
	@echo "  lint   -- shellcheck on all scripts"
	@echo "  test   -- bats smoke tests"
	@echo "  check  -- lint + test"

lint:
	shellcheck -x $(SCRIPTS)

test:
	bats test/smoke/

check: lint test
