# Murmur — developer tasks.
#
# SAFETY: the development Mac mini has limited RAM and model-loading tests have
# crashed it. `test` is light-tier only and never sets MURMUR_RUN_HEAVY_TESTS.
# Anything that loads model weights (`bench`, `test-heavy`) refuses to run
# unless you opt in explicitly, and is intended for a CI runner.

MURMUR_DIR := Murmur

.DEFAULT_GOAL := help

.PHONY: help build test test-heavy bench metrics clean

help:
	@echo "Murmur targets:"
	@echo "  make build       Build the app (debug)"
	@echo "  make test        Light-tier tests — safe locally, no model loading"
	@echo "  make metrics     Summarise the local session-metrics log"
	@echo ""
	@echo "  make test-heavy  Model-loading tests   (requires I_HAVE_ENOUGH_RAM=1)"
	@echo "  make bench       Latency/accuracy bench (requires I_HAVE_ENOUGH_RAM=1)"
	@echo ""
	@echo "  test-heavy and bench load multi-GB models. Run them on a CI runner."
	@echo "  Do NOT run them on the development Mac mini — they have crashed it."

build:
	cd $(MURMUR_DIR) && swift build

# Light tier. This is the target CI runs on every PR and the only one that
# should ever be run casually on a dev machine.
test:
	cd $(MURMUR_DIR) && swift test

# Guard shared by every model-loading target. Requires a deliberate opt-in that
# is impossible to trip over by accident or muscle memory.
define REQUIRE_RAM_OPT_IN
	@if [ "$(I_HAVE_ENOUGH_RAM)" != "1" ]; then \
		echo ""; \
		echo "REFUSING TO RUN: this target loads transcription models (multi-GB)."; \
		echo ""; \
		echo "  Model-loading runs have crashed the development Mac mini."; \
		echo "  Run this on a GitHub-hosted CI runner instead:"; \
		echo "    gh workflow run heavy-tests.yml"; \
		echo ""; \
		echo "  If you are certain this machine has the RAM, opt in explicitly:"; \
		echo "    make $@ I_HAVE_ENOUGH_RAM=1"; \
		echo ""; \
		exit 1; \
	fi
endef

test-heavy:
	$(REQUIRE_RAM_OPT_IN)
	cd $(MURMUR_DIR) && MURMUR_RUN_HEAVY_TESTS=1 swift test

# Prints the metric table from docs/plans/2026-07-30-10x-plan.md.
# Loads models — same opt-in guard as test-heavy.
bench:
	$(REQUIRE_RAM_OPT_IN)
	cd $(MURMUR_DIR) && MURMUR_RUN_HEAVY_TESTS=1 swift test --filter Bench

# Read-only summary of the local metrics log. Loads nothing — always safe.
metrics:
	@python3 Scripts/summarise_metrics.py

clean:
	cd $(MURMUR_DIR) && swift package clean
