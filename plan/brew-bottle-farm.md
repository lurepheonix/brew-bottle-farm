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

- [x] `make help` coverage test (`make m1-check`): every script answers `--help` RC=0 non-empty; every side-effect-free target runs green; mutating/VM/interactive targets documented as skipped; tracked tree asserted unchanged; patch-count assertion derived from `patches/series` (never hardcoded).
- [x] `packages.sh status` + `sync.sh --dry-run` green on the starter set (`fd` canary already bottled + verified); lock `core_sha` refresh path tested (`--force`: `bf15382d` → `4312d06c`, `luajit` re-queued to `2.1.1792349434`, post-force dry-run queue 0). (`hello` fixture removed Oct 2026, not reintroduced.)
- [x] `apply-patches.sh --check-only` green on all 23 series patches (stack-aware: scratch unwind + re-apply roundtrip must reproduce the tree exactly; per-patch probes give false failures on same-file leader+follower stacks); `fish-use-external-rust` refreshed for core drift (`pour_bottle?` → `bottle do` block, header SHA → locked `core_sha`); `.rej` fail-closed demonstrated (`m1-check` synthetic bad-patch probe + `patch(1)` `.rej` artifact probe, both in scratch dirs).
- Done when: fresh checkout passes the Verification block in README with no VM running (covered: `status`, `sync-dry`, `patches-check` need no VM; `vm-status` is read-only `prlctl list`).

## M2 — Farm hardening (needs VM)

