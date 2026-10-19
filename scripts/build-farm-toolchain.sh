#!/usr/bin/env bash
set -euo pipefail
umask 022 # keep Cellar files group/world-readable like a normal brew install

# build-farm-toolchain.sh — own fast pipeline for the authored farm-toolchain formula.
# Usage: ./scripts/build-farm-toolchain.sh [--tag sequoia] [--output-dir ./bottles]
#
# Builds + bottles Formula/farm-toolchain.rb from the working tree (no release
# tarball needed — the formula's url/sha256 placeholders are for the published
# tap; here the source is staged locally and checksummed on the fly).
# Fast by design: install only stages files + writes Cellar shims, so no
# provisioned toolchain is needed to build it.
# Location-agnostic (same env roots as build.sh). Runs on the host via
# `make farm-toolchain`, or in the VM. Fails closed on version drift
# (formula version must equal the build-deps.conf `farm-toolchain` pin).
# Publishes nothing — hand the artifacts to publish.sh when ready.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG="${TAG:-sequoia}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/bottles}"
BREW_PREFIX="${BREW_PREFIX:-/usr/local}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-/tmp}"
FARM_MIN_DISK_GB="${FARM_MIN_DISK_GB:-10}"
FORMULA="farm-toolchain"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/build-farm-toolchain.sh [--tag sequoia] [--output-dir ./bottles]
  Builds + bottles the authored farm-toolchain formula from the working tree.
  Fast: no provisioned toolchain needed (install only stages files + shims).
  Fails closed when the formula version drifts from the build-deps.conf pin.
  Env: TAG OUTPUT_DIR BREW_PREFIX BUILD_LOG_DIR FARM_MIN_DISK_GB
EOF
      exit 0 ;;
    --*) echo "unknown opt $1" >&2; exit 1 ;;
    *) echo "unknown arg $1 (queue files not supported — this builds one formula)" >&2; exit 1 ;;
  esac
done

export PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"

echo "=== build-farm-toolchain.sh ==="
echo "tag: $TAG"
echo "output: $OUTPUT_DIR"

# Single-pin rule: formula version == build-deps.conf pin (bump both together).
formula_version="$(grep -E '^[[:space:]]*version "' "$ROOT_DIR/Formula/$FORMULA.rb" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
conf_pin="$(grep -E "^$FORMULA[[:space:]]" "$ROOT_DIR/build-deps.conf" | awk '{print $3}')"
if [[ -z "$formula_version" || -z "$conf_pin" ]]; then
  echo "error: could not read farm-toolchain version (formula='$formula_version' conf='$conf_pin')" >&2
  exit 1
fi
if [[ "$formula_version" != "$conf_pin" ]]; then
  echo "error: farm-toolchain version drift: formula $formula_version != build-deps.conf $conf_pin" >&2
  echo "hint: bump both together (docs/stack.md version policy)" >&2
  exit 1
fi
echo "pin ok: $formula_version"

mkdir -p "$OUTPUT_DIR"
if ! [[ "$FARM_MIN_DISK_GB" =~ ^[0-9]+$ ]]; then
  echo "error: FARM_MIN_DISK_GB must be a number (got '$FARM_MIN_DISK_GB')" >&2
  exit 1
fi
_free_kb="$(df -k "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if [[ -n "$_free_kb" && "$_free_kb" -lt $(( FARM_MIN_DISK_GB * 1024 * 1024 )) ]]; then
  echo "error: free space below guard (${FARM_MIN_DISK_GB}GB) on the bottle volume" >&2
  exit 1
fi

# Resume: bottle already collected — nothing to do.
if ls "$OUTPUT_DIR/$FORMULA--"*.bottle.tar.gz >/dev/null 2>&1 && ls "$OUTPUT_DIR/$FORMULA--"*.json >/dev/null 2>&1; then
  echo "resume: $FORMULA artifacts already in $OUTPUT_DIR — skipping"
  exit 0
fi

# Stage source: the install block expects buildpath/scripts/toolchain.sh,
# buildpath/build-deps.conf, buildpath/.tool-versions.
stage="$(mktemp -d /tmp/farm-toolchain-src.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/src/scripts"
cp "$ROOT_DIR/scripts/toolchain.sh" "$stage/src/scripts/toolchain.sh"
cp "$ROOT_DIR/build-deps.conf" "$stage/src/build-deps.conf"
cp "$ROOT_DIR/.tool-versions" "$stage/src/.tool-versions"
tar -czf "$stage/src.tar.gz" -C "$stage/src" scripts/toolchain.sh build-deps.conf .tool-versions
src_sha="$(shasum -a 256 "$stage/src.tar.gz" | awk '{print $1}')"
echo "staged source: $stage/src.tar.gz ($src_sha)"

