# Patches

B1 plain-patch stack. Formulae are mirrored from `homebrew/core` into `Formula/*.rb` by `scripts/sync.sh` / `scripts/publish.sh:ensure_formula`; this directory holds unified diffs that make them use **external build toolchains** instead of `depends_on "rust" => :build` (etc).

## Layout

- `series` — ordered list of patch filenames (like quilt/stgit series). `#` comments ignored.
- `<pkg>-use-external-<tool>.patch` — `diff -u` vs `Formula/<pkg>.rb` (apply with `patch -p1 --forward` from repo root).
- Same-file followers: when two patches touch one formula, generate the later
  one against the earlier-applied state (cumulative context), so series order
  always applies — a follower diffed against pristine breaks once the leader
  lands (seen with fish rust+sphinx).
- `--check-only` verifies the whole stack at once (scratch unwind in reverse
  order + re-apply in order must reproduce the tree exactly), because a leader
  patch is only reversible before its followers land — per-patch reverse probes
  would false-fail on applied trees. Keep full hunk context (BSD `patch`
  rejects mid-file hunks with zero trailing context).

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

- Only `:build` deps are eligible for external-toolchain swaps. Runtime interpreter deps
  (`depends_on "python@3.15"`, `depends_on "ruby"` without `=> :build`, `uses_from_macos`)
  must **not** point at unpackaged externals; the intermediaries that need them
  (`meson`/`sphinx-doc`/`python-setuptools`/`certifi` → `farm/local/python@3.15`,
  `asciidoctor` → `farm/local/ruby`) resolve to the farm shim-kegs
  (`Formula/python@3.15.rb`, `Formula/ruby.rb`: stable cellar paths backed by the
  pinned uv/asdf interpreters, installed on the builder, never bottled).
  Intra-queue dep edges must be single-sourced per install: an unqualified edge
  (resolving to core) alongside a `farm/local/` edge to the same rack yields two
  formula objects for one cellar path, and brew deadlocks itself (non-blocking
  flock on its own held keg lock). Qualify every edge to a farm-covered name.
- Naming convention (single scheme): patch text stays fork-agnostic — bottled
  deps appear as `farm/local/X` (placeholder) or bare core names; either is
  fine in a patch. `orchestrate.sh` normalizes the *staged* copies every run
  (`farm/local/` → tap name, then every bare bottled dep → tap-qualified,
  comments skipped) with fail-closed asserts (no placeholder left, no bare
  bottled deps, no tap-qualified externals). `publish.sh` repeats the same
  mapping over the bottled set as a safety net. Never hardcode a real tap
  name (`<user>/intel`) in a patch — it breaks other forks.
- Any formula invoking farm tools at build time (`:build`-scoped `farm/local`
  dep or `Formula["farm/local/..."]` reference) must declare `env :std`:
  superenv scrubs `uv` from PATH and the farm shims fail loud otherwise
  (checked by `apply-patches.sh --check-only`).
- Per-slot pins: the version in a patch must match the `build-deps.conf` pin for that
  exact tool slot (checked by `apply-patches.sh`). Patch-level skew within a slot
  (e.g. `3.15.x` vs pin `3.15.0`) warns; cross-slot use (patch claims `python@3.14`
  for a `python@3.15` dep) is rejected. Python slots are provided via `uv` first,
  `asdf` fallback — see `build-deps.conf` `uv:python`.
- Shim-keg patches (runtime `depends_on` → `farm/local/python@3.15` / `farm/local/ruby`
  + `env :std` where the build shells out to the interpreter) use
  `# Tool: python@3.15 <pin>` / `# Tool: ruby <pin>` headers so pin-change
  auto-queueing in `sync.sh` picks them up. The shim-keg formulae themselves
  (`Formula/python@3.15.rb`, `Formula/ruby.rb`) are authored, not mirrored:
  version must equal the conf pin (bump together); they install symlinks only
  (upstream tarball fetched+verified, content unused) and are pre-installed on
  the builder by `orchestrate.sh` (never queued, never bottled).
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