- [x] `build.sh` resume: `--resume` skips formulae with complete artifacts in the output dir; per-formula `/tmp/build-*.log` retention, `FAILED` list exit code (verified: back-to-back runs skip).
- [x] Linkage gate: `brew linkage --test` + `otool -L` leak check for external `rust/go/python` paths; block publish on failure (verified: green on VM `fd` and `gh` builds, `farm-toolchain` host build).
- [x] `brew cleanup` between formulae (VM path only — host cache belongs to the user); disk guard (`df` free-space check vs `FARM_MIN_DISK_GB`, default 10GB; VM disk 80GB assumption holds).
- [x] Real bottle end-to-end (starter set canary): `fd` → bottled + verified (`brew linkage --test` + `otool` clean) via VM build; tap Releases + `brew install <user>/intel/<formula>` deferred with publish (no real `gh release`, no tap pushes).
- [x] `sync.sh` records toolchain pins in lock (`toolchain`, `tap_provided`); slot-change auto-queues patched formulae + dependents.
- [x] `sync.sh` orphan-prune: BFS from explicit over direct deps, never through managed (`external`/`bottled`) nodes — drops managed-only subtrees (`llvm` via `rust`, plus `libgit2/libssh2/llhttp/z3` and `python`-only `readline/sqlite/mpdecimal/libyaml`); removals-only lock updates queue nothing (verified: `--force --dry-run` queues 66, plain dry-run queue 0).
- [x] `build.sh` multi-item loop fix: queue read on fd 3 + `</dev/null` on in-loop `brew` calls (a mid-loop read ate the queue fd → 1-of-75 silent RC=0); fail-closed `READ_COUNT`/classified-count asserts; verified with a 2-formula VM smoke (`pkgconf`+`xz`, linkage clean).
- [x] `build.sh` keep-during-run: `FARM_KEEP_INSTALLED=1` (VM + local) replaces the per-formula uninstall so the toposorted queue feeds itself on Tier-3 guests (no re-pour); `FARM_END_CLEANUP=1` does one reverse-order uninstall + `brew cleanup` after green runs (local keeps results); failures skip cleanup, `FAILED` kegs stay for debugging. Guest-side setup lives in `build.sh` itself (file, never ssh-quoted one-liners): one explicit `brew update` (auto-update disabled for the run via `HOMEBREW_NO_AUTO_UPDATE=1`), tap seeding + shim-keg install/reinstall before the loop.
- [x] Pinned mirrors + skew gate: `orchestrate` re-mirrors every queued `Formula/` from homebrew-core at the locked `core_sha` (raw URL — host `brew cat` serves stale download-cache copies, e.g. libpng 1.6.58 vs API 1.6.59); `build.sh` fails any formula whose installed keg mismatches expected `stable_revision`.
- [x] Farm shim-kegs for interpreter-needing intermediaries (option B): authored `Formula/python@3.15.rb` + `Formula/ruby.rb` (stable cellar symlinks to pinned uv/asdf interpreters; installed pre-build, never bottled) + dep-qualify patches for the intermediaries (`meson`/`sphinx-doc`/`python-setuptools`/`certifi` → `farm/local/python@3.15`, `asciidoctor` → `farm/local/ruby`, `env :std` where builds shell out); `toolchain.sh` provisions setuptools+wheel into every python slot (PEP 668: via `uv pip --break-system-packages`). Intra-queue edges must be single-sourced per install — core+farm objects for one rack self-deadlock brew's keg lock (found via certifi/sphinx `OperationInProgressError`, fixed by qualifying); unqualified edges also walk core text into unpourable nodes, so 11 more owner patches qualify poison-ward edges (`aom`/`dav1d`/`ffmpeg`/`fish`/`imagemagick`/`libheif`/`libuv`/`libvmaf`/`luv`/`neovim`/`ripgrep`).
- [x] `env :std` gap fix: the farm-tool consumers that lacked it (`libvmaf`/`dav1d` via farm meson, `libuv` via farm sphinx) failed with shim "not provisioned" (superenv scrubs `uv`, asdf holds no 3.15 slot), cascading to `aom`/`ffmpeg`; fixed in their patches, enforced by an `apply-patches.sh --check-only` lint (build-time farm-tool use ⇒ `env :std`).
- [x] Single naming scheme (no mixed tap names): patch text stays fork-agnostic (`farm/local/` placeholder + bare core names allowed); `orchestrate.sh` normalizes staged copies every run (placeholder → tap name, then every bare bottled dep → tap-qualified, comments skipped) with fail-closed asserts (no placeholder, no bare bottled deps, no tap-qualified externals); `publish.sh` repeats the mapping as a safety net. Builder resolves everything through `FARM_TAP_NAME` (from `TAP_REPO`, required on all paths, no legacy fallback).
- [x] Stage-ordering fix: `shared-sync` re-copied working-tree Formulae over the normalized staged copies (guest built `farm/local`-named deps against public-named shims — 17 failures in a 49/66 run); it no longer touches `Formula/`, orchestrate's mirror→apply→normalize is the sole writer.
- [x] In-tap patch files: formulae referencing `file "Patches/..."` (lua) failed with "Patch file does not exist" — `orchestrate.sh` 1d mirrors them from core at the lock SHA into staged `tap-files/` (never `Patches/` directly: case-insensitive filesystems merge it with farm `patches/` staging); `build.sh` overlays each ref into the guest tap next to the Formula, fail closed (lpeg/luv had silently built without real lua and needed rebuild).
- [x] Guest-clear quoting: `vm.sh run` argv crosses ssh join+reparse and both host/guest zsh fail bare non-matching globs — unquoted `rm $dir/*.tar.gz` silently cleared nothing (host glob failed first), so stale staging bottles were recollected as fresh. All guest clears now use `noglob find … -name '…' -delete` (verified live).
- [x] Tap alias mirroring (`opt/pkg-config`): installs record `tab.aliases` from the installing tap, and superenv's pkg-config shim hardcodes `opt/pkg-config` — the farm tap mirrors core `Aliases/` per queued formula (else Tier-3 configure builds fail `pkg-config not found`); verified `unlink+link` creates all three opt links.
- [x] Meson `bin/` wrapper with keg `PYTHONPATH` (`pip --prefix` ships no `.pth` into the toolchain python — bottled meson otherwise fails `No module named 'mesonbuild'` at first use).
- [x] Tap-compat removals: `no_autobump!` rejected outside official taps (`x264`, `luajit` patches, no pin header). 23 patches total.
- [x] Stable `CARGO_HOME` per run (`$VM_GUEST_SHARED/cargo-home`, overridable): brew's `cargo fetch` + `cargo install --offline` must share one registry (TMPDIR-keyed homes diverge between phases); content-addressed, safe to share, faster.
- [x] Version-aware resume: `FARM_RESUME=1` (propagated through `orchestrate`) skips only artifacts whose version matches the expected `stable_revision` (stale pairs are dropped and rebuilt, never silently collected).
- [x] `toolchain.env` stamp (`TOOLCHAIN_PINLIST`/`TOOLCHAIN_STAMP`); `build.sh` hard-fails on stale toolchain.
- [x] `check-toolchain-updates.sh` (`make toolchain-updates`): conf pins vs brew stables / uv builds / host bootstraps.
- [x] `farm-toolchain` bottled via own fast pipeline (`scripts/build-farm-toolchain.sh`, `make farm-toolchain`; `keg_only`, single-pin formula==conf; host-built 0.1.0 bottled). VM switched to `brew install farm-toolchain` (local bottle hand-pour) + `farm-toolchain provision` delegation in `toolchain.sh`.
- Done when: `make orchestrate` builds the starter set unattended after `make vm-toolchain`.

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
      Resolved 75, queued 66 (orphan-prune drops 9 managed-only subtrees incl. `llvm`;
      4 external build-deps via toolchain.sh: `go` + `rust` +
      `python@3.15` + `ruby`; `go` covered by B1 patch `gh-use-external-go`).
      Expect ~77 resolved, minus externals (`rust` + `python@3.13/3.14/3.15` + `ruby`
      via `ripgrep/starship/fd` build paths and `meson/sphinx-doc/asciidoctor`
      intermediaries — all provided by `toolchain.sh` via uv/asdf, never bottled).
      Intermediaries that runtime-link an interpreter (`meson`, `sphinx-doc`,
      `asciidoctor`) stay unpatched and use core interpreters in the VM.
