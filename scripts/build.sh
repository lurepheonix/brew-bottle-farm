#!/usr/bin/env bash
set -euo pipefail
umask 022 # prlctl exec sessions can carry umask 000 (world-writable files
          # break bundler's security check in `brew bottle`); enforce 022.

# build.sh — bottle builder: VM (macOS Sequoia, /usr/local) or host dry path
# Usage: ./scripts/build.sh [build-queue.txt] [--tag sequoia] [--root-url URL] [--output-dir DIR]
# Runs in the VM via orchestrate.sh, or on the host via orchestrate --local.
#
# For each formula in queue:
#   brew uninstall --force (clean; host pre-existing kegs restored when FARM_RESTORE_KEGS=1)
#   brew install --build-bottle
#   brew bottle --json --root-url=...
#   brew cleanup between formulae (unless FARM_CLEANUP=0)
# Collects *.bottle.tar.gz + *.json into $OUTPUT_DIR (default: ./bottles)

TAG="${TAG:-sequoia}"
ROOT_URL="${ROOT_URL:-}"
OUTPUT_DIR="${OUTPUT_DIR:-./bottles}"
QUEUE_FILE="${1:-./build-queue.txt}"

# Location roots (Phase 2): every path below is overridable so the same script
# runs in the VM (VM_GUEST_SHARED=/tmp/shared, BREW_PREFIX=/usr/local) and on
# the host dry path (orchestrate --local). Defaults preserve VM behavior.
BREW_PREFIX="${BREW_PREFIX:-/usr/local}"
VM_GUEST_SHARED="${VM_GUEST_SHARED:-/tmp/shared}"
SHARED_DIR="${SHARED_DIR:-$HOME/Parallels/shared-brew}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-/tmp}"
# M2 behavior flags (env-only except --resume):
#   FARM_RESUME=1        skip formulae whose bottle artifacts already exist in OUTPUT_DIR
#   FARM_CLEANUP=1       `brew cleanup` between formulae (VM path; host cache is
#                        the user's — orchestrate --local sets 0)
#   FARM_RESTORE_KEGS=1  reinstall a pre-existing keg this build uninstalled
#                        (host additive-only — orchestrate --local sets 1)
#   FARM_MIN_DISK_GB     free-space guard in GB (fail closed below threshold)
FARM_RESUME="${FARM_RESUME:-0}"
FARM_CLEANUP="${FARM_CLEANUP:-1}"
#   FARM_KEEP_INSTALLED=1  leave each bottled formula installed for downstream
#                        queue entries (required on Tier-3 guests where deps
#                        cannot be re-poured; orchestrate sets it on both
#                        paths — local builds keep results on the consumer)
#   FARM_END_CLEANUP=1   after a fully green run, uninstall all BUILT formulae
#                        + one brew cleanup (VM path only; local keeps results
#                        unless explicitly removed; failures skip cleanup and
#                        keep FAILED kegs for debugging)
FARM_KEEP_INSTALLED="${FARM_KEEP_INSTALLED:-0}"
FARM_END_CLEANUP="${FARM_END_CLEANUP:-0}"
FARM_RESTORE_KEGS="${FARM_RESTORE_KEGS:-0}"
FARM_MIN_DISK_GB="${FARM_MIN_DISK_GB:-10}"
# FARM_TOOLCHAIN_GATE=strict|skip. strict (default) hard-fails on a stale or
# missing toolchain stamp. skip is for non-canonical host-local builds only
# (orchestrate --local sets it with a warning); linkage + otool gates still run.
FARM_TOOLCHAIN_GATE="${FARM_TOOLCHAIN_GATE:-strict}"

# Parse opts
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --root-url) ROOT_URL="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --resume) FARM_RESUME="1"; shift ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/build.sh [build-queue.txt] [--tag sequoia] [--root-url URL] [--output-dir ./bottles] [--resume]
  Runs in the VM or on the host (--local). Requires brew, CLT, Xcode.
  --root-url: override bottle root_url (default: https://github.com/<user>/homebrew-intel/releases/download/<formula>-<version>)
  --resume: skip formulae whose bottle artifacts already exist in the output dir
  Env: FARM_RESUME FARM_CLEANUP FARM_RESTORE_KEGS FARM_KEEP_INSTALLED FARM_END_CLEANUP FARM_MIN_DISK_GB FARM_CARGO_HOME BREW_PREFIX
       VM_GUEST_SHARED SHARED_DIR BUILD_LOG_DIR FARM_TOOLCHAIN_GATE TOOLCHAIN_ENV
EOF
      exit 0 ;;
    --*) echo "unknown opt $1" >&2; exit 1 ;;
    *) QUEUE_FILE="$1"; shift ;;
  esac
done

if [[ ! -f "$QUEUE_FILE" ]]; then
  echo "error: queue file not found: $QUEUE_FILE" >&2
  echo "hint: run ./scripts/sync.sh on host first, then scp build-queue.txt into VM" >&2
  exit 1
