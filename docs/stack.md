# Stack

Only source for versions and tooling. Do not duplicate pins elsewhere —
`build-deps.conf` + `.tool-versions` are the live pins, this file explains them.

## Host

- Intel macOS Sequoia `15.7.9-x86_64`, Homebrew `/usr/local` (verified `7.0.9`).
- `brew` Ruby DSL: `dev-cmd/bottle.rb` (`--build-bottle`, `--json`, `--merge --write --no-commit`), `utils/bottles.rb` (`Tag`), `brew info --json=v2`, `brew deps --include-build`, `brew linkage --test`.
- CLIs: `gh` (Releases upload), `gnu-tar` (bottle tarballs), `prlctl` 26.4+ (Parallels Desktop), `git`, `patch(1)`, `python3` (JSON helpers only, no deps).
- Runners: `bash` (`set -euo pipefail`), `make` (task wrappers; `make help` is source of truth). No Node, no Taskfile, no CI.
- Host `python3` is stdlib-JSON only and must never depend on asdf slots: host scripts
  (`sync/packages/publish/orchestrate`) drop `~/.asdf/shims` from `PATH` when the shim
  cannot satisfy the repo `.tool-versions` (which pins VM-only interpreters).

## VM (`brew-sequoia`, Parallels, reused via snapshots)

- macOS Sequoia Intel guest, 8c/16GB/80GB, `/usr/local` prefix (relocation requirement).
- Guest additions: Parallels Tools (shared folders), Xcode CLT (`xcode-select --install` in GUI Terminal only).
- File transport: SSH + rsync (`vm.sh ssh-setup` once: host `~/.ssh/brew-farm` keypair,
  guest Remote Login via `launchctl enable/bootstrap`, key seeding, `known_hosts`
  refresh with stale DHCP pruning; IP re-resolved every run). `shared-sync` stages
  host `~/Parallels/shared-brew` → guest `/tmp/shared` via `rsync-to`; bottles come
  back via `rsync-from`. `prlctl exec` stays for bootstrap/debug only.
- Snapshots: `clean` (post-CLT) + `toolchain-ready` (post-toolchain, avoids recompiling python slots + ruby every run).

## External build toolchains (per-slot pins, `build-deps.conf`)

| Tool | Pin | Source | Strategy |
| ---- | --- | ------ | -------- |
| `rust` | `1.99.1` | `rustup:https://sh.rustup.rs` | `external` — official binary, seconds vs hours |
| `go` | `1.27.2` | `https://go.dev/dl/go1.27.2.darwin-amd64.tar.gz` | `external` — official tarball into `~/.local/go-<pin>` |
| `python@3.13` | `3.13.16` | `uv:python` (uv prebuilt, asdf fallback) | `external` — never bottled |
| `python@3.14` | `3.14.8` | `uv:python` (uv prebuilt, asdf fallback) | `external` — never bottled |
| `python@3.15` | `3.15.0` | `uv:python` (uv prebuilt since 0.13.1, asdf fallback) | `external` — never bottled |
| `ruby` | `4.0.7` | `asdf:ruby` | `external` — never bottled (compiled once per snapshot) |
| `node` | `26.12.0` | `asdf:nodejs` | `external` — never bottled (prebuilt) |
| `farm-toolchain` | `0.1.0` | `tap:homebrew-intel` (own fast pipeline) | `bottled` — stable leak target, filtered from normal queue |
| `asdf` | `0.20.2` | precompiled `darwin-amd64` release tarball | `bootstrap` — provisioned by `toolchain.sh` itself, ignored by `sync.sh` |
| `uv` | `0.13.1` | precompiled `darwin-amd64` release tarball | `bootstrap` — provisioned by `toolchain.sh` itself, ignored by `sync.sh` |

Rules: per-slot pins (one pin per `python@*` slot, `ruby`, `node`; latest finals).
`farm-toolchain` pin == formula version (bump both together).
Patch-level skew within a slot allowed with warning; cross-slot skew rejected.
`uv:python` means `uv python install` first (fast), `asdf install python` fallback when uv
lacks a build. Language runtimes are never bottled: leaves never runtime-link them
(verified for the starter set); bottled intermediaries that do (`meson`/`sphinx-doc` →
python, `asciidoctor` → ruby) stay unpatched and use core interpreters inside the VM,
and the linkage gate blocks external paths from leaking into bottles.
`sync.sh` filters `external` from the bottle queue; `toolchain.sh` provisions;
`apply-patches.sh` checks patch `# Tool:` header vs pin; `orchestrate.sh` verifies
`build-deps.conf` ↔ `.tool-versions` per slot before work. One-time compile cost
(python slots, ruby) is covered by the `toolchain-ready` snapshot.

## Bottle hosting

- GitHub Releases in public `homebrew-intel` tap, per-formula tags `<formula>-<version>`, `root_url` `https://github.com/<user>/homebrew-intel/releases/download/<formula>-<version>` (inferred from `origin.url`, override `TAP_ROOT_URL`).
- No GitHub Actions. Custom `root_url` skips `attestation.rb` ghcr attestation (documented tradeoff; SHA256 still verified).
- Lifetime: Homebrew Intel Tier Unsupported Sep 2027 — then pin `brew 6.x` or migrate to Linuxbrew/Docker.
