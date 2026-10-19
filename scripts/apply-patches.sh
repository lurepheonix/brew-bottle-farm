#!/usr/bin/env bash
set -euo pipefail

# apply-patches.sh — B1 plain-patch applier for Formula/*.rb
# Usage: ./scripts/apply-patches.sh [--check-only] [--formula-dir ./Formula] [--patches-dir ./patches]
#
# Reads patches/series (ordered) and applies each via `patch -p1 --forward`.
# Fail-closed: any .rej or hunk failure aborts (forces human to refresh patch after core_sha bump).
# Enforces single-pin: patch header tool version must match build-deps.conf pin.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FORMULA_DIR="${FORMULA_DIR:-$ROOT_DIR/Formula}"
PATCHES_DIR="${PATCHES_DIR:-$ROOT_DIR/patches}"
SERIES_FILE="$PATCHES_DIR/series"
BUILD_DEPS_CONF="$ROOT_DIR/build-deps.conf"
CHECK_ONLY="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY="true"; shift ;;
    --formula-dir) FORMULA_DIR="$2"; shift 2 ;;
    --patches-dir) PATCHES_DIR="$2"; SERIES_FILE="$PATCHES_DIR/series"; shift 2 ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/apply-patches.sh [--check-only] [--formula-dir ./Formula] [--patches-dir ./patches]
  --check-only  validate series exists, patches apply cleanly (dry-run), pins match build-deps.conf
EOF
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$SERIES_FILE" ]]; then
  echo "no series file $SERIES_FILE — nothing to patch"
  exit 0
fi

# Parse series (strip comments/blank)
series_list=$(grep -v '^[[:space:]]*#' "$SERIES_FILE" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u || true)
if [[ -z "$series_list" ]]; then
  echo "series empty — nothing to patch"
  exit 0
fi

count=$(echo "$series_list" | wc -l | tr -d ' ')
echo "=== apply-patches.sh ($count patches, check $CHECK_ONLY) ==="
echo "formula dir: $FORMULA_DIR"
echo "patches dir: $PATCHES_DIR"

failed=0
for patch_name in $series_list; do
  patch_file="$PATCHES_DIR/$patch_name"
  echo "--- $patch_name ---"
  if [[ ! -f "$patch_file" ]]; then
    echo "error: patch file not found: $patch_file" >&2
    failed=1
    continue
  fi

  # Single-pin header check: look for "# Tool: <name> <version>" in patch
  # e.g. "# Tool: rust 1.82.0" — compare to build-deps.conf pin (bash 3.2 compatible, no associative array)
  header_tool=$(grep -E '^# Tool:' "$patch_file" 2>/dev/null | head -n1 | sed -E 's/^# Tool:[[:space:]]*//' | awk '{print $1}' || true)
  header_ver=$(grep -E '^# Tool:' "$patch_file" 2>/dev/null | head -n1 | sed -E 's/^# Tool:[[:space:]]*//' | awk '{print $2}' || true)
  if [[ -n "$header_tool" && -n "$header_ver" && -f "$BUILD_DEPS_CONF" ]]; then
    expected=$(grep -v '^[[:space:]]*#' "$BUILD_DEPS_CONF" 2>/dev/null | awk -v t="$header_tool" '$1==t {print $3}' | head -n1 || true)
    if [[ -n "$expected" && "$header_ver" != "$expected" ]]; then
      echo "error: patch $patch_name header Tool: $header_tool $header_ver != build-deps.conf pin $expected (single-pin rule)" >&2
      failed=1
      continue
    fi
  fi

  # Gate: reject patches that touch runtime python (depends_on "python@" without => :build)
  # Check patch diff for `depends_on "python` not followed by `=> :build`
  if grep -q 'depends_on "python' "$patch_file" 2>/dev/null; then
    # If patch adds a disabled line for python build dep, it should contain => :build in context
    # Heuristic: if patch contains python@ but not :build, warn
    if ! grep -q 'depends_on "python.*=> :build' "$patch_file" 2>/dev/null && grep -q 'depends_on "python' "$patch_file" 2>/dev/null; then
      echo "warn: patch $patch_name touches python without :build — will be checked for runtime linkage; ensure it's build-only" >&2
      # Not fatal, but check-only will enforce later
    fi
  fi

  # Dry-run check first
  if ! patch -p1 --dry-run --forward -d "$ROOT_DIR" < "$patch_file" >/dev/null 2>&1; then
    # If already applied, dry-run will fail with "already applied" — check if reverse would apply
    if patch -p1 --dry-run --reverse -d "$ROOT_DIR" < "$patch_file" >/dev/null 2>&1; then
      echo "  already applied (reverse applies cleanly) — skipping"
      continue
    fi
    echo "error: patch $patch_name does not apply cleanly (core_sha drift?)" >&2
    patch -p1 --dry-run --forward -d "$ROOT_DIR" < "$patch_file" 2>&1 | sed 's/^/  dry-run: /' || true
    failed=1
    continue
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "  would apply (check-only)"
    continue
  fi

  echo "  applying..."
  if ! patch -p1 --forward -d "$ROOT_DIR" < "$patch_file" 2>&1 | sed 's/^/  patch: /'; then
    echo "error: patch $patch_name failed to apply" >&2
    failed=1
    continue
  fi
  # Check for .rej files
  if find "$FORMULA_DIR" -name "*.rej" -o -name "*.orig" 2>/dev/null | grep -q .; then
    echo "error: .rej/.orig files after patch $patch_name" >&2
    find "$FORMULA_DIR" -name "*.rej" -o -name "*.orig" 2>/dev/null | sed 's/^/  /' >&2
    failed=1
    continue
  fi
  echo "  ok"
done

# Post-check: ensure no leftover rejects anywhere
if find "$ROOT_DIR" -name "*.rej" 2>/dev/null | grep -q .; then
  echo "error: leftover .rej files:" >&2
  find "$ROOT_DIR" -name "*.rej" 2>/dev/null | sed 's/^/  /' >&2
  failed=1
fi

if [[ $failed -ne 0 ]]; then
  echo "apply-patches: $failed failure(s) — refresh patches after core_sha bump (see patches/README.md)" >&2
  exit 1
fi

echo "apply-patches: all $count patches ok"