fi

QUEUE_COUNT=$(grep -c . "$QUEUE_FILE" || true)
if [[ "$QUEUE_COUNT" -eq 0 ]]; then
  echo "build queue empty — nothing to do"
  exit 0
fi

# Determine repo for root_url if not given.
# Explicit TAP_ROOT_URL (derived from TAP_REPO in orchestrate.sh) always wins:
# the farm checkout's own git remote points at brew-bottle-farm, never the tap,
# and the VM guest has no git remote at all.
if [[ -n "${TAP_ROOT_URL:-}" ]]; then
  echo "tap root_url base: $TAP_ROOT_URL (explicit TAP_ROOT_URL)"
elif [[ -z "$ROOT_URL" ]]; then
  # Try to infer from host git remote
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    remote=$(git config --get remote.origin.url 2>/dev/null || true)
    # remote like git@github.com:user/homebrew-tap.git or https://github.com/user/homebrew-tap.git
    if [[ "$remote" =~ github.com[:/]([^/]+)/([^/.]+) ]]; then
      user="${BASH_REMATCH[1]}"
      repo="${BASH_REMATCH[2]}"
      repo="${repo%.git}"
      # root_url will be per-formula; we set base domain, but brew bottle --root-url expects full prefix
      # We'll construct per-formula below, so leave ROOT_URL empty to trigger per-formula construction
      echo "inferred GitHub repo: $user/$repo (per-formula root_url will be https://github.com/$user/$repo/releases/download/<formula>-<version>)"
    fi
  fi
fi

# Headless exec sessions can ship a minimal PATH — brew may be installed but invisible.
# Normalize before anything else (same as toolchain.sh).
export PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$HOME/.local/bin:$HOME/.cargo/bin:${GOROOT:-$HOME/.local/go}/bin:$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"

# Source external toolchain if provisioned (rustup + go + uv/asdf runtimes)
TOOLCHAIN_ENV="${TOOLCHAIN_ENV:-$VM_GUEST_SHARED/toolchain.env}"
if [[ -f "$TOOLCHAIN_ENV" ]]; then
  echo "sourcing toolchain $TOOLCHAIN_ENV"
  # shellcheck disable=SC1090
  source "$TOOLCHAIN_ENV" || true
elif [[ -f "./toolchain.env" ]]; then
  echo "sourcing toolchain ./toolchain.env"
  # shellcheck disable=SC1090
  source "./toolchain.env" || true
fi
# Staleness gate: toolchain.env stamp must match the staged build-deps.conf pins.
# Prevents building patched formulae with a stale toolchain snapshot.
_toolchain_conf=""
for _cand in "$VM_GUEST_SHARED/build-deps.conf" "$(dirname "$0")/../build-deps.conf" "./build-deps.conf"; do
  if [[ -f "$_cand" ]]; then
    _toolchain_conf="$_cand"
    break
  fi
done
if [[ "${FARM_TOOLCHAIN_GATE}" == "skip" ]]; then
  echo "warn: toolchain staleness gate skipped (FARM_TOOLCHAIN_GATE=skip — non-canonical build, linkage gate still enforced)" >&2
elif [[ -n "${_toolchain_conf:-}" ]]; then
  _conf_pinlist=$(grep -v '^[[:space:]]*#' "$_toolchain_conf" 2>/dev/null | grep -v '^[[:space:]]*$' | awk 'NF>=3 && ($2=="external" || $2=="bottled") {print $1"="$3}' | sort | tr '\n' ' ' | sed 's/ *$//' || true)
  if [[ -z "${TOOLCHAIN_PINLIST:-}" ]]; then
    echo "error: toolchain.env has no TOOLCHAIN_PINLIST stamp — re-provision before building" >&2
    echo "hint: provision the toolchain first (VM: make vm-toolchain; host dry path: orchestrate --local runs toolchain --check)" >&2
    exit 1
  elif [[ "$_conf_pinlist" != "${TOOLCHAIN_PINLIST:-}" ]]; then
    echo "error: toolchain.env stamp mismatch — toolchain snapshot is stale" >&2
    echo "  staged: ${_conf_pinlist:-<empty>}"
    echo "  env:    ${TOOLCHAIN_PINLIST:-<empty>}"
    echo "hint: re-provision the toolchain (VM: make vm-toolchain)" >&2
    exit 1
  else
    echo "toolchain stamp ok (${TOOLCHAIN_STAMP:-unstamped})"
  fi
else
  echo "warn: no staged build-deps.conf found — skipping toolchain staleness gate" >&2
fi
# Rustup proxies resolve the toolchain via settings/env lookup, which does not
# survive the brew build sandbox — pin it explicitly (matches `rustup run`).
if [[ -n "${TOOLCHAIN_RUST_PIN:-}" ]]; then
  export RUSTUP_TOOLCHAIN="$TOOLCHAIN_RUST_PIN"