# Overlay a buildable copy of the formula (file:// url + real sha256) into a
# local tap. Same overlay pattern as build.sh (cache rebuilt every run).
tap_dir="$(brew --repository 2>/dev/null)/Library/Taps/farm/homebrew-local"
if [[ -z "$tap_dir" ]]; then
  echo "error: brew --repository failed" >&2
  exit 1
fi
mkdir -p "$tap_dir/Formula"
python3 - "$ROOT_DIR/Formula/$FORMULA.rb" "$tap_dir/Formula/$FORMULA.rb" "$stage/src.tar.gz" "$src_sha" <<'PYEOF'
import sys
src, dest, url, sha = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(src) as f:
    text = f.read()
lines = []
for line in text.splitlines(keepends=True):
    s = line.strip()
    if s.startswith('url '):
        lines.append(f'  url "file://{url}"\n')
    elif s.startswith('sha256 ') and '0000' in s:
        lines.append(f'  sha256 "{sha}"\n')
    else:
        lines.append(line)
with open(dest, 'w') as f:
    f.writelines(lines)
print('overlaid buildable formula -> ' + dest)
PYEOF

# Per-formula root_url (same inference as build.sh; placeholder when unknown —
# publish.sh records the real one at release time).
if [[ -z "${ROOT_URL:-}" ]]; then
  remote=$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || echo "")
  if [[ "$remote" =~ github.com[:/]([^/]+)/([^/.]+) ]]; then
    gh_user="${BASH_REMATCH[1]}"
    gh_repo="${BASH_REMATCH[2]%.git}"
    per_formula_root="https://github.com/$gh_user/$gh_repo/releases/download/${FORMULA}-${formula_version}"
  else
    per_formula_root="https://github.com/USER/homebrew-intel/releases/download/${FORMULA}-${formula_version}"
    echo "warn: no GitHub remote, using placeholder root_url" >&2
  fi
else
  per_formula_root="$ROOT_URL"
fi
echo "root_url: $per_formula_root"

brew uninstall --force "farm/local/$FORMULA" "$FORMULA" 2>/dev/null || true
set +e
brew install --build-bottle "farm/local/$FORMULA" 2>&1 | tee "$BUILD_LOG_DIR/build-$FORMULA.log"
build_status=${PIPESTATUS[0]}
set -e
if [[ $build_status -ne 0 ]]; then
  echo "error: brew install --build-bottle farm/local/$FORMULA failed (see $BUILD_LOG_DIR/build-$FORMULA.log)" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"
set +e
brew bottle --json "$FORMULA" --root-url="$per_formula_root" 2>&1 | tee "$BUILD_LOG_DIR/bottle-$FORMULA.log"
bottle_status=${PIPESTATUS[0]}
set -e
if [[ $bottle_status -ne 0 ]]; then
  echo "error: brew bottle --json $FORMULA failed" >&2
  exit 1
fi

# Normalize the JSON top key (brew keys it farm/local/<name>; publish.sh wants short).
/usr/bin/python3 - "${FORMULA}--"*".json" "$FORMULA" <<'PYEOF'
import glob, json, sys
short = sys.argv[-1]
paths = sorted(glob.glob(short + '--*.json'))
path = paths[0]
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

echo "linkage check: brew linkage --test"
if ! brew linkage --test "$FORMULA" > "$BUILD_LOG_DIR/linkage-$FORMULA.log" 2>&1; then
  echo "error: brew linkage --test $FORMULA failed:" >&2
  cat "$BUILD_LOG_DIR/linkage-$FORMULA.log" 2>/dev/null | sed 's/^/  linkage: /' >&2
  exit 1
fi
echo "  linkage --test clean"

shopt -s nullglob
artifacts=(./"$FORMULA"--*.bottle*.tar.gz ./"$FORMULA"--*.json)
shopt -u nullglob
if [[ ${#artifacts[@]} -eq 0 ]]; then
  echo "warn: no bottle artifacts for $FORMULA in $(pwd)" >&2
  exit 1
fi
for tar in ./"$FORMULA"--*.bottle*.tar.gz; do
  echo "verifying $tar"
  tar tzf "$tar" | head -n 20 | sed 's/^/  /' || true
done

brew uninstall --force "$FORMULA" 2>/dev/null || true
echo ""
echo "=== summary ==="
echo "  + $FORMULA $formula_version bottled"
echo "artifacts in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"/"$FORMULA"--* 2>&1 | sed 's/^/  /' || true