- [ ] Deferred (8): `watchman` (heaviest — stays deferred);
  `httpie` (needs runtime-python strategy — orphan-prune drops its
  readline/sqlite, Tier-3 can't install it); `eza` done 2026-10-21;
  free batch (`cloudflared duf git-filter-repo go-task rclone scdoc shfmt
  smartmontools telnet`) done 2026-10-21; `dust`/`zoxide` done 2026-10-21,
  removed from the lists below.
  - [x] `mist-cli` (done 2026-10-22, bottled + published + host-pour verified):
  guest HAS full Xcode 26.3 + SDK 26.2, so only the toolchain leg needed work.
  Implemented `swift external 6.4.1` in `build-deps.conf` (official macOS `.pkg`,
  `pkgutil`+`cpio` extract, versioned home) + `Formula/swift.rb` shim-keg +
  `mist-cli-use-farm-swift.patch` (first `uses_from_macos` redirect, plus
  install-time `ENV.delete SDKROOT/CPATH` — brew pins both at the stale CLT SDK
  even under `env :std` and the swift driver mixed CLT 15.x headers into Xcode
  26.2 modules). `patches-check` 37/37; VM bottled it (linkage clean); host
  `brew install` pours + `mist --help` + linkage clean (replaced core-identical
  2.3, tap stays). En route: swiftly abandoned (its `.pkg` needs the installd
  daemon absent over SSH; `--version` lies pre-init; toolchain needs no swiftly
  at all); **publish gap closed**: leaf `:build` edges must resolve even for
  pure pours, so `publish.sh` now ships authored shim-kegs into the tap as
  resolution-only formulae.
  Lessons: (1) a failed orchestrate consumes its own queue — retry with
  `--force`, never plain; (2) every `toolchain.sh` change requires a
  `farm-toolchain` re-bottle + guest keg reinstall (the guest delegates to
  the vendored copy, not the staged script); (3) author patches by deriving
  context mechanically from pristine files — hand-typed context loses
  indent/whitespace and BSD `patch` fails closed with no useful diagnostic;
  (4) `env :std` passes brew's own SDKROOT/CPATH pins through (they point
  at the stale CLT) — compiled-toolchain consumers must scrub them in
  `def install`.
  - [x] `stgit` promotion (done 2026-10-22, all 9 bottled + published):
  runtime closure is EMPTY (self-contained Rust binary — `brew deps stgit`
  returns nothing); the `python@3.15` in `--include-build` is build-time only
  via `asciidoc`, so no runtime-python strategy needed (unlike `httpie`).
  `make add` + `sync` converged the lock (`b646889f` → `80a7992b`); pruned
  new set is 9, not 16 (`asciidoc boost docbook docbook-xsl gnu-getopt
  icu4c@78 source-highlight stgit xmlto` — llvm/z3/python-trio shaved by
  orphan-prune, rest already bottled). Three patches authored
  (`stgit-use-external-rust`, `asciidoc-use-farm-python`, both `env :std`;
  `docbook-no-autobump` — upstream added `no_autobump!` to `docbook` after
  the lock moved, same tap-compat class as `x264`/`luajit`);
  `patches-check` 36/36 green. 4 bottled in run 1 (boost 10 min);
  run 2 unblocked by the docbook patch; run 3 fixed the doc-catalog gap
  (`docbook-xsl` post-install never ran on the guest — fresh-prefix
  chicken-and-egg, `xmlcatalog --del` needs the file pre-created; created
  `/usr/local/etc/xml/catalog`, post-installed `docbook-xsl`+`docbook`,
  `xmlto`+`stgit` man builds then resolved locally instead of dying on
  http→https 301s). Verified: all 9 `brew fetch` clean from tap releases,
  stgit tarball sha256 exact match; stgit bottle pours with zero runtime
  deps (`:build`-only). Fetch --deps on the asciidoc path hits the known
  dangling-shim caveat (same pre-existing class as meson/sphinx-doc —
  harmless for pours).
  Lesson: never run non-dry `sync` between `add` and `orchestrate` — it
  records the new versions in the lock and the next sync queues 0,
  silently eating the build (`sync.sh:394` only queues lock-diffs).
  Promotion flow is `add` → `orchestrate` (`--force` + `skip-built`
  re-derives the queue safely). Record a `build.sh` post-install pass for
  catalog-owning formulae before the next doc-stack batch.
      + `automake cmake dust meson mist-cli nasm p7zip sphinx-doc
      stgit watchman zoxide` — promote in small batches after starter e2e.
