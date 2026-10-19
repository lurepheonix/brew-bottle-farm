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
  → vm.sh shared-sync: host ~/Parallels/shared-brew → VM /tmp/shared (tar+base64)
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

## VM transport (Sequoia TCC)

`/Volumes/SharedFolders/` is not directly readable under Sequoia. `vm.sh shared-sync`
copies `scripts/toolchain.sh`, `scripts/build.sh`, `build-deps.conf`, `.tool-versions`,
`build-queue.txt`, `patches/series` (+referenced patches), `Formula/*.rb` into host `$SHARED_DIR`,
then `shared-stage` pipes `tar czf - -C $SHARED_DIR . | base64 | prlctl exec ... "base64 -d | tar xzf - -C /tmp/shared"`.
Staged files are owned by the GUI user when resolvable, else root + warning. `HOME=/` root-exec trap is guarded in `toolchain.sh` (fail with `VM_USER=` hint).
