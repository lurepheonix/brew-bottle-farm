#!/usr/bin/env bash
set -euo pipefail

# build.sh — runs INSIDE the Parallels VM (macOS Sequoia, /usr/local)
# Usage: ./scripts/build.sh [build-queue.txt] [--tag sequoia] [--root-url URL]
#
# For each formula in queue:
#   brew uninstall --force (clean)
#   brew install --build-bottle
#   brew bottle --json --root-url=...
# Collects *.bottle.tar.gz + *.json into $OUTPUT_DIR (default: ./bottles or /tmp/shared/bottles)

TAG="${TAG:-sequoia}"
ROOT_URL="${ROOT_URL:-}"
OUTPUT_DIR="${OUTPUT_DIR:-./bottles}"
QUEUE_FILE="${1:-./build-queue.txt}"

# Parse opts
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --root-url) ROOT_URL="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/build.sh [build-queue.txt] [--tag sequoia] [--root-url URL] [--output-dir ./bottles]
  Runs inside VM. Requires brew, CLT, Xcode.
  --root-url: override bottle root_url (default: https://github.com/<user>/homebrew-intel/releases/download/<formula>-<version>)
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

# Source external toolchain if provisioned (rustup + go + asdf python)
TOOLCHAIN_ENV="${TOOLCHAIN_ENV:-/tmp/shared/toolchain.env}"
if [[ -f "$TOOLCHAIN_ENV" ]]; then
  echo "sourcing toolchain $TOOLCHAIN_ENV"
  # shellcheck disable=SC1090
  source "$TOOLCHAIN_ENV" || true
elif [[ -f "./toolchain.env" ]]; then
  echo "sourcing toolchain ./toolchain.env"
  # shellcheck disable=SC1090
  source "./toolchain.env" || true
fi
# Pre-flight: if any queued formula is patched to use external rust/go, assert toolchain present
if [[ -n "${TOOLCHAIN_RUST_PIN:-}" ]] && ! command -v cargo >/dev/null 2>&1; then
  echo "warn: TOOLCHAIN_RUST_PIN=$TOOLCHAIN_RUST_PIN but cargo not on PATH — patched formulae needing rust will fail" >&2
fi
if [[ -n "${TOOLCHAIN_GO_PIN:-}" ]] && ! command -v go >/dev/null 2>&1 && [[ ! -x "${GOROOT:-/usr/local/go}/bin/go" ]]; then
  echo "warn: TOOLCHAIN_GO_PIN=$TOOLCHAIN_GO_PIN but go not on PATH" >&2
fi

mkdir -p "$OUTPUT_DIR"
echo "=== build.sh ==="
echo "tag: $TAG"
echo "queue: $QUEUE_FILE ($QUEUE_COUNT)"
echo "output: $OUTPUT_DIR"
echo "root_url base: ${ROOT_URL:-per-formula (releases/download/<formula>-<version>)}"
echo "toolchain: rust=${TOOLCHAIN_RUST_PIN:-none} $(cargo --version 2>/dev/null || echo 'no cargo') | go=${TOOLCHAIN_GO_PIN:-none} $(go version 2>/dev/null || echo 'no go') | python=${TOOLCHAIN_PYTHON_PIN:-none} $(python3 --version 2>&1 || echo 'no python')"
echo "brew config:"
brew config | sed 's/^/  /' || true
echo ""

# Ensure gnu-tar for bottle if needed (bottle.rb:gnu_tar_formula_ensure_installed)
if ! brew list gnu-tar >/dev/null 2>&1; then
  echo "note: gnu-tar not installed — bottle will use system tar (may be ok), installing gnu-tar is recommended"
fi

FAILED=()
BUILT=()

while IFS= read -r formula; do
  [[ -z "$formula" ]] && continue
  echo "======================================================================"
  echo "Building $formula (--build-bottle, tag $TAG)"
  echo "======================================================================"

  # Clean previous install to ensure --build-bottle picks up correct deps
  brew uninstall --force "$formula" 2>/dev/null || true
  # Don't cleanup all — keep deps bottled as they are dependencies for next formula (but ensure we built them first via toposort)

  # Determine per-formula root_url and version for naming
  # We need version before build for root_url, but version may change after brew update; use stable from brew info
  stable_version=$(brew info --json=v2 --formula "$formula" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['formulae'][0]['versions']['stable'] if d['formulae'] else '')" 2>/dev/null || echo "unknown")
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
  # Check shared dir, repo Formula, and current dir in order
  local_formula=""
  for cand in "/tmp/shared/Formula/$formula.rb" "./Formula/$formula.rb" "$HOME/Parallels/shared-brew/Formula/$formula.rb"; do
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
    # Check if local file is patched (contains brew-bottle-farm marker) — if so, use it
    if grep -q "brew-bottle-farm" "$local_formula" 2>/dev/null; then
      echo "using patched Formula: $local_formula"
      brew_install_target="$local_formula"
    elif [[ -f "$local_formula" ]]; then
      # Even if not obviously patched, prefer local if it exists and is newer than core
      echo "using local Formula: $local_formula (may be patched or mirrored)"
      # Only use local if it differs from core (to avoid stale mirror)
      # Compare core formula vs local — if local is same as brew cat, still ok to use local
      brew_install_target="$local_formula"
    fi
  fi

  set +e
  brew install --build-bottle "$brew_install_target" 2>&1 | tee "/tmp/build-$formula.log"
  build_status=${PIPESTATUS[0]}
  set -e
  if [[ $build_status -ne 0 ]]; then
    echo "error: brew install --build-bottle $formula ($brew_install_target) failed (see /tmp/build-$formula.log)" >&2
    FAILED+=("$formula")
    continue
  fi

  # Generate bottle JSON + tarball
  # --json writes <formula>--<version>.<tag>.bottle.json and the .tar.gz
  set +e
  brew bottle --json "$formula" --root-url="$per_formula_root" 2>&1 | tee "/tmp/bottle-$formula.log"
  bottle_status=${PIPESTATUS[0]}
  set -e
  if [[ $bottle_status -ne 0 ]]; then
    echo "error: brew bottle --json $formula failed" >&2
    FAILED+=("$formula")
    # keep installed for debugging
    continue
  fi

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
    mv -v "$f" "$OUTPUT_DIR/"
  done

  # Verify bottle
  for tar in "$OUTPUT_DIR"/"$formula"--*.bottle*.tar.gz; do
    echo "verifying $tar"
    tar tzf "$tar" | head -n 20 | sed 's/^/  /' || true
  done

  # Uninstall to keep VM clean for next formula (deps already built due to toposort, will be reinstalled from bottle if needed)
  brew uninstall --force "$formula" 2>/dev/null || true
  BUILT+=("$formula")
  echo "ok: $formula bottled"

done < "$QUEUE_FILE"

echo ""
echo "=== summary ==="
echo "built: ${#BUILT[@]}"
printf "  %s\n" "${BUILT[@]}" | sed 's/^/  + /' || true
echo "failed: ${#FAILED[@]}"
printf "  %s\n" "${FAILED[@]}" | sed 's/^/  ✗ /' || true
echo "artifacts in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR" 2>&1 | sed 's/^/  /' || true

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "some formulae failed — check /tmp/build-*.log and /tmp/bottle-*.log inside VM" >&2
  exit 1
fi
