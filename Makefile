ACT := $(shell command -v act 2>/dev/null || echo $(HOME)/.local/bin/act)
ACT_IMAGE ?= catthehacker/ubuntu:act-latest
ACT_FLAGS := -P ubuntu-latest=$(ACT_IMAGE)

BATS ?= /usr/local/bin/bats
BATS_LIB_PATH ?= /usr/local/lib

INTEGRATION := tests/integration/aws_create_instance_integration.sh
ARGS ?=

.PHONY: ci unittest integration list help

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

ci: ## Run the full GitHub Actions CI in docker via act
	$(ACT) push $(ACT_FLAGS)

unittest: ## Run bats unit tests locally (no docker)
	BATS_LIB_PATH=$(BATS_LIB_PATH) $(BATS) -r --print-output-on-failure tests/unit/

integration: ## Run REAL-AWS integration tests (costs money)
	$(INTEGRATION) $(ARGS)

list: ## List CI jobs act would run
	$(ACT) $(ACT_FLAGS) -l
