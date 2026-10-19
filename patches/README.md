# Patches

B1 plain-patch stack. Formulae are mirrored from `homebrew/core` into `Formula/*.rb` by `scripts/sync.sh` / `scripts/publish.sh:ensure_formula`; this directory holds unified diffs that make them use **external build toolchains** instead of `depends_on "rust" => :build` (etc).

## Layout

- `series` — ordered list of patch filenames (like quilt/stgit series). `#` comments ignored.
- `<pkg>-use-external-<tool>.patch` — `diff -u` vs `Formula/<pkg>.rb` (apply with `patch -p1 --forward` from repo root).

Stgit is **optional** local workflow, not required in VM/CI:

```bash
stg new ripgrep-use-external-rust
# edit Formula/ripgrep.rb
stg refresh
git format-patch --stdout -1 > patches/ripgrep-use-external-rust.patch
echo "ripgrep-use-external-rust.patch" >> patches/series
```

CI/VM only runs `patch(1)` via `scripts/apply-patches.sh`.

## Patch header (required)

Each patch must start with a comment block:

```
# Formula: ripgrep
# Upstream version tested: 14.1.0
# Tool: rust 1.82.0 (build-deps.conf) via rustup
# Why safe: depends_on "rust" => :build only, no linkage (brew linkage --test clean), std_cargo_args
# Core SHA: abc123...
```

## Rules

- Only `:build` deps are eligible. Runtime interpreter deps (`depends_on "python@3.15"`,
  `depends_on "ruby"` without `=> :build`, `uses_from_macos`) must **not** be patched
  (rejected by policy; `meson`/`sphinx-doc`/`asciidoctor` keep core interpreters in the VM).
- Per-slot pins: the version in a patch must match the `build-deps.conf` pin for that
  exact tool slot (checked by `apply-patches.sh`). Patch-level skew within a slot
  (e.g. `3.15.x` vs pin `3.15.0`) warns; cross-slot use (patch claims `python@3.14`
  for a `python@3.15` dep) is rejected. Python slots are provided via `uv` first,
  `asdf` fallback — see `build-deps.conf` `uv:python`.
- Future interpreter-swap patches (runtime `depends_on` → `<tap>/farm-toolchain` +
  path rewrites for `meson`/`sphinx-doc`/`asciidoctor`) use `# Tool: farm-toolchain <ver>`
  headers so pin-change auto-queueing in `sync.sh` picks them up. Until such patches
  exist, those intermediaries stay unpatched on core interpreters in the VM.
- Fail-closed: on `core_sha` bump, `apply-patches.sh` re-applies after re-mirror; `.rej` → non-zero exit, build blocked until human refreshes patch.

## Example

`ripgrep-use-external-rust.patch`:

```diff
--- a/Formula/ripgrep.rb
+++ b/Formula/ripgrep.rb
@@ -10,7 +10,8 @@
-  depends_on "rust" => :build
+  # brew-bottle-farm: external rustup 1.99.1 (build-deps.conf). Requires $CARGO_HOME on PATH.
+  # depends_on "rust" => :build  # disabled — see patches/README.md
+  env :std  # passthrough env so toolchain cargo is visible (superenv would scrub PATH)
```

`env :std` is required, not optional: external toolchains live outside brew's
dep tree, and superenv scrubs them from `PATH` (so the formula's `cargo`/`go`
calls fail). Per-command `--env=std` is disabled in current brew — the DSL line
in the formula is the sanctioned path. The VM image (snapshot) is our
hermeticity boundary instead.

Applied by: `./scripts/apply-patches.sh` (called by `orchestrate.sh` between `sync` and VM build).

## Adding a new tool

1. Add rows to `build-deps.conf` and matching pins to `.tool-versions` (per-slot rule).
2. Add patch file + entry in `series`.
3. Run `./scripts/apply-patches.sh --check-only` locally.
4. Build one patched leaf in VM, verify `brew linkage --test` clean and `otool -L` has no tool paths.
