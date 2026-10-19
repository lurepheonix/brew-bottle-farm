#!/usr/bin/env bash
set -euo pipefail

# Host JSON helper: plain python3 only — never the VM's asdf slots.
# The repo .tool-versions pins VM-only interpreters; if the asdf shim
# cannot satisfy them on this host, drop it so brewed/system python3 is used.
if ! python3 -c 'pass' >/dev/null 2>&1; then
  PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '/\.asdf/shims' | paste -sd: -)"
fi

# publish.sh — host side: upload bottles to GitHub Releases and merge bottle DSL into Formulae
# Usage: ./scripts/publish.sh [--dry-run] [--skip-release] [--bottles-dir ./bottles]
#
# Expects:
#   bottles/*.tar.gz + bottles/*.json produced by build.sh (inside VM, scp'd to host)
#   Formula/ contains mirrored formulae (copied from homebrew/core via sync)
# Does:
#   1. gh release create <formula>-<version> <tar.gz> (per-formula versioned tag)
#   2. brew bottle --merge <json> --write --no-commit to inject bottle block
#   3. git add + commit

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOTTLES_DIR="${BOTTLES_DIR:-$ROOT_DIR/bottles}"
FORMULA_DIR="$ROOT_DIR/Formula"
DRY_RUN="false"
SKIP_RELEASE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --skip-release) SKIP_RELEASE="true"; shift ;;
    --bottles-dir) BOTTLES_DIR="$2"; shift 2 ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/publish.sh [--dry-run] [--skip-release] [--bottles-dir ./bottles]
  --dry-run      preview without gh release / git commit
  --skip-release skip gh release (only merge bottle DSL)
EOF
      exit 0 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$BOTTLES_DIR" ]]; then
  echo "error: bottles dir not found: $BOTTLES_DIR" >&2
  exit 1
fi

