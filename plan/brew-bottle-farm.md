# Plan — brew-bottle-farm

Farm tooling for Intel Sequoia bottles; public output is the `homebrew-intel` tap.
Stack: `docs/stack.md`. Architecture: `docs/architecture.md`. Tasks: `Makefile` (`make help`).
No GitHub Actions CI (local-only farm; GitHub used for Releases hosting only).

## Features (all milestones)

- Explicit-list mgmt: `packages.sh` validated add/remove/edit/sync-from-brew/status.
- Dep resolve: `sync.sh` explicit ∪ `--include-build` deps, external filter, `pkgVersion`+dep-set+`core_sha` diff, toposorted `build-queue.txt` + `packages.lock.json`.
- External toolchains: `toolchain.sh` rustup/go-tarball/asdf-python, single-pin, `toolchain.env`.
- Patch stack B1: `patches/series`, single-pin header check, fail-closed `.rej`.
- Reused VM: `vm.sh` Parallels helpers, `clean` + `toolchain-ready` snapshots, `tar+base64` TCC bypass.
- Publish: per-formula Releases + `brew bottle --merge`, `git commit`.
- One-shot: `orchestrate.sh` sync → mirror+patches → VM toolchain → VM build → linkage check → publish.

## M0 — Docs baseline (this change)

- [x] README rewrite: two-repo model (`brew-bottle-farm` + `homebrew-intel`), prereqs, host vs VM split, env table, troubleshooting.
- [x] `AGENTS.md` operational contract (points to `docs/`, `plan/`).
- [x] `docs/stack.md`, `docs/architecture.md`.
- [x] `Makefile` host/`vm-*` split; `make help` source of truth; drop confusing bare `toolchain` target.
- [x] Remove `.github/workflows/` (no Actions CI per owner decision).
- [x] Rename markers `brew-intel-tap` → `brew-bottle-farm` in `build.sh` grep + `publish.sh` notes + example patch.
- Done when: `make sync-dry`, `make patches-check`, `make publish-dry`, `make vm-status --help` paths match docs.

## M1 — Local validation hardening

- [ ] `make help` coverage test: every target runs `--help`/`--dry-run` without side effects.
- [ ] `packages.sh status` + `sync.sh --dry-run` green on `hello` fixture; lock `core_sha` refresh path tested (`--force`).
- [ ] `apply-patches.sh --check-only` green with example `ripgrep` patch enabled/disabled; `.rej` fail-closed demonstrated.
- Done when: fresh checkout passes the Verification block in README with no VM running.

## M2 — Farm hardening (needs VM)

- [ ] `build.sh` resume: partial `bottles/` reuse, per-formula `/tmp/build-*.log` retention, `FAILED` list exit code.
- [ ] Linkage gate: `brew linkage --test` + `otool -L` leak check for external `rust/go/python` paths inside VM; block publish on failure.
- [ ] `brew cleanup` between formulae; disk guard (`df` check, 80GB assumption validated).
- [ ] Real bottle end-to-end: `hello` → Releases (dry-run + real) → `brew install <user>/intel/hello` from tap.
- Done when: `make orchestrate` builds `hello` unattended after `make vm-toolchain`.

## M3 — Multi-tag (Tahoe later)

- [ ] Clone VM `brew-tahoe`; `TAG=tahoe make orchestrate` merges second `sha256 tahoe:` line without clobbering `sequoia`.
- [ ] `packages.lock.json` per-tag queue (`tag` field already exists; verify mixed-tag lock handling).
- [ ] Tap README in `homebrew-intel` documents both tags + sunset note.
- Done when: one formula carries both `sequoia` and `tahoe` bottle blocks.

## Backlog (not v1)

- `shellcheck` + `shfmt -d` clean for all `scripts/*.sh` (deferred per owner; document versions in `docs/stack.md` when adopted).
- Full-core builds (8588 formulae infeasible; 300 bottles ~3GB/30-50h sequential).
- Linuxbrew/Docker migration path for post-Sep-2027.
- Bottle attestation for custom `root_url` (upstream `attestation.rb:231` skips ghcr).
- Optional `stg` local patch workflow automation.
- Taskfile migration (rejected for now — see `docs/architecture.md` host/VM split; revisit only if `make` becomes insufficient).