fi
# Stable cargo home for the whole run (not per-build TMPDIR): brew's
# `cargo fetch` + `cargo install --offline` steps must share one registry or
# offline resolution fails on an empty index. Content-addressed and safe to
# share across formulae (and faster: fetch once). Overridable via FARM_CARGO_HOME.
export CARGO_HOME="${FARM_CARGO_HOME:-$VM_GUEST_SHARED/cargo-home}"
mkdir -p "$CARGO_HOME"
# Wrap toolchain proxies for the brew sandbox: only PATH is known to survive
# into the build env (RUSTUP_TOOLCHAIN and friends are filtered), so the
# wrapper pins everything explicitly and execs the real toolchain binary.
# (The VM image/snapshot is our hermeticity boundary, not the sandbox.)
if [[ -n "${TOOLCHAIN_RUST_PIN:-}" ]]; then
  FARMBIN="${FARMBIN:-$HOME/.local/farmbin}"
  mkdir -p "$FARMBIN"
  _CHOME="${CARGO_HOME:-$HOME/.cargo}"
  _RHOME="${RUSTUP_HOME:-$HOME/.rustup}"
  for _tool in cargo rustc; do
    cat > "$FARMBIN/$_tool" <<EOF
#!/bin/sh
# farm wrapper: explicit toolchain config (brew filters parent env)
export HOME="$HOME"
export RUSTUP_HOME="$_RHOME"
export RUSTUP_TOOLCHAIN="$TOOLCHAIN_RUST_PIN"
# Respect an explicitly set CARGO_HOME (build.sh pins one stable home per run
# so fetch+offline-install share a registry); fall back to a TMPDIR scratch.
export CARGO_HOME="\${CARGO_HOME:-\${TMPDIR:-/tmp}/farm-cargo}"
_REAL="$_RHOME/toolchains/$TOOLCHAIN_RUST_PIN-x86_64-apple-darwin/bin/$_tool"
if [ -x "\$_REAL" ]; then exec "\$_REAL" "\$@"; fi
exec "$_CHOME/bin/$_tool" "\$@"
EOF
    chmod +x "$FARMBIN/$_tool"
  done
  export PATH="$FARMBIN:$PATH"
fi
# Pre-flight: if any queued formula is patched to use external rust/go, assert toolchain present
if [[ -n "${TOOLCHAIN_RUST_PIN:-}" ]] && ! command -v cargo >/dev/null 2>&1; then
  echo "warn: TOOLCHAIN_RUST_PIN=$TOOLCHAIN_RUST_PIN but cargo not on PATH — patched formulae needing rust will fail" >&2
fi
if [[ -n "${TOOLCHAIN_GO_PIN:-}" ]] && ! command -v go >/dev/null 2>&1 && [[ ! -x "${GOROOT:-/usr/local/go}/bin/go" ]]; then
  echo "warn: TOOLCHAIN_GO_PIN=$TOOLCHAIN_GO_PIN but go not on PATH" >&2
fi

# Tap identity (single naming scheme, no legacy fallback): FARM_TAP_NAME is the
# fully-qualified short tap name (e.g. lurepheonix/intel) that every bottled
# dep resolves through; orchestrate.sh derives it from TAP_REPO (required)
# and passes it in. TAP_USER/TAP_REPO_NAME locate the tap dir.
if [[ -z "${FARM_TAP_NAME:-}" ]]; then
  echo "error: FARM_TAP_NAME must be set (orchestrate.sh derives it from TAP_REPO)" >&2
  echo "hint: set TAP_REPO in .env (e.g. TAP_REPO=<user>/homebrew-intel)" >&2
  exit 1