- [ ] Never explicit: `asdf/uv/go/rust/python@*/ruby/node/swift` (external/bootstrap via `toolchain.sh`).
- Done when: `packages.txt` holds the 10, `make sync-dry` green,
  `packages.lock.json` + `build-queue.txt` written.

## Publish (done 2026-10-21: 65 new + `fd` canary = 66 live in `homebrew-intel`)

Prerequisites discovered during M2 close-out (all metadata-level; builds and
linkage are unaffected). Done before the first real publish:

- [x] `root_url` wiring: `orchestrate.sh` reads `TAP_REPO` from `.env`
  (same source `publish.sh` uses) and passes `TAP_ROOT_URL` through to the
  guest `build.sh`; explicit `--root-url` > `TAP_ROOT_URL` > git inference
  in `build.sh` (git inference would yield the *farm* repo on the host and
  nothing on the guest). Verified: `orchestrate --dry-run` prints the tap base.
- [x] Placeholder salvage: `scripts/fix-root-urls.sh` (`make fix-root-urls`)
  rewrites `USER/homebrew-tap` URL prefixes in `bottles/*.json` to the tap
  (SHA-safe, tarballs untouched; 23 rewritten, `farm-toolchain` left alone,
  all sha256 re-verified vs tarballs). Version-skewed bottles
  (`ca-certificates/cmake/libpng/libunistring/pcre2/pkgconf/tree-sitter`)
  still rebuild via the skew gate, not rewrite.
- [x] Dep rewrite for self-containment: `publish.sh` rewrites every bottled dep
  to `<tap-user>/intel/X` (from `TAP_REPO`) in bottled Formulae after
  `brew bottle --merge` — builder placeholder `farm/local/X` first, then bare
  `depends_on "N"` / `Formula["N"]` for every bottled N (comments skipped,
  scopes preserved); `--dry-run` previews. External build tools stay out (consumers
  install prebuilt bottles; no toolchain needed).
  Caveat (decided 2026-10-22, mist-cli batch): leaf `:build` edges must
  resolve even for pure bottle pours (`brew install` expands direct dep
  names), so `publish.sh` now ships the authored shim-kegs
  (`python@3.15`/`ruby`/`swift`) into the tap as resolution-only formulae
  (never bottled, `:build`-skipped at pour, never installed). Dangling refs
  remain only for direct intermediary installs and source builds — same
  accepted tradeoff as before.
- [x] Merge into the tap checkout: `brew bottle --merge` only writes into a
  checked-out tap and only finds formulae by full tap name — short keys hit
  API-only core ("No available formula"). `publish.sh` ensures the tap is
  tapped + trusted, copies staged Formulae in, merges with long-keyed JSON
  copies, runs the dep rewrite against the checkout, copies merged files back
  to the farm tree; `--push` pushes the tap (default: print the hint).
- [x] Remote asset names: release uploads use brew's download form (single
  dash, revision included); uploading local double-dash names 404s every
  pour (seen live with the `fd` canary).
