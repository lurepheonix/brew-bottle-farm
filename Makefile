# Makefile — host convenience wrappers around scripts/*.sh
# Source of truth for runnable tasks: `make help`.
# Host-only by default. VM tasks (prefix `vm-`) always go through
# `./scripts/vm.sh exec` as the VM GUI user — never run toolchain.sh/build.sh directly on host.

.PHONY: help list add remove status sync sync-dry patches patches-check publish-dry \
	vm-status vm-toolchain vm-toolchain-check vm-shell orchestrate orchestrate-dry

help:
	@echo "brew-bottle-farm — host tasks (default) + VM tasks (vm-*)"
	@echo ""
	@echo "Explicit list:"
	@echo "  make list              — ./scripts/packages.sh list"
	@echo "  make add PKG=foo       — ./scripts/packages.sh add <PKG>"
	@echo "  make remove PKG=foo    — ./scripts/packages.sh remove <PKG>"
	@echo "  make status            — ./scripts/packages.sh status"
	@echo ""
	@echo "Sync / patches / publish (host):"
	@echo "  make sync              — ./scripts/sync.sh"
	@echo "  make sync-dry          — ./scripts/sync.sh --dry-run"
	@echo "  make patches           — ./scripts/apply-patches.sh"
	@echo "  make patches-check     — ./scripts/apply-patches.sh --check-only"
	@echo "  make publish-dry       — ./scripts/publish.sh --dry-run"
	@echo ""
	@echo "VM (via vm.sh exec, GUI user):"
	@echo "  make vm-status         — ./scripts/vm.sh status"
	@echo "  make vm-toolchain      — provision rust/go/python inside VM"
	@echo "  make vm-toolchain-check — verify VM toolchain pins (--check)"
	@echo "  make vm-shell          — interactive shell inside VM"
	@echo ""
	@echo "Full farm (host glue: sync -> mirror+patches -> VM build -> publish):"
	@echo "  make orchestrate       — ./scripts/orchestrate.sh"
	@echo "  make orchestrate-dry   — ./scripts/orchestrate.sh --dry-run"

list:
	./scripts/packages.sh list

add:
	@test -n "$(PKG)" || (echo "usage: make add PKG=foo" && exit 1)
	./scripts/packages.sh add $(PKG)

remove:
	@test -n "$(PKG)" || (echo "usage: make remove PKG=foo" && exit 1)
	./scripts/packages.sh remove $(PKG)

status:
	./scripts/packages.sh status

sync:
	./scripts/sync.sh

sync-dry:
	./scripts/sync.sh --dry-run

vm-status:
	./scripts/vm.sh status

# Provision inside the VM (NOT on host). Uses auto-detected GUI user
# (/dev/console); override with VM_USER=<name> for headless exec.
vm-toolchain:
	./scripts/vm.sh exec bash /tmp/shared/scripts/toolchain.sh

vm-toolchain-check:
	./scripts/vm.sh exec bash /tmp/shared/scripts/toolchain.sh --check

vm-shell:
	./scripts/vm.sh exec bash

orchestrate:
	./scripts/orchestrate.sh

orchestrate-dry:
	./scripts/orchestrate.sh --dry-run

publish-dry:
	./scripts/publish.sh --dry-run

patches:
	./scripts/apply-patches.sh

patches-check:
	./scripts/apply-patches.sh --check-only