fi
if [[ "$FARM_TAP_NAME" != */* ]]; then
  echo "error: FARM_TAP_NAME must be a qualified tap name like <user>/<tap> (got '$FARM_TAP_NAME')" >&2
  exit 1
fi
# Tap dir parts (both paths: the per-formula overlay below needs the dir too).
if [[ -z "${TAP_USER:-}" || -z "${TAP_REPO_NAME:-}" ]]; then
  echo "error: TAP_USER/TAP_REPO_NAME must be set (orchestrate.sh derives them from TAP_REPO)" >&2
  exit 1
fi

# Shim-keg bootstrap (VM path only; skipped for --local host builds).
# Tier-3 guests cannot pour core python/ruby, so dep resolution needs the
# authored shim-kegs installed before the queue builds. Runs from a file
# (never via ssh-quoted one-liners): seeds the local tap from staged files,
# updates taps once (auto-update is disabled for the run for reproducibility),
# then installs (or reinstalls to track pins).
if [[ "${FARM_TRANSPORT:-ssh}" != "local" ]]; then
  echo "updating taps once (auto-update disabled for this run)..."
  if ! brew update </dev/null 2>&1 | sed 's/^/  brew-update: /'; then
    echo "error: brew update failed — cannot pin guest core to lock versions" >&2
    exit 1
  fi
  echo "seeding $FARM_TAP_NAME tap with shim-kegs..."
  _brew_repo="$(brew --repository </dev/null 2>/dev/null || true)"
  if [[ -z "$_brew_repo" ]]; then
    echo "error: brew --repository failed — cannot seed local tap" >&2
    exit 1
  fi
  # Tap dir follows brew's rule: short `<user>/<name>` <- dir
  # `<user>/homebrew-<name>`; TAP_REPO_NAME is the authoritative repo part.
  _tap_dir="$_brew_repo/Library/Taps/$TAP_USER/$TAP_REPO_NAME/Formula"
  mkdir -p "$_tap_dir"
  # Tap aliases (installs record tab.aliases from the installing tap; without
  # them e.g. opt/pkg-config is never created and superenv builds fail).
  if [[ -d "$VM_GUEST_SHARED/Aliases" ]]; then
    mkdir -p "${_tap_dir%/Formula}/Aliases"
    for _al in "$VM_GUEST_SHARED/Aliases/"*; do
      [[ -e "$_al" ]] || continue
      cp -P "$_al" "${_tap_dir%/Formula}/Aliases/" 2>&1 | sed 's/^/  alias: /' || true
    done
  fi
  for _shim in python@3.15 ruby swift; do
    _found=""
    for _cand in "$VM_GUEST_SHARED/Formula/$_shim.rb" "./Formula/$_shim.rb" "$SHARED_DIR/Formula/$_shim.rb"; do
      if [[ -f "$_cand" ]]; then _found="$_cand"; break; fi
    done
    if [[ -z "$_found" ]]; then
      echo "error: shim-keg source missing for $_shim (stage Formulae first)" >&2
      exit 1
    fi
    cp -v "$_found" "$_tap_dir/$_shim.rb" 2>&1 | sed 's/^/  seed: /' || {
      echo "error: could not stage $_shim into local tap" >&2
      exit 1
    }
    if brew list --versions "$FARM_TAP_NAME/$_shim" </dev/null >/dev/null 2>&1; then
      echo "reinstalling $FARM_TAP_NAME/$_shim (track pins)..."
      brew reinstall "$FARM_TAP_NAME/$_shim" </dev/null 2>&1 | tail -2 | sed 's/^/  shim: /' || {
        echo "error: reinstall $FARM_TAP_NAME/$_shim failed" >&2
        exit 1
      }
    else
      echo "installing $FARM_TAP_NAME/$_shim ..."
      brew install "$FARM_TAP_NAME/$_shim" </dev/null 2>&1 | tail -2 | sed 's/^/  shim: /' || {
        echo "error: install $FARM_TAP_NAME/$_shim failed" >&2
        exit 1
      }
    fi
  done
  # Bulk-seed the local tap with the FULL staged set (not just the queue):
  # skip-built-pruned deps resolve through $FARM_TAP_NAME too (stage 1c maps
  # the whole lock-resolved closure), and the guest tap must carry their
  # published bottle blocks — otherwise Tier-3 guests fall back to the core
  # API (no bottle: "must be built from source") or resolve live core
  # (version drift), and mixed core+tap objects for one rack self-deadlock
  # the keg lock (seen live: python-setuptools + shim python@3.15).
  # The tap is a cache rebuilt from staged files every run: wipe + recopy
  # so no stale entry shadows the current staged set. Per-formula overlay
  # in the loop below re-copies identical files (plus per-formula tap-files).
  echo "seeding $FARM_TAP_NAME tap with all staged Formulae..."
  _seed_dir="$_brew_repo/Library/Taps/$TAP_USER/$TAP_REPO_NAME/Formula"
  mkdir -p "$_seed_dir"
  find "$_seed_dir" -maxdepth 1 -name '*.rb' -delete
  _seeded=0
  for _seed_src in "$VM_GUEST_SHARED/Formula/"*.rb ./Formula/*.rb "$SHARED_DIR/Formula/"*.rb; do
    [[ -e "$_seed_src" ]] || continue
    cp -P "$_seed_src" "$_seed_dir/" 2>/dev/null || true
  done
  # Count distinct basenames actually present (globs above overlap).
  _seeded=$(ls "$_seed_dir/"*.rb 2>/dev/null | wc -l | tr -d ' ')
  echo "  seeded $_seeded formulae into $FARM_TAP_NAME"
  if [[ "$_seeded" -eq 0 ]]; then
    echo "error: staged Formulae missing — cannot seed local tap (run shared-sync/stage first)" >&2
    exit 1
  fi
fi

mkdir -p "$OUTPUT_DIR"
# Disk guard (M2): fail fast when the bottle volume is nearly full, before
# burning build time. Threshold is env-overridable (GB).
if ! [[ "$FARM_MIN_DISK_GB" =~ ^[0-9]+$ ]]; then
  echo "error: FARM_MIN_DISK_GB must be a number (got '$FARM_MIN_DISK_GB')" >&2
  exit 1
fi
_free_kb="$(df -k "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if [[ -n "$_free_kb" && "$_free_kb" -lt $(( FARM_MIN_DISK_GB * 1024 * 1024 )) ]]; then
  echo "error: free space below guard (${FARM_MIN_DISK_GB}GB) on the bottle volume — free $(df -h "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2 {print $4}') — clean up or lower FARM_MIN_DISK_GB" >&2
  exit 1
fi
echo "disk guard ok (free $(df -h "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2 {print $4}') on the bottle volume, guard ${FARM_MIN_DISK_GB}GB)"
# brew bottle writes its tarball+JSON to the CURRENT directory, so work there.
cd "$OUTPUT_DIR"
echo "=== build.sh ==="
echo "tag: $TAG"
echo "queue: $QUEUE_FILE ($QUEUE_COUNT)"
echo "output: $OUTPUT_DIR"
echo "root_url base: ${ROOT_URL:-per-formula (releases/download/<formula>-<version>)}"
echo "toolchain: rust=${TOOLCHAIN_RUST_PIN:-none} $(cargo --version 2>/dev/null || echo 'no cargo') | go=${TOOLCHAIN_GO_PIN:-none} $(go version 2>/dev/null || echo 'no go') | python=${TOOLCHAIN_PYTHON_PIN:-none} $(/usr/bin/python3 --version 2>&1 || echo 'no python')"
echo "brew config:"
brew config | sed 's/^/  /' || true
echo ""

# Ensure gnu-tar for bottle if needed (bottle.rb:gnu_tar_formula_ensure_installed)
if ! brew list gnu-tar >/dev/null 2>&1; then
  echo "note: gnu-tar not installed — bottle will use system tar (may be ok), installing gnu-tar is recommended"
fi

FAILED=()
BUILT=()
SKIPPED=()
# Loop accounting (M2 fail-closed): the queue is read on fd 3 so no
# in-loop command can swallow queue lines via stdin; READ_COUNT must
# match the file's line count or the run aborts instead of silently
# under-building.
READ_COUNT=0
EXPECTED_LINES=$(awk 'END{print NR}' "$QUEUE_FILE")

while IFS= read -r formula <&3 || [[ -n "$formula" ]]; do
  [[ -z "$formula" ]] && continue
  READ_COUNT=$((READ_COUNT + 1))
  # Staged overlay first (lock-pinned): the resume expectation below must be
  # read from the pinned staged Formula, never from live core. Guest runs
  # `brew update` once at bootstrap, so a short-name `brew info $formula`
  # drifts hourly past the host lock — reseeded lock-built artifacts would
  # always look stale. Querying $FARM_TAP_NAME/$formula keeps resume, skew
  # gate, and lock on the same version.
  # If a patched Formula exists (host mirrored + apply-patches), prefer it (B1)
  # Check staged guest dir, cwd, host shared mirror, and repo in order
  local_formula=""
  for cand in "$VM_GUEST_SHARED/Formula/$formula.rb" "./Formula/$formula.rb" "$SHARED_DIR/Formula/$formula.rb"; do
    if [[ -f "$cand" ]]; then
      local_formula="$cand"
      break
    fi
  done
  # Also check repo root if we are on host
  if [[ -z "$local_formula" && -f "$(dirname "$0")/../Formula/$formula.rb" ]]; then
    local_formula="$(dirname "$0")/../Formula/$formula.rb"
  fi

  brew_install_target="$formula"
  if [[ -n "$local_formula" ]]; then
    # Modern brew is API-only (no local core checkout) and rejects
    # `install <file>` outside a tap, so serve the mirrored/patched Formula
    # through a local tap and install by fully-qualified name.
    # (The tap is a cache: rebuilt from the staged Formulae each run.)
    # Tap dir follows brew's rule (see shim bootstrap above).
    tap_dir="$(brew --repository </dev/null 2>/dev/null)/Library/Taps/$TAP_USER/$TAP_REPO_NAME"
    if [[ -n "$tap_dir" ]]; then
      if grep -q "brew-bottle-farm" "$local_formula" 2>/dev/null; then
        echo "overlaying patched Formula into local tap: $FARM_TAP_NAME/$formula"
      else
        echo "overlaying mirrored Formula into local tap: $FARM_TAP_NAME/$formula"
      fi
      mkdir -p "$tap_dir/Formula"
      cp "$local_formula" "$tap_dir/Formula/$formula.rb"
      brew_install_target="$FARM_TAP_NAME/$formula"
      # In-tap files: brew resolves `file "Patches/..."` refs relative to
      # the tap root, so overlay each referenced file from the staged
      # tap-files dir (mirrored by orchestrate 1d). Fail the formula closed
      # when a referenced file is missing — otherwise the build fails
      # obscurely mid-install ("Patch file does not exist").
      _tap_refs=$(grep -o -E 'file "Patches/[^"]+"' "$tap_dir/Formula/$formula.rb" 2>/dev/null | sed -E 's/^file "//; s/"$//' | sort -u || true)
      if [[ -n "$_tap_refs" ]]; then
        _tap_ref_missing=""
        while IFS= read -r _rel; do
          [[ -z "$_rel" ]] && continue
          _src=""
          for _tfd in "$VM_GUEST_SHARED/tap-files/$_rel" "./tap-files/$_rel" "$SHARED_DIR/tap-files/$_rel" "$(dirname "$0")/../tap-files/$_rel"; do
            if [[ -f "$_tfd" ]]; then _src="$_tfd"; break; fi
          done
          if [[ -z "$_src" ]]; then
            echo "error: $formula references in-tap file $_rel but it is not staged (orchestrate 1d mirrors it to tap-files/)" >&2
            _tap_ref_missing="true"
            continue
          fi
          mkdir -p "$tap_dir/$(dirname "$_rel")"
          cp "$_src" "$tap_dir/$_rel"
          echo "  staged tap file: $_rel"
        done <<< "$_tap_refs"
        if [[ -n "$_tap_ref_missing" ]]; then
          FAILED+=("$formula")
          continue
        fi
      fi
    else
      echo "warn: brew --repository failed — installing $formula from core (unpatched)" >&2
    fi
  fi

  # Expected bottle version from the pinned overlay target (not live core):
  # needed both for resume matching and root_url.
  read -r stable_version pkg_revision <<< "$(brew info --json=v2 --formula "$brew_install_target" </dev/null 2>/dev/null | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); f=d['formulae'][0] if d['formulae'] else {}; print(f.get('versions',{}).get('stable','unknown'), f.get('revision',0))" 2>/dev/null || echo "unknown 0")"
  if [[ -z "${stable_version:-}" ]]; then stable_version="unknown"; fi
  if [[ -z "${pkg_revision:-}" ]]; then pkg_revision="0"; fi
  expected_pkg="$stable_version"
  if [[ "$pkg_revision" != "0" ]]; then expected_pkg="${stable_version}_${pkg_revision}"; fi
  # Resume (M2): bottle artifacts already collected — skip the rebuild, but
  # only when the artifact version matches the pinned expectation (a lock bump
  # must rebuild, never silently collect a stale bottle).
  if [[ "$FARM_RESUME" == "1" ]]; then
    shopt -s nullglob
    _tars=("$OUTPUT_DIR/$formula--"*.bottle.tar.gz)
    _jsons=("$OUTPUT_DIR/$formula--"*.json)
    shopt -u nullglob
    if [[ ${#_tars[@]} -gt 0 && ${#_jsons[@]} -gt 0 ]]; then
      _aver="${_tars[0]##*/$formula--}"
      _aver="${_aver%%.$TAG.bottle.tar.gz}"
      if [[ "$_aver" == "$expected_pkg" ]]; then
        echo "resume: $formula $expected_pkg artifacts already in $OUTPUT_DIR — skipping"
        SKIPPED+=("$formula")
        continue
      else
        echo "resume: $formula artifacts version $_aver != expected $expected_pkg — rebuilding (dropping stale)"
        rm -f "$OUTPUT_DIR/$formula--"*.bottle.tar.gz "$OUTPUT_DIR/$formula--"*.json 2>/dev/null || true
      fi
    fi
  fi
  echo "======================================================================"
  echo "Building $formula (--build-bottle, tag $TAG)"
  echo "======================================================================"

  # Clean previous install to ensure --build-bottle picks up correct deps.
  # Host additive-only: remember a pre-existing keg so the post-build
  # uninstall below can be undone (FARM_RESTORE_KEGS=1, set by --local).
  _was_installed="false"
  if brew list --versions "$formula" </dev/null >/dev/null 2>&1; then _was_installed="true"; fi
  brew uninstall --force "$formula" </dev/null 2>/dev/null || true

  # Determine per-formula root_url (version computed above, before resume).
  # Precedence: --root-url flag > TAP_ROOT_URL env (tap repo, from
  # orchestrate.sh via TAP_REPO) > git inference (last resort: yields the
  # *farm* repo on the host and nothing on the guest).
  if [[ -n "$ROOT_URL" ]]; then
    per_formula_root="$ROOT_URL"
  elif [[ -n "${TAP_ROOT_URL:-}" ]]; then
    _tap_base="${TAP_ROOT_URL%/}"
    per_formula_root="$_tap_base/${formula}-${stable_version}"
  else
    # Infer repo again inside VM
    remote=$(git config --get remote.origin.url 2>/dev/null || echo "")
    if [[ "$remote" =~ github.com[:/]([^/]+)/([^/.]+) ]]; then
      gh_user="${BASH_REMATCH[1]}"
      gh_repo="${BASH_REMATCH[2]%.git}"
      per_formula_root="https://github.com/$gh_user/$gh_repo/releases/download/${formula}-${stable_version}"
    else
      # fallback: placeholder (fail visibly, not silently)
      per_formula_root="https://github.com/USER/homebrew-tap/releases/download/${formula}-${stable_version}"
      echo "warn: could not infer GitHub repo, using placeholder $per_formula_root — set TAP_ROOT_URL env or --root-url" >&2
    fi
  fi
  echo "root_url: $per_formula_root"

  # Overlay already staged above (before resume) — brew_install_target is set.

  # NOTE: no --env flag here: per-command --env is disabled in current brew.
  # Formulae needing passthrough env declare `env :std` via their B1 patch
  # (the VM image/snapshot is our hermeticity boundary, not the sandbox).
  set +e
  brew install --build-bottle "$brew_install_target" </dev/null 2>&1 | tee "$BUILD_LOG_DIR/build-$formula.log"
  build_status=${PIPESTATUS[0]}
  set -e
  if [[ $build_status -ne 0 ]]; then
    echo "error: brew install --build-bottle $formula ($brew_install_target) failed (see $BUILD_LOG_DIR/build-$formula.log)" >&2
    FAILED+=("$formula")
    continue
  fi

  # Version-skew gate: the installed keg must match the expected pkg version
  # (stable_revision). A stale overlaid Formula would otherwise bottle the
  # wrong version silently (lock says .59, keg is .58).
  installed_pkg=$(brew list --versions "$formula" </dev/null 2>/dev/null | awk '{print $2}' || echo "")
  if [[ -z "$installed_pkg" ]]; then
    echo "error: $formula installed but no keg version found" >&2
    FAILED+=("$formula")
    continue
  fi
  if [[ "$installed_pkg" != "$expected_pkg" ]]; then
    echo "error: version skew: installed $formula $installed_pkg != expected $expected_pkg (stale overlay?)" >&2
    FAILED+=("$formula")
    continue
  fi

  # Generate bottle JSON + tarball
  # --json writes <formula>--<version>.<tag>.bottle.json and the .tar.gz
  set +e
  brew bottle --json "$formula" --root-url="$per_formula_root" </dev/null 2>&1 | tee "$BUILD_LOG_DIR/bottle-$formula.log"
  bottle_status=${PIPESTATUS[0]}
  set -e
  if [[ $bottle_status -ne 0 ]]; then
    echo "error: brew bottle --json $formula failed" >&2
    FAILED+=("$formula")
    # keep installed for debugging
    continue
  fi

  # Normalize the JSON top key to the short formula name: brew keys it by the
  # fully-qualified tap name (e.g. lurepheonix/intel/fd), but publish.sh
  # derives release tags and tarball globs from a short key (fd). Filenames
  # stay as-is (publish.sh already globs the `fd--<version>` double-dash form).
  json_files=(./"$formula"--*.json)
  if ((${#json_files[@]})); then
    # NOTE: absolute /usr/bin/python3 — bare `python3` may resolve to an asdf
    # shim whose version lookup depends on cwd (fails inside the bottle dir).
    /usr/bin/python3 - "${json_files[0]}" "$formula" <<'PYEOF'
import json, sys
path, short = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
if short not in d:
    long = [k for k in d if "/" in k and k.rsplit("/", 1)[-1] == short]
    if long:
        d[short] = d.pop(long[0])
with open(path, 'w') as f:
    json.dump(d, f, indent=2, sort_keys=True)
    f.write('\n')
print('normalized bottle JSON key -> ' + short + ' (' + path + ')')
PYEOF
  fi

  # Linkage gate (M2): the installed keg must not leak external toolchain
  # paths. Legit brew deps under $BREW_PREFIX are fine (bottled themselves);
  # $HOME/sandbox paths (rustup/cargo/asdf/uv) are not.
  echo "linkage check: brew linkage --test + otool leak scan"
  if ! brew linkage --test "$formula" </dev/null > "$BUILD_LOG_DIR/linkage-$formula.log" 2>&1; then
    echo "error: brew linkage --test $formula failed:" >&2
    cat "$BUILD_LOG_DIR/linkage-$formula.log" 2>/dev/null | sed 's/^/  linkage: /' >&2
    FAILED+=("$formula")
    continue  # keep installed for debugging
  fi
  echo "  linkage --test clean"
  keg_prefix="$(brew --prefix "$formula" </dev/null 2>/dev/null || true)"
  leak_found="false"
  if [[ -n "$keg_prefix" && -d "$keg_prefix" ]]; then
    while IFS= read -r mfile; do
      bad="$(otool -L "$mfile" 2>/dev/null | grep -E "/Users/|/private/tmp/|$VM_GUEST_SHARED|/\.cargo/|/\.rustup/|/\.asdf/|/\.local/" || true)"
      if [[ -n "$bad" ]]; then
        echo "error: external toolchain leak in $mfile:" >&2
        echo "$bad" | sed 's/^/  leak: /' >&2
        leak_found="true"
      fi
    done < <(find "$keg_prefix/bin" "$keg_prefix/lib" -type f 2>/dev/null || true)
  else
    echo "error: keg prefix not found for $formula ($keg_prefix)" >&2
    leak_found="true"
  fi
  if [[ "$leak_found" == "true" ]]; then
    FAILED+=("$formula")
    continue  # keep installed for debugging
  fi
  echo "  otool leak scan clean"

  # Collect artifacts
  # brew bottle outputs files in cwd, typically ./<formula>--<version>.<tag>.bottle*.tar.gz and .json
  shopt -s nullglob
  artifacts=(./"$formula"--*.bottle*.tar.gz ./"$formula"--*.json)
  shopt -u nullglob
  if [[ ${#artifacts[@]} -eq 0 ]]; then
    echo "warn: no bottle artifacts found for $formula in $(pwd)" >&2
    ls -lh ./*.tar.gz ./*.json 2>&1 | sed 's/^/  /' || true
    FAILED+=("$formula")
    continue
  fi
  for f in "${artifacts[@]}"; do
    if [[ "$PWD" != "$OUTPUT_DIR" ]]; then
      mv -v "$f" "$OUTPUT_DIR/"
    else
      echo "  artifact already in $OUTPUT_DIR: $f"
    fi
  done

  # Verify bottle
  for tar in "$OUTPUT_DIR"/"$formula"--*.bottle*.tar.gz; do
    echo "verifying $tar"
    tar tzf "$tar" | head -n 20 | sed 's/^/  /' || true
  done

  # Keep-installed: each bottled formula stays for downstream queue entries
  # (the old "uninstall each, reinstall deps from bottle" assumed pourable
  # core bottles — false on Tier-3 guests). Single cleanup at the end instead.
  if [[ "$FARM_KEEP_INSTALLED" == "1" ]]; then
    echo "  keep-installed: leaving $formula installed for downstream formulae"
  else
    brew uninstall --force "$formula" </dev/null 2>/dev/null || true
  fi
  # M2: prune stale downloads between formulae (VM path only — the host cache
  # belongs to the user; orchestrate --local sets FARM_CLEANUP=0).
  if [[ "$FARM_CLEANUP" == "1" ]]; then
    brew cleanup </dev/null 2>/dev/null || true
  fi
  # Host additive-only: a keg this build took down gets reinstalled, so a
  # local dry run never leaves the host worse than it found it.
  if [[ "$FARM_RESTORE_KEGS" == "1" && "$_was_installed" == "true" ]]; then
    if brew list --versions "$formula" </dev/null >/dev/null 2>&1; then
      echo "  pre-existing $formula still installed — leaving it"
    elif brew install "$formula" </dev/null >/dev/null 2>&1; then
      echo "  restored pre-existing $formula"
    else
      echo "warn: could not restore pre-existing $formula — reinstall it manually" >&2
    fi
  fi
  BUILT+=("$formula")
  echo "ok: $formula bottled"

done 3< "$QUEUE_FILE"

echo ""
echo "=== summary ==="
echo "queue lines consumed: $READ_COUNT (expected $EXPECTED_LINES)"
echo "built: ${#BUILT[@]}"
if ((${#BUILT[@]})); then printf "  %s\n" "${BUILT[@]}" | sed 's/^/  + /'; fi
echo "skipped (resume): ${#SKIPPED[@]}"
if ((${#SKIPPED[@]})); then printf "  %s\n" "${SKIPPED[@]}" | sed 's/^/  = /'; fi
echo "failed: ${#FAILED[@]}"
if ((${#FAILED[@]})); then printf "  %s\n" "${FAILED[@]}" | sed 's/^/  ✗ /'; fi
echo "artifacts in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR" 2>&1 | sed 's/^/  /' || true

PROCESSED=$((${#BUILT[@]} + ${#SKIPPED[@]} + ${#FAILED[@]}))
if [[ "$READ_COUNT" -ne "$EXPECTED_LINES" ]]; then
  echo "error: build loop consumed $READ_COUNT of $EXPECTED_LINES queue lines — stdin leak, refusing silent under-build" >&2
  exit 1
fi
if [[ "$PROCESSED" -ne "$QUEUE_COUNT" ]]; then
  echo "error: classified $PROCESSED of $QUEUE_COUNT queued formulae (built+skipped+failed)" >&2
  exit 1
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "some formulae failed — check $BUILD_LOG_DIR/build-*.log and $BUILD_LOG_DIR/bottle-*.log" >&2
  exit 1
fi

# End-of-run cleanup (VM path only): the per-formula uninstall is skipped
# under FARM_KEEP_INSTALLED, so remove everything built in one go, in
# reverse topo order. Local builds keep results on the consumer machine.
if [[ "$FARM_END_CLEANUP" == "1" && ${#BUILT[@]} -gt 0 ]]; then
  echo "end-of-run cleanup: uninstalling ${#BUILT[@]} built formulae + brew cleanup"
  i=$((${#BUILT[@]} - 1))
  while [[ "$i" -ge 0 ]]; do
    brew uninstall --force "${BUILT[$i]}" </dev/null 2>/dev/null || true
    i=$((i - 1))
  done
  brew cleanup </dev/null 2>/dev/null || true
fi
