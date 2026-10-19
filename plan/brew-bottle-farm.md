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

- [x] `build.sh` resume: `--resume` skips formulae with complete artifacts in the output dir; per-formula `/tmp/build-*.log` retention, `FAILED` list exit code (verified: back-to-back runs skip).
- [x] Linkage gate: `brew linkage --test` + `otool -L` leak check for external `rust/go/python` paths; block publish on failure (verified: green on VM `fd` and `gh` builds, `farm-toolchain` host build).
- [x] `brew cleanup` between formulae (VM path only — host cache belongs to the user); disk guard (`df` free-space check vs `FARM_MIN_DISK_GB`, default 10GB; VM disk 80GB assumption holds).
- [ ] Real bottle end-to-end: `hello` → Releases (dry-run + real) → `brew install <user>/intel/hello` from tap.
- [x] `sync.sh` records toolchain pins in lock (`toolchain`, `tap_provided`); slot-change auto-queues patched formulae + dependents.
- [x] `toolchain.env` stamp (`TOOLCHAIN_PINLIST`/`TOOLCHAIN_STAMP`); `build.sh` hard-fails on stale toolchain.
- [x] `check-toolchain-updates.sh` (`make toolchain-updates`): conf pins vs brew stables / uv builds / host bootstraps.
- [x] `farm-toolchain` bottled via own fast pipeline (`scripts/build-farm-toolchain.sh`, `make farm-toolchain`; `keg_only`, single-pin formula==conf; host-built 0.1.0 bottled). VM switch to `brew install farm-toolchain` + `provision` still open.
- Done when: `make orchestrate` builds `hello` unattended after `make vm-toolchain`.

## M3 — Multi-tag (Tahoe later)

- [ ] Clone VM `brew-tahoe`; `TAG=tahoe make orchestrate` merges second `sha256 tahoe:` line without clobbering `sequoia`.
- [ ] `packages.lock.json` per-tag queue (`tag` field already exists; verify mixed-tag lock handling).
- [ ] Tap README in `homebrew-intel` documents both tags + sunset note.
- Done when: one formula carries both `sequoia` and `tahoe` bottle blocks.

## SSH transport + decoupling (next workstream)

Background: Sequoia TCC blocks the Parallels shared-folder mount both ways
(guest reads fail, guest writes hang); all transport currently goes through
`prlctl exec` + tar+base64 pipes. Guest→host collection in `orchestrate.sh`
is broken by design (assumes a live bidirectional mount); the `fd` canary
used a hand-rolled reverse base64 pipe instead.

- [x] Phase 1 — SSH transport: `vm.sh ssh-setup` (host keypair `~/.ssh/brew-farm`,
  never in repo; Remote Login via `exec-as-root`, else one-time GUI toggle;
  key seeding via root; `ssh-keyscan` into host `known_hosts`; re-resolve DHCP IP
  each run, prune stale host keys), `rsync-to`/`rsync-from` + real `ssh <cmd>`
  (replacing the password-assuming stubs); `prlctl exec` stays for bootstrap only
  (IP discovery, sshd repair, initial seeding). Migrate `shared-sync` /
  `shared-stage` / bottle+log collection + `orchestrate.sh` collect step to rsync.
  Verify with an `fd` bottle round-trip (stage → build → collect → SHA match).
- [x] Phase 2 — decouple build infra from VM (done; VM stays canonical bottle source): `FARM_TRANSPORT=prlctl|ssh|local`
  dispatch in `vm.sh`/`orchestrate.sh`; all roots via env (`TOOLCHAIN_ENV`,
  `BUILD_DEPS_CONF`, queue/output paths; `/tmp/shared` + `/usr/local` stay defaults).
  Add host-local dry path (`orchestrate --local`: sync → patch → build, publish untouched).
  `toolchain.sh`/`build.sh` location-agnostic via env roots (`BREW_PREFIX`, `VM_GUEST_SHARED`, `SHARED_DIR`, `BUILD_LOG_DIR`, `FARM_TOOLCHAIN_GATE`); hardcoded `/tmp/shared` + `/usr/local` are defaults only.
- [ ] Phase 3 (optional) — host as bottle source: decide whether host-built bottles
  share the `sequoia` tag (15.x covers both); VM stays canonical builder until then.
- Done when: full `orchestrate` runs over SSH transport with no `prlctl` pipe
  in the loop (verified: `orchestrate.sh` uses `run`/`push`/`pull` dispatch; `prlctl`
  only via `status`/`start` control plane), and `--local` completes sync → patch → build on host
  (verified: `make orchestrate-local`, scratch output, publish untouched).

## Package rollout (from host `brew leaves`, Oct 2026)

- [x] Starter (10): `fd ffmpeg fish gh htop imagemagick neovim ripgrep starship wget`
      via `make add PKG=` each (validated); `hello` fixture removed (Oct 2026).
      `gh` is starter-explicit so the host installs the farm bottle from the tap
      (bootstrap: one-off queue → hand-pour first bottle → first publish → managed tap install).
      Resolved 75, queued 75 (4 external build-deps via toolchain.sh: `go` + `rust` +
      `python@3.15` + `ruby`; `go` covered by B1 patch `gh-use-external-go`).
      Expect ~77 resolved, minus externals (`rust` + `python@3.13/3.14/3.15` + `ruby`
      via `ripgrep/starship/fd` build paths and `meson/sphinx-doc/asciidoctor`
      intermediaries — all provided by `toolchain.sh` via uv/asdf, never bottled).
      Intermediaries that runtime-link an interpreter (`meson`, `sphinx-doc`,
      `asciidoctor`) stay unpatched and use core interpreters in the VM.
- [ ] Deferred (22): `eza` (pulls `ghc/cabal-install/pandoc`, heaviest outlier)
      + `automake cloudflared cmake duf dust git-filter-repo go-task httpie
      meson mist-cli nasm p7zip rclone scdoc shfmt smartmontools sphinx-doc
      stgit telnet watchman zoxide` — promote in small batches after starter e2e.
- [ ] Never explicit: `asdf/uv/go/rust/python@*/ruby/node` (external/bootstrap via `toolchain.sh`).
- Done when: `packages.txt` holds the 10, `make sync-dry` green,
  `packages.lock.json` + `build-queue.txt` written.

## Backlog (not v1)

- Package rollout batch 2+: deferred 22 above (`eza` first — needs `ghc` cost check;
  `watchman` pulls `boost/folly`; `cmake/meson/nasm/automake/scdoc` may stay deps-only).

- `shellcheck` + `shfmt -d` clean for all `scripts/*.sh` (deferred per owner; document versions in `docs/stack.md` when adopted).
- Full-core builds (8588 formulae infeasible; 300 bottles ~3GB/30-50h sequential).
- Linuxbrew/Docker migration path for post-Sep-2027.
- Bottle attestation for custom `root_url` (upstream `attestation.rb:231` skips ghcr).
- Optional `stg` local patch workflow automation.
- Taskfile migration (rejected for now — see `docs/architecture.md` host/VM split; revisit only if `make` becomes insufficient).