- [x] Skip-bottled (`scripts/skip-built.sh`, `make skip-built`, step 1a in
  `orchestrate.sh`): prune queue entries the tap already bottles at the
  locked version (batch `brew info` on tap names, exact version + tag match,
  no token, never fails the run). `FARM_RESUME` now defaults to 1 so routine
  runs reseed + skip instead of rebuilding.
- [x] Full publish 2026-10-21: `sync --force` settled the lock (`dec878f0` →
  `2ad3663c`, 6 drifted all matched bottles except `sphinx-doc` 9.1.1 vs
  bottled 9.1.0_5); `publish.sh --push` on 66 JSONs (`farm-toolchain` staged
  out per owner call — keg-only infra stays out of the public tap);
  66 releases live with remote-form asset names; tap pushed (`b40aa50`, 66
  bottled Formulae); farm commit `8348aec`. Verified: `brew fetch` + sha256
  match (`pkgconf`), full pour + `linkage --test` + functional roundtrip
  (`brotli`, host restored after); `skip-built` pruned 65, queues only
  `sphinx-doc` (needs the VM for the guest rebuild). Lock-vs-bottle skew
  policy: bottles newer than the lock publish as-is; the lock converges on
  the next `sync --force`, never by hand-edit.
- [x] `publish.sh` dep-rewrite truncation fix: the tap-checkout rewrite built
  `out = []` but never appended — any touched Formula would have been
  emptied. Fixed (`out.append(line)`), verified against a synthetic formula
  (placeholder mapped, file intact). Found pre-push by reading the script.

## Backlog (not v1)

- [ ] Runtime-python leaf strategy (`httpie` deferred 2026-10-21): farm
  bottles no interpreter at runtime by design, but a Python app's closure
  needs `python@3.15` + `readline`/`sqlite`/`mpdecimal` on the pour machine.
  Options: bottle the runtime python stack, ship shim-keg providers in the
  tap, or keep such leaves out. Decide before promoting any python-runtime
  leaf.
- [x] `sphinx-doc` 9.1.1 guest rebuild (done 2026-10-21: VM run also caught a
  same-day core drift of `luajit` `...434` → `...110`; both bottled, linkage
  clean, published as 2 single-bottle releases; tap still 66 Formulae with
  refreshed blocks, 68 releases live).
  Lesson: the shared staging dir (`shared-brew/bottles`) is additive — Oct-20
  fossil pairs rode reseed→guest→pull back into `bottles/` (caught by count
  audit before publish; quarantined, never released). Purge shared fossils
  whenever a collect surprises the file count.
- [x] `go` 1.27.2 → 1.27.3 bump (done 2026-10-21, batched with the VM run):
  pin + tarball URL, `farm-toolchain` re-bottled (its vendored stamp is
  checked at provision — stale guest keg must be uninstalled so the new
  bottle hand-pours; hint updated). Patch header refreshed with it
  (`gh-use-external-go.patch` `# Tool: go 1.27.3` — single-pin rule;
  caught by `--check-only`, not by hand). Same-version dependents (`gh`) are
  intentionally NOT rebuilt: `skip-built` prunes by version+tag, and the
  linkage gate proves build-only tools never leak into bottles.
- [x] `apply-patches.sh --check-only` published-state gap (fixed 2026-10-21):
  Branch 3 re-mirrors the touched formulae pristine at the locked `core_sha`
  (needs network) and verifies forward-apply there — the exact input the next
  `orchestrate` stages. Verified: 23/23 apply onto pristine `2ad3663c`.
- [x] `m1-check.sh` make-RC mapping (fixed 2026-10-21): `make` maps a failed
  recipe to RC=2, so the `toolchain-updates` blessed-drift branch now accepts
  RC=2 with the script's `updates available` signature. Verified: full
  `m1-check` 32 passed, 0 failed.
- `orchestrate` 1b `--only` filter (added 2026-10-21): patch-apply touches
  only freshly-mirrored queued formulae, so the published
  (bottled+rewritten) rest of the tree no longer false-fails the run.
  Verified live on the `sphinx-doc`+`luajit` VM run.

