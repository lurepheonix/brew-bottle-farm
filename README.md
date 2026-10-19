# brew-bottle-farm

Intel Sequoia bottle farm — builds `homebrew/core` formulae from source inside a
Parallels VM and publishes bottles to GitHub Releases for a public tap.
Dies Sep 2027 when Homebrew drops Intel (Tier Unsupported).

Two repos:

| Repo | Name | Contents | Visibility |
| ---- | ---- | -------- | ---------- |
| This repo (farm tooling) | `brew-bottle-farm` | `scripts/`, `patches/`, `packages.txt`, `build-deps.conf` | private OK |
| Output (tap) | `github.com/<user>/homebrew-intel` | `Formula/*.rb` + Releases bottles | **public** (must be `homebrew-*` for `brew tap user/intel` shortcut) |

Flow: `packages.txt` (explicit) → `sync.sh` (resolve + queue) → `orchestrate.sh`
(mirror + patches → VM build → publish to `homebrew-intel` Releases).

**Host:** Intel macOS (`/usr/local`, `15.7.9-x86_64` verified).
**VM:** Parallels Desktop `brew-sequoia` (8c/16GB/80GB, Sequoia, `/usr/local`).
QEMU not used. Future: Tahoe VM clone (`TAG=tahoe`).

No GitHub Actions CI — everything runs locally (`make ...`, see `Makefile`).
GitHub is only used as bottle hosting (`gh release`, via `publish.sh`).

## Prereqs (host)

```bash
brew install gh gnu-tar          # releases + bottle tarballs
gh auth login
prlctl --version                 # Parallels Desktop 26.4+ verified
brew config                      # must show x86_64 / /usr/local
```

Create the public tap repo once (empty `homebrew-intel`), then point this farm at it:

```bash
git clone github.com/<user>/homebrew-intel ~/homebrew-intel   # output tap
# this repo stays as the farm; Formula/*.rb here are mirrored working copies
```

## Quick Start (host)

```bash
# 1. Manage explicit formulae (validated — must exist in homebrew/core, not cask/disabled)
make add PKG=ffmpeg
make list
make status
# Or import current leaves:
./scripts/packages.sh sync --from-brew

# 2. Preview what would build
make sync-dry

# 3. Full run: sync → VM build → publish
make orchestrate
make orchestrate-dry   # preview only
```

Consumer side:

```bash
brew tap <user>/intel
brew install <user>/intel/ffmpeg  # pulls https://github.com/<user>/homebrew-intel/releases/download/ffmpeg-<ver>/...
```

## VM setup (once, reused)

```bash
./scripts/vm.sh shared-setup
./scripts/vm.sh start   # open Parallels window, finish macOS setup, install Parallels Tools
./scripts/vm.sh shared-sync   # stages toolchain/patches/queue to VM /tmp/shared/ (bypasses Sequoia TCC on /Volumes/SharedFolders/)

# INSIDE the VM's Terminal.app (GUI session required — headless `vm.sh exec` can't
# show dialogs or type your sudo password):
xcode-select --install
# Guest Homebrew is REQUIRED (build.sh runs guest `brew install --build-bottle`;
# without it every build fails). Upstream install.sh refuses Intel, so:
make vm-brew   # clone Homebrew/brew into /usr/local + gh/gnu-tar/libyaml, no sudo password needed
# Manual fallback INSIDE the VM's Terminal.app (only if vm-brew fails):
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install gnu-tar libyaml   # bottle tarballs + ruby-build psych dep (gh stays host-only)
# Verify from host afterwards (export VM_USER=<gui-user> if auto-detect fails):
VM_USER=<gui-user> ./scripts/vm.sh exec brew --version   # must show /usr/local (Intel)

./scripts/vm.sh snapshot clean
make vm-toolchain               # rustup + go + asdf python per build-deps.conf (NOT on host)
./scripts/vm.sh snapshot toolchain-ready   # avoids recompiling python (~15 min) every run
```

`vm.sh exec` runs as the VM GUI user (auto-detected from `/dev/console`;
override `VM_USER=<name>`). Never run `scripts/toolchain.sh` / `scripts/build.sh`
directly on host — they are VM-only (`TOOLCHAIN_ENV=/tmp/shared/toolchain.env`).

## Tasks (`make help` is source of truth)

Host: `list` / `add PKG=` / `remove PKG=` / `status` / `sync` / `sync-dry` /
`patches` / `patches-check` / `publish-dry` / `orchestrate` / `orchestrate-dry`.
VM (via `vm.sh exec`): `vm-status` / `vm-toolchain` / `vm-toolchain-check` / `vm-shell`.

Scripts:

* `scripts/packages.sh` — manual `packages.txt` mgmt with strict validation
  (`brew info --json=v2 --formula`, rejects casks/disabled, checks `brew deps`).
* `scripts/sync.sh` — `resolved = explicit ∪ deps (--include-build)`, filters external
  build-deps per `build-deps.conf`, diffs vs `packages.lock.json`, writes toposorted
  `build-queue.txt`. `--dry-run`, `--force`, `--tag`.
* `scripts/toolchain.sh` — **VM-only**: provisions rustup, go tarball,
  `uv`/`asdf` + python slots, ruby, node per `build-deps.conf` (single-pin
  with `.tool-versions`), writes `toolchain.env`.
* `scripts/apply-patches.sh` — applies `patches/series` (`patch -p1 --forward`) to
  mirrored `Formula/*.rb`, fail-closed on `.rej`, checks single-pin header.
