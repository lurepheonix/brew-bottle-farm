# Architecture

## Repos

- **Farm (this repo, `brew-bottle-farm`):** `scripts/`, `patches/`, `packages.txt`, `packages.lock.json`, `build-queue.txt`, `build-deps.conf`, `.tool-versions`, `Makefile`, `docs/`, `plan/`. Working-copy `Formula/*.rb` (mirrored) + `bottles/` (artifacts, gitignored except `.keep`).
- **Tap (public `homebrew-intel`):** `Formula/*.rb` with merged bottle blocks + GitHub Releases (`<formula>-<version>` tags). Consumers `brew tap <user>/intel` only this repo.

## Data flow

```
packages.txt (explicit, manual via packages.sh)
  → sync.sh: resolved = explicit ∪ brew deps --include-build
             − external (build-deps.conf) → build-queue.txt (toposorted) + packages.lock.json
  → orchestrate.sh: mirror Formula/*.rb (brew cat) → apply-patches.sh (patches/series)
  → vm.sh shared-sync: host ~/Parallels/shared-brew → VM /tmp/shared (rsync over SSH)
  → VM: toolchain.sh (→ toolchain.env) → build.sh (brew install --build-bottle + brew bottle --json)
  → host bottles/ (*.tar.gz + *.json)
  → publish.sh: gh release create + brew bottle --merge --write --no-commit → git commit → git push
  → consumer: brew install <user>/intel/<formula>
```

## Host vs VM split (load-bearing)

Host-only: `packages.sh`, `sync.sh`, `apply-patches.sh`, `publish.sh`, `orchestrate.sh`, `vm.sh` itself. `Makefile` default targets wrap these; `make help` is the list.

VM-only (never run on host): `toolchain.sh`, `build.sh`. Invoked as
`vm.sh exec bash /tmp/shared/scripts/toolchain.sh` / `.../build.sh` under the GUI user
(auto-detected from `/dev/console`, `VM_USER` override) with `TOOLCHAIN_ENV=/tmp/shared/toolchain.env`.
`make vm-toolchain`, `make vm-toolchain-check`, `make vm-shell` are the only VM entry points.

Why: `toolchain.sh` writes user-scoped installs (`~/.cargo`, `~/.local/go-*`, `~/.local/bin` for `uv`,
`~/.local/share/uv/python`, `~/.asdf`) and
`build.sh` requires guest `brew` + `/usr/local` prefix + patched `Formula/` at `/tmp/shared/Formula/`.
Running either on host provisions/builds the wrong machine and breaks the single-pin env.

## Key files

- `packages.txt` — explicit list, source of truth; header comment preserved by `packages.sh`.
- `packages.lock.json` — `{explicit, resolved{name: pkgVersion}, skipped_build_deps, core_sha, tag, generated_at}`; `sync.sh` diffs `pkgVersion` + dep-set + `core_sha`.
- `build-queue.txt` — toposorted rebuild list (deps first); gitignored, regenerated.
- `build-deps.conf` — `<name> <external|bottled|bootstrap> <pin> <source>`; per-slot pins
  (`python@3.13/3.14/3.15`, `ruby`, `node`); `uv:python` = uv first, asdf fallback.
  `asdf`/`uv` must be `bootstrap` (else `sync.sh` would treat the real formulae as skippable).
  `farm-toolchain` is `bottled` (own fast pipeline, filtered from the normal queue).
- `patches/series` + `<pkg>-use-external-<tool>.patch` — B1 quilt-style stack, `patch -p1 --forward`, fail-closed on `.rej`; header `# Tool: <name> <ver>` checked vs `build-deps.conf`; only `:build` deps patchable (runtime interpreters in `meson`/`sphinx-doc`/`asciidoctor` stay unpatched, use core interpreters in the VM). Today example-only (all entries commented out).
- `Formula/*.rb` — mirrored working copies (`brew cat`), patched in place; `publish.sh:ensure_formula` re-mirrors missing ones.
  Exception: `Formula/farm-toolchain.rb` is authored here (not mirrored) — the versioned
  toolchain bundle; bottled by the farm's own fast pipeline, filtered from the normal queue.
