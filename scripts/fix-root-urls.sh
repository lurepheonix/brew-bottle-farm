#!/usr/bin/env bash
set -euo pipefail

# fix-root-urls.sh — rewrite placeholder bottle root_urls to the real tap repo.
# Usage: ./scripts/fix-root-urls.sh [--dry-run] [--bottles-dir ./bottles]
#
# Mechanical, SHA-safe salvage for bottles built before TAP_ROOT_URL wiring:
# only the `root_url` / file `url` string prefixes change
# (USER/homebrew-tap -> <TAP_REPO>); tarballs and their sha256 are untouched.
# Version-skewed bottles still need a rebuild (see build.sh skew gate) —
# this script fixes URLs only, never versions.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOTTLES_DIR="$ROOT_DIR/bottles"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --bottles-dir) BOTTLES_DIR="$2"; shift 2 ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/fix-root-urls.sh [--dry-run] [--bottles-dir ./bottles]

  Rewrites placeholder https://github.com/USER/homebrew-tap/ URL prefixes in
  bottles/*.json to https://github.com/<TAP_REPO>/ (from .env TAP_REPO).
  SHA-safe: tarballs and sha256 fields are never touched.
  Only the USER/homebrew-tap placeholder prefix is replaced; anything else
  (e.g. farm-toolchain's farm-repo URL) is left alone.
EOF
      exit 0 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done

if [[ -f "$ROOT_DIR/.env" ]]; then
  _tap_from_env=$(grep -E '^TAP_REPO=' "$ROOT_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- || true)
  _tap_from_env="${_tap_from_env%\"}"; _tap_from_env="${_tap_from_env#\"}"
  _tap_from_env="${_tap_from_env%\'}"; _tap_from_env="${_tap_from_env#\'}"
  if [[ -n "${_tap_from_env:-}" && -z "${TAP_REPO:-}" ]]; then
    TAP_REPO="$_tap_from_env"
  fi
fi
if [[ -z "${TAP_REPO:-}" ]]; then
  echo "error: TAP_REPO must be set (.env or env) — refusing to guess the release target" >&2
  exit 1
fi

PLACEHOLDER="https://github.com/USER/homebrew-tap/"
REAL="https://github.com/${TAP_REPO}/"

jsons=("$BOTTLES_DIR"/*.json)
if [[ ! -e "${jsons[0]}" ]]; then
  echo "error: no bottle JSONs in $BOTTLES_DIR" >&2
  exit 1
fi

# shellcheck disable=SC2016
python3 - "$BOTTLES_DIR" "$PLACEHOLDER" "$REAL" "$DRY_RUN" <<'PYEOF'
import glob, json, os, sys
bdir, placeholder, real, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "true"
rewritten, clean, skipped = [], [], []
for path in sorted(glob.glob(os.path.join(bdir, "*.json"))):
    with open(path) as f:
        try:
            d = json.load(f)
        except Exception as e:
            print(f"error: {path}: bad JSON ({e})", file=sys.stderr)
            sys.exit(1)
    text = json.dumps(d)
    if placeholder not in text:
        clean.append(os.path.basename(path))
        continue
    # Fail closed on unexpected URL shapes: only the placeholder prefix may change.
    fixed = text.replace(placeholder, real)
    if "USER/homebrew-tap" in fixed:
        print(f"error: {path}: unrecognized placeholder variant left after rewrite", file=sys.stderr)
        sys.exit(1)
    name = os.path.basename(path)
    if dry:
        rewritten.append(name + " (preview)")
        continue
    with open(path, "w") as f:
        json.dump(json.loads(fixed), f, indent=2, sort_keys=True)
        f.write("\n")
    rewritten.append(name)
print(f"tap: {real}<formula>-<version>")
print(f"rewrote placeholder -> tap in {len(rewritten)} JSONs:")
for n in rewritten:
    print(f"  + {n}")
print(f"already clean: {len(clean)}")
for n in clean:
    print(f"  = {n}")
PYEOF
