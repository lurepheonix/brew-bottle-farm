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
  Env: FARM_RESUME FARM_CLEANUP FARM_RESTORE_KEGS FARM_MIN_DISK_GB BREW_PREFIX
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

# Determine repo for root_url if not given
if [[ -z "$ROOT_URL" ]]; then
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
# Fresh registry per build: the sandbox forbids writes to the shared
# ~/.cargo (each build re-fetches the index into its own TMPDIR).
export CARGO_HOME="\${TMPDIR:-/tmp}/farm-cargo"
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

while IFS= read -r formula; do
  [[ -z "$formula" ]] && continue
  # Resume (M2): bottle artifacts already collected — skip the rebuild.
  if [[ "$FARM_RESUME" == "1" ]] && ls "$OUTPUT_DIR/$formula--"*.bottle.tar.gz >/dev/null 2>&1 && ls "$OUTPUT_DIR/$formula--"*.json >/dev/null 2>&1; then
    echo "resume: $formula artifacts already in $OUTPUT_DIR — skipping"
    SKIPPED+=("$formula")
    continue
  fi
  echo "======================================================================"
  echo "Building $formula (--build-bottle, tag $TAG)"
  echo "======================================================================"

  # Clean previous install to ensure --build-bottle picks up correct deps.
  # Host additive-only: remember a pre-existing keg so the post-build
  # uninstall below can be undone (FARM_RESTORE_KEGS=1, set by --local).
  _was_installed="false"
  if brew list --versions "$formula" >/dev/null 2>&1; then _was_installed="true"; fi
  brew uninstall --force "$formula" 2>/dev/null || true

  # Determine per-formula root_url and version for naming
  # We need version before build for root_url, but version may change after brew update; use stable from brew info
  stable_version=$(brew info --json=v2 --formula "$formula" 2>/dev/null | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d['formulae'][0]['versions']['stable'] if d['formulae'] else '')" 2>/dev/null || echo "unknown")
  if [[ -z "$ROOT_URL" ]]; then
    # Infer repo again inside VM
    remote=$(git config --get remote.origin.url 2>/dev/null || echo "")
    if [[ "$remote" =~ github.com[:/]([^/]+)/([^/.]+) ]]; then
      gh_user="${BASH_REMATCH[1]}"
      gh_repo="${BASH_REMATCH[2]%.git}"
      per_formula_root="https://github.com/$gh_user/$gh_repo/releases/download/${formula}-${stable_version}"
    else
      # fallback: require env TAP_ROOT_URL
      per_formula_root="${TAP_ROOT_URL:-https://github.com/USER/homebrew-tap/releases/download/${formula}-${stable_version}}"
      echo "warn: could not infer GitHub repo, using placeholder $per_formula_root — set TAP_ROOT_URL env or --root-url" >&2
    fi
  else
    per_formula_root="$ROOT_URL"
  fi
  echo "root_url: $per_formula_root"

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
    # Note: tap `farm/local` lives in dir `farm/homebrew-local` (prefix rule).
    tap_dir="$(brew --repository 2>/dev/null)/Library/Taps/farm/homebrew-local"
    if [[ -n "$tap_dir" ]]; then
      if grep -q "brew-bottle-farm" "$local_formula" 2>/dev/null; then
        echo "overlaying patched Formula into local tap: farm/local/$formula"
      else
        echo "overlaying mirrored Formula into local tap: farm/local/$formula"
      fi
      mkdir -p "$tap_dir/Formula"
      cp "$local_formula" "$tap_dir/Formula/$formula.rb"
      brew_install_target="farm/local/$formula"
    else
      echo "warn: brew --repository failed — installing $formula from core (unpatched)" >&2
    fi
  fi

  # NOTE: no --env flag here: per-command --env is disabled in current brew.
  # Formulae needing passthrough env declare `env :std` via their B1 patch
  # (the VM image/snapshot is our hermeticity boundary, not the sandbox).
  set +e
  brew install --build-bottle "$brew_install_target" 2>&1 | tee "$BUILD_LOG_DIR/build-$formula.log"
  build_status=${PIPESTATUS[0]}
  set -e
  if [[ $build_status -ne 0 ]]; then
    echo "error: brew install --build-bottle $formula ($brew_install_target) failed (see $BUILD_LOG_DIR/build-$formula.log)" >&2
    FAILED+=("$formula")
    continue
  fi

  # Generate bottle JSON + tarball
  # --json writes <formula>--<version>.<tag>.bottle.json and the .tar.gz
  set +e
  brew bottle --json "$formula" --root-url="$per_formula_root" 2>&1 | tee "$BUILD_LOG_DIR/bottle-$formula.log"
  bottle_status=${PIPESTATUS[0]}
  set -e
  if [[ $bottle_status -ne 0 ]]; then
    echo "error: brew bottle --json $formula failed" >&2
    FAILED+=("$formula")
    # keep installed for debugging
    continue
  fi

  # Normalize the JSON top key to the short formula name: brew keys it by the
  # fully-qualified tap name (farm/local/fd), but publish.sh derives release
  # tags and tarball globs from a short key (fd). Filenames stay as-is
  # (publish.sh already globs the `fd--<version>` double-dash form).
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
    long = [k for k in d if k == 'farm/local/' + short]
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
  if ! brew linkage --test "$formula" > "$BUILD_LOG_DIR/linkage-$formula.log" 2>&1; then
    echo "error: brew linkage --test $formula failed:" >&2
    cat "$BUILD_LOG_DIR/linkage-$formula.log" 2>/dev/null | sed 's/^/  linkage: /' >&2
    FAILED+=("$formula")
    continue  # keep installed for debugging
  fi
  echo "  linkage --test clean"
  keg_prefix="$(brew --prefix "$formula" 2>/dev/null || true)"
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

  # Uninstall to keep the machine clean for next formula (deps already built due to toposort, will be reinstalled from bottle if needed)
  brew uninstall --force "$formula" 2>/dev/null || true
  # M2: prune stale downloads between formulae (VM path only — the host cache
  # belongs to the user; orchestrate --local sets FARM_CLEANUP=0).
  if [[ "$FARM_CLEANUP" == "1" ]]; then
    brew cleanup 2>/dev/null || true
  fi
  # Host additive-only: a keg this build took down gets reinstalled, so a
  # local dry run never leaves the host worse than it found it.
  if [[ "$FARM_RESTORE_KEGS" == "1" && "$_was_installed" == "true" ]]; then
    if brew list --versions "$formula" >/dev/null 2>&1; then
      echo "  pre-existing $formula still installed — leaving it"
    elif brew install "$formula" >/dev/null 2>&1; then
      echo "  restored pre-existing $formula"
    else
      echo "warn: could not restore pre-existing $formula — reinstall it manually" >&2
    fi
  fi
  BUILT+=("$formula")
  echo "ok: $formula bottled"

done < "$QUEUE_FILE"

echo ""
echo "=== summary ==="
echo "built: ${#BUILT[@]}"
if ((${#BUILT[@]})); then printf "  %s\n" "${BUILT[@]}" | sed 's/^/  + /'; fi
echo "skipped (resume): ${#SKIPPED[@]}"
if ((${#SKIPPED[@]})); then printf "  %s\n" "${SKIPPED[@]}" | sed 's/^/  = /'; fi
echo "failed: ${#FAILED[@]}"
if ((${#FAILED[@]})); then printf "  %s\n" "${FAILED[@]}" | sed 's/^/  ✗ /'; fi
echo "artifacts in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR" 2>&1 | sed 's/^/  /' || true

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "some formulae failed — check $BUILD_LOG_DIR/build-*.log and $BUILD_LOG_DIR/bottle-*.log" >&2
  exit 1
fi