- Package rollout batch 2 (scoped 2026-10-21, flat new-dep counts are upper
  bounds — `sync.sh` orphan-prune shaves managed-only subtrees at promotion):
  - [x] Free batch (done 2026-10-21): `duf rclone telnet go-task
    cloudflared smartmontools git-filter-repo` + `shfmt` (+1 tiny `scdoc`) —
    9 bottled, linkage clean. Needed 5 `*-use-external-go.patch` (one per Go
    consumer; the `external` row alone never redirects — each `:build` edge
    needs its own patch + `env :std`). `httpie` deferred: it runtime-links
    `python@3.15`, so orphan-prune drops its `readline`/`sqlite` and Tier-3
    can't install it — needs a runtime-python strategy first (plan item).
    `telnet` needs working `xcodebuild` on the guest (fixed live with
    `xcodebuild -runFirstLaunch` after a CoreSimulator plug-in failure).
    Publish hardening from this batch (both seen live): `publish.sh` skips
    non-lock JSONs + keg-only `farm-toolchain`, and pins tarballs to the
    exact pkg_version (fossil pairs previously globbed into wrong releases;
    3 bogus tags deleted, 2 legit releases de-polluted).
  - [x] External Haskell (done 2026-10-21, path B chosen): `ghc 9.14.1` +
  `cabal-install 3.18.2.0` are `external` rows (official x86_64-darwin
  bindists, URLs verified live), provisioned by `toolchain.sh` into
  versioned user-local prefixes (ghc needs `./configure --prefix` + `make
  install`; cabal is a bare binary), covered by `--check` and
  `toolchain.env`, auto-detected by `check-toolchain-updates.sh` and
  `sync.sh` (both read the conf generically). Verified by a real guest
  provision (all 12 toolchain entries green). Consumer patches authored at
  the locked core: `pandoc-use-external-ghc` (leader) +
  `pandoc-use-external-cabal-install` (follower, cumulative context) +
  `eza-use-external-rust`. Found en route: `apply-patches.sh` sorted the
  series alphabetically, breaking leader/follower pairs whose names don't
  sort dependency-first — series file order is now authoritative
  (order-preserving dedupe; `sync.sh` already honored file order). 26/26
  apply onto pristine core; `m1-check` 32/32.
  - [x] `eza` promotion (done 2026-10-21): `make add eza` → guest built
  `eza` + `pandoc` + `libgit2`/`libssh2`/`llhttp`/`gmp` (no `openssl@3` —
  bottled libgit2 links `openssl@4`; no `llvm` — pruned via external rust),
  linkage clean, 6 releases published. `pandoc` Haskell build took ~20 min
  against external GHC. Two publish defects found and fixed en route (both
  would have left the tap unpourable): the dep-rewrite only handled
  self-refs (now per-file over the bottled set, with fail-closed asserts —
  same shape as orchestrate 1c), and release tags wrongly included the
  revision (`libgit2-1.9.7_2` 404s; brew expects tag `libgit2-1.9.7` with the
  revision only in the asset name — tag now derived from the JSON
  `root_url` leaf). 7 mistagged releases repaired (6 re-created, 1 obsolete
  `sphinx-doc-9.1.0_5` deleted). Verified: `fetch --deps` pulls the full
  closure from tap releases; `eza` installs from the tap (host needed
  `--ignore-dependencies`: core `ca-certificates` keg blocks the tap one —
  expected on a core-populated dev host, no conflict on fresh Tier-3
  machines). Host impact: core `eza` replaced by tap `eza` 0.23.5
  (version-identical, linkage clean; core `eza` reinstall would be a source
  build, so the tap bottle stays).
  - [x] `dust`/`zoxide` (done 2026-10-21: rode the bottled libgit2-group,
    prune shaved llvm/z3/python-trio as scoped; 1 `*-use-external-rust.patch`
    each; `gh` 2.102.1 → 2.103.0 drift rebuilt in the same run; guest
    resume + `skip-built` meant 3 builds, not 83); `stgit` (16:
    boost/icu/docbook doc-stack — batch alone); `mist-cli` (verify the
    `swift` dep before anything — likely Xcode-system, not bottlable).
  - Deferred: `watchman` (29 new, folly/fbthrift/mvfst stack — confirmed
    heaviest, stays deferred).

- `shellcheck` + `shfmt -d` clean for all `scripts/*.sh` (deferred per owner; document versions in `docs/stack.md` when adopted).
- Full-core builds (8588 formulae infeasible; 300 bottles ~3GB/30-50h sequential).
- Linuxbrew/Docker migration path for post-Sep-2027.
- Bottle attestation for custom `root_url` (upstream `attestation.rb:231` skips ghcr).
- Optional `stg` local patch workflow automation.
- Taskfile migration (rejected for now — see `docs/architecture.md` host/VM split; revisit only if `make` becomes insufficient).