# Find jsons
jsons=("$BOTTLES_DIR"/*.json)
if [[ ! -e "${jsons[0]}" ]]; then
  echo "error: no bottle JSONs in $BOTTLES_DIR" >&2
  echo "hint: run ./scripts/vm.sh shared-sync first to stage bottles into host $BOTTLES_DIR" >&2
  exit 1
fi
echo "found ${#jsons[@]} bottle JSONs"
printf "  %s\n" "${jsons[@]}"

# Group by formula name from JSON keys
# Each JSON is like {"formula": {"formula": {...}, "bottle": {...}}}
# Use brew bottle --merge to handle correctly, but for releases we need per-formula tag

# Ensure Formula dir has mirrored formulae for each bottled formula
# If missing, copy from homebrew/core or brew cat
ensure_formula() {
  local name="$1"
  local dest="$FORMULA_DIR/$name.rb"
  if [[ -f "$dest" ]]; then
    return 0
  fi
  echo "mirroring Formula/$name.rb from homebrew/core..."
  mkdir -p "$FORMULA_DIR"
  # Prefer local core tap
  if [[ -f "/usr/local/Homebrew/Library/Taps/homebrew/homebrew-core/Formula/${name:0:1}/$name.rb" ]]; then
    cp "/usr/local/Homebrew/Library/Taps/homebrew/homebrew-core/Formula/${name:0:1}/$name.rb" "$dest"
  elif brew cat "$name" >/dev/null 2>&1; then
    brew cat "$name" > "$dest"
  else
    # Search via glob
    src=$(find /usr/local/Homebrew -name "$name.rb" 2>/dev/null | head -n 1 || true)
    if [[ -n "$src" ]]; then
      cp "$src" "$dest"
    else
      echo "warn: could not mirror $name, will skip merge for this formula" >&2
      return 1
    fi
  fi
}

for json in "${jsons[@]}"; do
  formula=$(python3 -c "import json; print(list(json.load(open('$json')).keys())[0])" 2>/dev/null || basename "$json" | cut -d- -f1)
  ensure_formula "$formula" || true
done

# Releases
if [[ "$SKIP_RELEASE" != "true" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh CLI not found (brew install gh, then gh auth login)" >&2
    exit 1
  fi
  # Need git repo + remote
  if ! git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: not a git repo: $ROOT_DIR" >&2
    exit 1
  fi
  for json in "${jsons[@]}"; do
    formula=$(python3 -c "import json; print(list(json.load(open('$json')).keys())[0])" 2>/dev/null || echo "")
    if [[ -z "$formula" ]]; then continue; fi
    version=$(python3 -c "import json; d=json.load(open('$json')); k=list(d.keys())[0]; print(d[k]['formula']['version'])" 2>/dev/null || echo "")
    if [[ -z "$version" ]]; then
      version=$(python3 -c "import json; d=json.load(open('$json')); k=list(d.keys())[0]; print(d[k]['formula']['pkg_version'])" 2>/dev/null || echo "unknown")
    fi
    tag="${formula}-${version}"
    # Find matching tarballs for this formula+version
    tars=("$BOTTLES_DIR"/"$formula"--*.bottle*.tar.gz)
    if [[ ! -e "${tars[0]}" ]]; then
      echo "warn: no tarballs for $formula, skipping release" >&2
      continue
    fi
    echo "=== release $tag ==="
    printf "  tars: %s\n" "${tars[@]}"
    echo "  json: $json"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [dry-run] would: gh release create $tag ${tars[*]} $json --title \"$formula $version (sequoia)\" --notes \"Bottle for $formula $version — tag sequoia — built via brew-bottle-farm\""
      continue
    fi
    # Create or upload to existing release
    if gh release view "$tag" >/dev/null 2>&1; then
      echo "  release $tag exists — uploading/clobbering assets"
      gh release upload "$tag" "${tars[@]}" "$json" --clobber
    else
      gh release create "$tag" "${tars[@]}" "$json" --title "$formula $version (sequoia)" --notes "Bottle for $formula $version — tag sequoia — built via brew-bottle-farm. Install: brew tap <user>/intel && brew install <user>/intel/$formula" --latest=false
    fi
  done
else
  echo "[skip-release] skipping gh releases"
fi

# Merge bottle DSL
echo "merging bottle DSL into Formula/*.rb via brew bottle --merge"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] would: brew bottle --merge ${jsons[*]} --write --no-commit"
  # Show preview without writing: brew bottle --merge prints to stdout? Use --write dry-run manually
  for json in "${jsons[@]}"; do
    echo "  json $json:"
    cat "$json" | python3 -m json.tool | sed 's/^/    /' | head -n 40
  done
  exit 0
fi

# brew bottle --merge expects JSONs and writes into Formula files
# Must be run from repo root with Formula/ layout
# We pass all jsons at once to merge multi-formula correctly
# Need to ensure we are in API-disabled mode? brew bottle is dev-cmd, needs --no-commit handling
brew bottle --merge "${jsons[@]}" --write --no-commit

echo "merged bottle blocks:"
git -C "$ROOT_DIR" diff --stat | sed 's/^/  /'
git -C "$ROOT_DIR" diff | head -n 200 | sed 's/^/  /' || true

# Commit
if git -C "$ROOT_DIR" diff --quiet; then
  echo "no Formula changes to commit"
else
  git -C "$ROOT_DIR" add Formula/
  # Also add lock if needed? publish is usually after sync, lock already committed, but include
  if git -C "$ROOT_DIR" diff --cached --quiet; then
    echo "no staged changes"
  else
    commit_msg="bottles: $(basename -a "${jsons[@]}" | sed 's/--.*//' | sort -u | tr '\n' ' ' | sed 's/ $//') (sequoia)"
    echo "committing: $commit_msg"
    git -C "$ROOT_DIR" commit -m "$commit_msg" --no-verify
    echo "push with: git push"
    echo "hint: git push origin HEAD"
  fi
fi

echo "publish done. Next: git push && brew tap <user>/tap && brew install <user>/tap/<formula>"
