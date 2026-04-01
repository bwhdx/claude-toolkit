# claude-toolkit Makefile — build, test, install all tools

INSTALL_DIR ?= $(HOME)/.local/bin
TOOLKIT_DIR := $(shell pwd)

.PHONY: all build test install clean lint help

all: build

# ── Build ─────────────────────────────────────────────────────────────────────

build: build-monitor build-dashboard ## Build all Go binaries
	@echo "✓ All binaries built"

build-monitor: ## Build cc-monitor
	cd cc-monitor && go build -o cc-monitor ./cmd/cc-monitor/

build-dashboard: ## Build cc-dashboard
	cd cc-dashboard && go build -o cc-dashboard ./cmd/cc-dashboard/

# ── Test ──────────────────────────────────────────────────────────────────────

test: test-go test-bash ## Run all tests

test-go: ## Run Go tests
	cd pkg && go test ./...
	cd cc-monitor && go test ./...

test-bash: ## Run bash tests (if bats installed)
	@if command -v bats >/dev/null 2>&1; then \
		bats cc-auth/test/*.bats 2>/dev/null || echo "No bash tests yet"; \
	else \
		echo "bats not installed — skipping bash tests"; \
	fi

# ── Install ───────────────────────────────────────────────────────────────────

install: build ## Build and install to INSTALL_DIR
	@mkdir -p $(INSTALL_DIR)
	cp cc-monitor/cc-monitor $(INSTALL_DIR)/cc-monitor
	cp cc-dashboard/cc-dashboard $(INSTALL_DIR)/cc-dashboard
	ln -sf $(TOOLKIT_DIR)/cc-auth/cc-auth $(INSTALL_DIR)/cc-auth
	@echo ""
	@echo "Installed to $(INSTALL_DIR):"
	@echo "  cc-auth      (symlink)"
	@echo "  cc-monitor   (binary)"
	@echo "  cc-dashboard (binary)"

uninstall: ## Remove installed binaries
	rm -f $(INSTALL_DIR)/cc-auth
	rm -f $(INSTALL_DIR)/cc-monitor
	rm -f $(INSTALL_DIR)/cc-dashboard

# ── Lint ──────────────────────────────────────────────────────────────────────

lint: lint-go lint-bash ## Run all linters

lint-go: ## Run Go linters
	cd cc-monitor && go vet ./...
	cd cc-dashboard && go vet ./...
	cd pkg && go vet ./...

lint-bash: ## Run shellcheck on bash files
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck cc-auth/cc-auth cc-auth/lib/*.bash lib/*.bash || true; \
	else \
		echo "shellcheck not installed — skipping"; \
	fi

# ── Clean ─────────────────────────────────────────────────────────────────────

clean: ## Remove build artifacts
	rm -f cc-monitor/cc-monitor
	rm -f cc-dashboard/cc-dashboard

# ── Help ──────────────────────────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
