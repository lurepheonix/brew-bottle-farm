# Makefile — host convenience wrappers around scripts/*.sh
# Source of truth for runnable tasks: `make help`.
# Host-only by default. VM builds go through `./scripts/vm.sh` (SSH transport);
# never run toolchain.sh/build.sh directly on host — except via
# `make orchestrate-local`, the sanctioned host dry path (publish untouched).

.PHONY: help list add remove status sync sync-dry toolchain-updates patches patches-check publish-dry \
	vm-status vm-ssh-setup vm-ssh vm-brew vm-toolchain vm-toolchain-check vm-shell orchestrate orchestrate-dry orchestrate-local farm-toolchain

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
	@echo "  make toolchain-updates — ./scripts/check-toolchain-updates.sh"
	@echo "  make patches           — ./scripts/apply-patches.sh"
	@echo "  make patches-check     — ./scripts/apply-patches.sh --check-only"
	@echo "  make publish-dry       — ./scripts/publish.sh --dry-run"
	@echo ""
	@echo "VM (via vm.sh; SSH transport, prlctl stays for bootstrap/control only):"
	@echo "  make vm-status         — ./scripts/vm.sh status"
	@echo "  make vm-ssh-setup      — one-time SSH bootstrap (keypair, Remote Login, key seeding)"
	@echo "  make vm-ssh            — interactive SSH shell as the VM GUI user"
	@echo "  make vm-brew           — install guest Homebrew (clone, no install.sh)"
	@echo "  make vm-toolchain      — provision rust/go/python inside VM"
	@echo "  make vm-toolchain-check — verify VM toolchain pins (--check)"
	@echo "  make vm-shell          — interactive shell inside VM (SSH)"
	@echo ""
	@echo "Full farm (host glue: sync -> mirror+patches -> build -> publish):"
	@echo "  make orchestrate       — ./scripts/orchestrate.sh (VM build, SSH transport)"
	@echo "  make orchestrate-dry   — ./scripts/orchestrate.sh --dry-run"
	@echo '  make orchestrate-local — ./scripts/orchestrate.sh --local (host dry path, publish untouched)'
	@echo '  make farm-toolchain    — ./scripts/build-farm-toolchain.sh (own fast pipeline)'

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

toolchain-updates:
	./scripts/check-toolchain-updates.sh

vm-status:
	./scripts/vm.sh status

# One-time SSH bootstrap (host keypair, Remote Login, key seeding).
# Requires explicit VM_USER (auto-detect is flaky).
vm-ssh-setup:
	./scripts/vm.sh ssh-setup

# Interactive SSH shell as the VM GUI user.
vm-ssh:
	./scripts/vm.sh ssh

vm-brew:
	./scripts/vm-brew.sh

# Provision inside the VM (NOT on host). Uses auto-detected GUI user
# (/dev/console); override with VM_USER=<name> for headless exec.
vm-toolchain:
	./scripts/vm.sh exec bash /tmp/shared/scripts/toolchain.sh

vm-toolchain-check:
	./scripts/vm.sh exec bash /tmp/shared/scripts/toolchain.sh --check

vm-shell:
	./scripts/vm.sh ssh bash

orchestrate:
	./scripts/orchestrate.sh

orchestrate-dry:
	./scripts/orchestrate.sh --dry-run

orchestrate-local:
	./scripts/orchestrate.sh --local

# Own fast pipeline for the authored farm-toolchain formula (builds + bottles
# from the working tree; no provisioned toolchain needed, publishes nothing).
farm-toolchain:
	./scripts/build-farm-toolchain.sh

publish-dry:
	./scripts/publish.sh --dry-run

patches:
	./scripts/apply-patches.sh

patches-check:
	./scripts/apply-patches.sh --check-only