* `scripts/build.sh` — **VM-only**: `brew install --build-bottle` +
  `brew bottle --json --root-url=...` per formula into `./bottles`.
* `scripts/publish.sh` — host: `gh release create <formula>-<version>` + `brew bottle
  --merge --write --no-commit` into `Formula/*.rb`, `git commit`. `--dry-run`.
* `scripts/vm.sh` — `prlctl` helpers (`status/start/stop/suspend/exec/shared-sync/...`).
  `shared-sync` stages via `tar+base64` to `/tmp/shared/` (Sequoia TCC workaround).
* `scripts/orchestrate.sh` — one-shot: `sync → mirror + patches → VM toolchain →
  VM build → linkage check → publish`.

## How It Works

* `packages.txt` is explicit only; deps resolved fresh via `brew deps --include-build`
  then filtered by `build-deps.conf` (external `rust/go/python@3.13` not bottled).
* `packages.lock.json` tracks `explicit`, `resolved{ver}`, `skipped_build_deps`,
  `core_sha`, `tag`; `sync.sh` queues only outdated/new formulae, toposorted.
* `patches/` holds diffs commenting out `depends_on "rust" => :build` (etc) to use
  external toolchains; applied after mirroring, fail-closed on `core_sha` drift.
* `publish.sh` uploads to Releases (per-formula `<formula>-<version>` tags) and merges
  `sha256` into `Formula` DSL. Custom `root_url` skips bottle attestation (SHA still checked).
* `root_url` is inferred from `git remote.origin.url` per formula:
  `https://github.com/<user>/homebrew-intel/releases/download/<formula>-<version>`.
  Override with `TAP_ROOT_URL` if remote is missing.

## Configuration

| Var | Default | Where |
| --- | ------- | ----- |
| `VM_NAME` | `brew-sequoia` | `vm.sh`, `orchestrate.sh` |
| `VM_CPUS / VM_MEM / VM_DISK` | `8 / 16384 / 80000` | `vm.sh create` |
| `SHARED_DIR` (host) | `~/Parallels/shared-brew` | `vm.sh`, `orchestrate.sh` |
| `VM_GUEST_SHARED` (guest) | `/tmp/shared` | `vm.sh` |
| `TAG` | `sequoia` (future: `tahoe`) | `sync.sh`, `orchestrate.sh`, `build.sh` |
| `VM_USER` | auto from `/dev/console` | `vm.sh exec` |
| `TOOLCHAIN_ENV` | `/tmp/shared/toolchain.env` | `toolchain.sh`, `build.sh` |
| `TAP_ROOT_URL` | inferred from git remote | `build.sh` |

`build-deps.conf` + `.tool-versions` — single pin per tool (`rust 1.82.0`,
`go 1.27.1`, `python 3.13.7`); `sync.sh` filters externals, `toolchain.sh` provisions,
`apply-patches.sh` checks patch header vs pin.

## Updating

* **Explicit list:** manual via `make add/remove PKG=` (validated). No auto import.
* **Upstream bumps:** `make orchestrate` auto-detects version changes and rebuilds
  affected formulae (incl. rdeps) even if `packages.txt` unchanged.
* **Tahoe later:** clone VM `brew-tahoe`, run `TAG=tahoe make orchestrate` — merges
  second `sha256 tahoe:` line.

## Problems & Toolchain Notes

* Tier 3 → Unsupported Sep 2027: tap stops when `brew` refuses Intel; pin `brew 6.x`
  or migrate to Linuxbrew/Docker.
* 300 bottles ~3GB/30-50h sequential; full 8588 core not feasible. Sequential +
  `brew cleanup` between.
* Custom `root_url` skips attestation; SHA still checked. Some licences
  non-redistributable — `brew audit` will skip.
* Relocation requires `/usr/local`; non-standard prefix fails. VM reused — keep
  `clean` + `toolchain-ready` snapshots, `prlctl suspend` between runs.
* **Build deps:** `rust`/`go` via official binaries (seconds vs hours, no linkage leak
  for `:build` deps). `python` slots (`3.13`/`3.14`/`3.15`) via `uv` prebuilt
  downloads (`asdf` compile fallback); `ruby` compiles once per snapshot.
  Pins live in `build-deps.conf` + `.tool-versions` (per-slot rule, see `docs/stack.md`).
* **Patches:** `patches/series` carries the active external-tool patches
  (`fd`/`fish`/`gh`/`ripgrep`/`starship`, one per `:build` dep).
  Applied after mirroring, fail-closed on `.rej` after `core_sha` bump — refresh via
  `git format-patch` (see `patches/README.md`).
* **TCC:** `/Volumes/SharedFolders/` is unreadable under Sequoia — transport is
  rsync over SSH (`./scripts/vm.sh shared-sync` stages host → `/tmp/shared/`,
  `rsync-from` collects bottles back), never direct mount reads.
* **`HOME=/` trap:** `vm.sh exec` without resolved GUI user runs as root with
  `HOME=/` — rustup/brew/asdf fail. Fix: `VM_USER=<gui-user> ...` (see `make vm-toolchain`).

## Verification

```bash
make status
make sync-dry
make vm-status
make patches-check
brew config  # should show x86_64, /usr/local
```

## License

BSD-2-Clause (same as Homebrew/brew). Bottles are derivative binaries; respect upstream formula licences.
