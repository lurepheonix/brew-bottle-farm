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

- Only `:build` deps are eligible. Runtime `depends_on "python@3.14"` or `uses_from_macos` must **not** be patched (rejected by `apply-patches.sh --check-only`).
- Single pin: version in patch must match `build-deps.conf` pin for that tool (checked by `apply-patches.sh`).
- Python slot: single asdf pin `3.13.7` satisfies `python@3.13` (patch-level skew, warn) but **not** `python@3.14` (minor skew, reject). Phase 1 therefore only patches `python@3.13` consumers. If you bump the single pin to `3.14.x`, flip the allowlist and re-patch.
- Fail-closed: on `core_sha` bump, `apply-patches.sh` re-applies after re-mirror; `.rej` → non-zero exit, build blocked until human refreshes patch.

## Example

`ripgrep-use-external-rust.patch`:

```diff
--- a/Formula/ripgrep.rb
+++ b/Formula/ripgrep.rb
@@ -10,7 +10,8 @@
-  depends_on "rust" => :build
+  # brew-bottle-farm: external rustup 1.82.0 (build-deps.conf). Requires $CARGO_HOME on PATH.
+  # depends_on "rust" => :build  # disabled — see patches/README.md
```

Applied by: `./scripts/apply-patches.sh` (called by `orchestrate.sh` between `sync` and VM build).

## Adding a new tool

1. Add line to `build-deps.conf` and `.tool-versions` (single pin).
2. Add patch file + entry in `series`.
3. Run `./scripts/apply-patches.sh --check-only` locally.
4. Build one patched leaf in VM, verify `brew linkage --test` clean and `otool -L` has no tool paths.
