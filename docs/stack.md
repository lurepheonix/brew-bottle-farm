# Stack

Only source for versions and tooling. Do not duplicate pins elsewhere —
`build-deps.conf` + `.tool-versions` are the live pins, this file explains them.

## Host

- Intel macOS Sequoia `15.7.9-x86_64`, Homebrew `/usr/local` (verified `7.0.9`).
- `brew` Ruby DSL: `dev-cmd/bottle.rb` (`--build-bottle`, `--json`, `--merge --write --no-commit`), `utils/bottles.rb` (`Tag`), `brew info --json=v2`, `brew deps --include-build`, `brew linkage --test`.
- CLIs: `gh` (Releases upload), `gnu-tar` (bottle tarballs), `prlctl` 26.4+ (Parallels Desktop), `git`, `patch(1)`, `python3` (JSON helpers only, no deps).
- Runners: `bash` (`set -euo pipefail`), `make` (task wrappers; `make help` is source of truth). No Node, no Taskfile, no CI.

## VM (`brew-sequoia`, Parallels, reused via snapshots)

- macOS Sequoia Intel guest, 8c/16GB/80GB, `/usr/local` prefix (relocation requirement).
- Guest additions: Parallels Tools (shared folders), Xcode CLT (`xcode-select --install` in GUI Terminal only).
- File transport: host `~/Parallels/shared-brew` → guest `/tmp/shared` via `tar+base64` pipe (`vm.sh shared-sync`); direct `/Volumes/SharedFolders/` reads blocked by Sequoia TCC.
- Snapshots: `clean` (post-CLT) + `toolchain-ready` (post-toolchain, avoids ~15min python rebuild).

## External build toolchains (single pin each, `build-deps.conf`)

| Tool | Pin | Source | Strategy |
| ---- | --- | ------ | -------- |
| `rust` | `1.82.0` | `rustup:https://sh.rustup.rs` | `external` — official binary, seconds vs hours |
| `go` | `1.27.1` | `https://go.dev/dl/go1.27.1.darwin-amd64.tar.gz` | `external` — official tarball into `~/.local/go-<pin>` |
| `python@3.13` | `3.13.7` | `asdf:python` | `external` — `asdf` compiles CPython once per snapshot |
| `asdf` | `0.20.0` | precompiled `darwin-amd64` release tarball | `bootstrap` — provisioned by `toolchain.sh` itself, ignored by `sync.sh` |

Rules: one pin satisfies exactly one slot. Patch-level skew (`3.13.7` vs upstream `3.13.x`) allowed with warning; minor skew (`3.13` vs `python@3.14`) rejected — `python@3.14` stays brewed in Phase 1. `sync.sh` filters `external` from the bottle queue; `toolchain.sh` provisions; `apply-patches.sh` checks patch `# Tool:` header vs pin; `orchestrate.sh` verifies `build-deps.conf` ↔ `.tool-versions` before work.

## Bottle hosting

- GitHub Releases in public `homebrew-intel` tap, per-formula tags `<formula>-<version>`, `root_url` `https://github.com/<user>/homebrew-intel/releases/download/<formula>-<version>` (inferred from `origin.url`, override `TAP_ROOT_URL`).
- No GitHub Actions. Custom `root_url` skips `attestation.rb` ghcr attestation (documented tradeoff; SHA256 still verified).
- Lifetime: Homebrew Intel Tier Unsupported Sep 2027 — then pin `brew 6.x` or migrate to Linuxbrew/Docker.
