# AGENTS.md — brew-bottle-farm

> Operational contract for agents. Stack/architecture/plans live elsewhere;
> this file only points to them and sets workflow rules.

## Sources of truth

- Stack — `docs/stack.md` (only source; do not copy versions here, do not revisit stack).
- Architecture — `docs/architecture.md` (farm layout: `scripts/` + `Formula/` + `patches/` + `bottles/`; host vs VM split; two-repo model with public `homebrew-intel` tap).
- Plan — `plan/brew-bottle-farm.md` (milestones 0–3 + backlog; GitHub Actions CI and full-core builds are explicitly out of scope).
- Task reference — `Makefile` (`make help` is source of truth for runnable tasks; `scripts/*.sh --help` for flags).
- Patch workflow — `patches/README.md` (B1 plain-patch stack, single-pin header rule).

## Workflow

- Commits with body "what and why", understandable to a non-coder.
- Commit and push only on explicit owner command ("commit", "push").
- Docs in the same commit as the work (`docs/*`, `plan/*` updated together with code).
- No TODOs in code — file a plan item instead.
- No secrets in repo or logs (`GH_TOKEN`, VM creds, `.env` contents).
- No personal identifiers in repo (usernames, host paths) — use `<gui-user>` / `$HOME` placeholders.
- No GitHub Actions — do not add `.github/workflows/`; farm runs locally via `make`.
- Host/VM boundary: never run `scripts/toolchain.sh` or `scripts/build.sh` directly on host — the only sanctioned host path is `make orchestrate-local` (dry path, publish untouched; VM stays canonical). VM tasks go through `make vm-*` (`vm.sh ssh` as GUI user; `exec` stays for bootstrap/debug only).

## Quality

- Bash: `set -euo pipefail`; every script keeps working `--help` and (where applicable) `--dry-run`. (`shellcheck`/`shfmt` deferred to backlog — run when installed, don't gate on it.)
- Before push: `make sync-dry`, `make patches-check`, `make publish-dry`, `make vm-status` green.
- Single-pin rule: `build-deps.conf` ↔ `.tool-versions` ↔ patch `# Tool:` header must match; `toolchain.sh --check` is the verifier.
- Patches fail closed: any `.rej`/`.orig` aborts the run; refresh via `git format-patch` per `patches/README.md`, never force-apply.
- On conflicts between this file and `docs/`/`plan/`: `docs/stack.md` wins on versions.