- `bottles/` — `*.tar.gz` + `*.json` from `build.sh`; gitignored, collected by `orchestrate.sh` from shared dir.

## VM transport (SSH; prlctl stays for bootstrap/control only)

Primary transport is SSH + rsync: host keypair `$HOME/.ssh/brew-farm` (never in
repo), guest Remote Login enabled once via `vm.sh ssh-setup` (requires explicit
`VM_USER`; `launchctl enable/bootstrap` as root, one-time GUI toggle fallback),
key seeded via root, host `known_hosts` refreshed with stale DHCP entries pruned.
The guest DHCP IP is re-resolved every run; SSH fails closed with key auth only
(`BatchMode=yes`, never password-prompt). `vm.sh ssh`, `rsync-to`, `rsync-from`
replace the old `tar+base64` pipe and the `cat | prlctl exec` queue push; bottle/log
collection is `rsync-from` (the old shared-folder-mount assumption never worked
guest→host under Sequoia TCC). `prlctl exec` stays for bootstrap/debug only: IP
discovery, `sshd` repair, initial key seeding, plus VM lifecycle/snapshots.
`vm.sh shared-sync` still stages the same tree (`scripts/`, `build-deps.conf`,
`.tool-versions`, `build-queue.txt`, `patches/series` + referenced patches,
`Formula/*.rb`) but ships it via rsync, owned by the GUI user through the SSH
login (no root `HOME=/` trap). `make vm-ssh-setup` / `make vm-ssh` are the entry
points; `orchestrate.sh` runs its whole VM loop (stage → toolchain → build →
collect) over SSH with no `prlctl` pipe.

## Publish credentials (tap releases)

Releases land in the tap repo (`TAP_REPO`, e.g. `<user>/homebrew-intel`), never in
this farm checkout (`publish.sh` passes explicit `--repo` on every `gh` call; repo
is never inferred from cwd). The credential rules:

- **Token type:** fine-grained PAT scoped to the single tap repo, **Contents: read +
  write** only, short expiry. Release create/view, asset upload/clobber, and tag
  creation all ride on Contents; nothing else is granted (no repo deletion, settings,
  Actions, or access to any other repo).
- **No persistent auth:** never `gh auth login`. The token lives outside any tool
  config and is injected per-command via `GH_TOKEN` (which `gh` honors with zero
  config state). No `export` into persistent shell state — prefix form dies with
  the command.
- **Storage:** macOS Keychain item first (encrypted at rest, not greppable):
  `security add-generic-password -s farm-tap-token -a <user> -w`, retrieved as
  `GH_TOKEN="$(security find-generic-password -s farm-tap-token -w)"`.
  Fallback is a `600` file outside the repo (FileVault covers powered-off; live
  same-UID reads are reachable either way — the Keychain's approval prompt is the
  property a dotfile can't give).
- **Config:** repo-root `.env` (gitignored) holds non-secrets only — `TAP_REPO`,
  plus one pointer: `FARM_TOKEN_FILE=…` or `FARM_TOKEN_KEYCHAIN_ITEM=…` (default
  `farm-tap-token`). Committed `.env.example` documents the keys with placeholders.
  `publish.sh` refuses to run if `.env` matches a token pattern (`ghp_|github_pat_|gho_`)
  — the no-secrets-in-repo rule enforced in code.
- **Resolution order** (`publish.sh`, first hit wins, value never printed or logged,
  dry-run preview lines contain no token): `GH_TOKEN` in environment → `FARM_TOKEN_FILE`
  (must exist; fail closed if group/world-readable) → Keychain item → abort with
  setup instructions.
- **Verify without touching anything:** `GH_TOKEN="$(…)" gh auth status`.
- **Blast radius:** a leaked token is usable only against that repo's releases within
  its expiry window. Rotate on expiry or any surprise (GitHub shows per-token last-used).
  The token never enters the VM or any snapshot; publish stays host-only and runs on
  explicit owner order.
