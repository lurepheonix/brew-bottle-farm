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
TAG="${TAG:-sequoia}"
DRY_RUN="false"
SKIP_RELEASE="false"
PUSH="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --skip-release) SKIP_RELEASE="true"; shift ;;
    --push) PUSH="true"; shift ;;
    --bottles-dir) BOTTLES_DIR="$2"; shift 2 ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/publish.sh [--dry-run] [--skip-release] [--push] [--bottles-dir ./bottles]

Env (repo-root .env, gitignored, also honored — non-secrets only):
  TAP_REPO=<user>/homebrew-intel (required for real runs; releases
    target. Never inferred from cwd — gh would otherwise publish into the
    farm repo instead of the tap.)
  GH_TOKEN env always wins for auth; else FARM_TOKEN_FILE (600/400 file
    holding the token) or Keychain item FARM_TOKEN_KEYCHAIN_ITEM
    (default farm-tap-token). Never `gh auth login`, never tokens in .env.

  --dry-run      preview without gh release / git commit
  --skip-release skip gh release (only merge bottle DSL)
  --push         push the tap checkout after merging (default: print hint only)
EOF
      exit 0 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done

# Local config (non-secrets only): repo-root .env, gitignored. Only known keys
# imported — .env is sourced, so anything else in it is ignored, not executed.
if [[ -f "$ROOT_DIR/.env" ]]; then
  if grep -Eq 'ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|gho_[A-Za-z0-9]+' "$ROOT_DIR/.env"; then
    echo "error: .env appears to contain a token — secrets stay out of the repo" >&2
    echo "hint: Keychain item or 600-file outside the repo; .env holds pointers only" >&2
    exit 1
  fi
  while IFS='=' read -r key val; do
    [[ "$key" =~ ^[A-Za-z_]+$ ]] || continue
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    case "$key" in
      TAP_REPO|FARM_TOKEN_FILE|FARM_TOKEN_KEYCHAIN_ITEM) export "$key=$val" ;;
    esac
  done < <(grep -E '^[A-Za-z_]+=' "$ROOT_DIR/.env" || true)
fi

# Explicit release target (fail closed — never guess; the tap repo is a
# different repo than this farm checkout, and gh defaults to cwd's origin).
if [[ -z "${TAP_REPO:-}" ]]; then
  if [[ "$DRY_RUN" == "true" || "$SKIP_RELEASE" == "true" ]]; then
    echo "warn: TAP_REPO unset — dry-run/skip-release preview only, no releases" >&2
    TAP_REPO="<tap-repo-unset>"
  else
    echo "error: TAP_REPO must be set (e.g. TAP_REPO=<user>/homebrew-intel)" >&2
    echo "hint: releases must land in the tap repo, never in this farm checkout" >&2
    exit 1
  fi
fi
# Derive consumer shorthand: <user>/homebrew-intel -> <user>/intel.
TAP_USER="${TAP_REPO%%/*}"
TAP_REPO_NAME="${TAP_REPO##*/}"
TAP_SHORT="$TAP_REPO"
if [[ "$TAP_REPO_NAME" == homebrew-* ]]; then
  TAP_SHORT="$TAP_USER/${TAP_REPO_NAME#homebrew-}"
fi

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

# Resolve the release token. Precedence: GH_TOKEN env → FARM_TOKEN_FILE
# (must be 600/400) → macOS Keychain item. Value never printed or logged.
resolve_gh_token() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "  token: GH_TOKEN from environment" >&2
    return 0
  fi
  if [[ -n "${FARM_TOKEN_FILE:-}" ]]; then
    if [[ ! -f "$FARM_TOKEN_FILE" ]]; then
      echo "error: FARM_TOKEN_FILE not found: $FARM_TOKEN_FILE" >&2
      return 1
    fi
    local perms
    perms=$(stat -f %Lp "$FARM_TOKEN_FILE" 2>/dev/null || echo "???")
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
      echo "error: FARM_TOKEN_FILE is mode $perms — must be 600 (or 400)" >&2
      echo "hint: chmod 600 $FARM_TOKEN_FILE" >&2
      return 1
    fi
    GH_TOKEN="$(cat "$FARM_TOKEN_FILE")"
    export GH_TOKEN
    echo "  token: file $FARM_TOKEN_FILE" >&2
    return 0
  fi
  local item="${FARM_TOKEN_KEYCHAIN_ITEM:-farm-tap-token}"
  local tok
  tok="$(security find-generic-password -s "$item" -w 2>/dev/null || true)"
  if [[ -n "$tok" ]]; then
    GH_TOKEN="$tok"
    export GH_TOKEN
    echo "  token: Keychain item $item" >&2
    return 0
  fi
  echo "error: no release token found (GH_TOKEN, FARM_TOKEN_FILE, Keychain item $item all empty/missing)" >&2
  echo "hint: fine-grained PAT (single tap repo, Contents read+write) in Keychain:" >&2
  echo "hint:   security add-generic-password -s $item -a <user> -w" >&2
  echo "hint: or point FARM_TOKEN_FILE at a 600 file outside the repo" >&2
  return 1
}

# Releases
if [[ "$SKIP_RELEASE" != "true" ]]; then
  if [[ "$DRY_RUN" != "true" ]] && ! command -v gh >/dev/null 2>&1; then
    echo "error: gh CLI not found" >&2
    echo "hint: install the farm-built bottle (brew install <tap>/gh once published)" >&2
    echo "hint: or bootstrap one-off from ./bottles, then supply GH_TOKEN per-command" >&2
    exit 1
  fi
  if [[ "$DRY_RUN" != "true" ]]; then
    resolve_gh_token || exit 1
  fi
  # Need git repo + remote
  if ! git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: not a git repo: $ROOT_DIR" >&2
    exit 1
  fi
  for json in "${jsons[@]}"; do
    formula=$(python3 -c "import json; print(list(json.load(open('$json')).keys())[0])" 2>/dev/null || echo "")
    if [[ -z "$formula" ]]; then continue; fi
    short="${formula##*/}"
    version=$(python3 -c "import json; d=json.load(open('$json')); k=list(d.keys())[0]; print(d[k]['formula'].get('pkg_version') or d[k]['formula'].get('version'))" 2>/dev/null || echo "")
    if [[ -z "$version" ]]; then
      version="unknown"
    fi
    tag="${short}-${version}"
    # Find matching tarballs for this formula+version
    tars=("$BOTTLES_DIR"/"$short"--*.bottle*.tar.gz)
    if [[ ! -e "${tars[0]}" ]]; then
      echo "warn: no tarballs for $short, skipping release" >&2
      continue
    fi
    # Stage upload assets under their REMOTE names: brew downloads
    # <root_url>/<name>-<pkg_version>.<tag>.bottle.tar.gz (single dash,
    # revision included), but local files use the double-dash form.
    # Uploading local names as-is 404s every pour (seen live with fd).
    stage_tmp=$(mktemp -d /tmp/farm-publish-stage.XXXXXX)
    staged=()
    for _t in "${tars[@]}" "$json"; do
      _bn="$(basename "$_t")"
      _remote="${_bn/#$short--/$short-}"
      cp "$_t" "$stage_tmp/$_remote"
      staged+=("$stage_tmp/$_remote")
    done
    echo "=== release $tag ==="
    printf "  tars: %s\n" "${tars[@]}"
    echo "  json: $json"
    echo "  remote names: $(cd "$stage_tmp" && echo *)"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [dry-run] would: gh release create $tag ${staged[*]} --repo $TAP_REPO --title \"$short $version ($TAG)\" --notes \"Bottle for $short $version — tag $TAG — built via brew-bottle-farm\""
      rm -rf "$stage_tmp"
      continue
    fi
    # Create or upload to existing release (explicit --repo: never cwd's origin)
    if gh release view "$tag" --repo "$TAP_REPO" >/dev/null 2>&1; then
      echo "  release $tag exists — uploading/clobbering assets"
      gh release upload "$tag" "${staged[@]}" --repo "$TAP_REPO" --clobber
    else
      gh release create "$tag" "${staged[@]}" --repo "$TAP_REPO" --title "$short $version ($TAG)" --notes "Bottle for $short $version — tag $TAG — built via brew-bottle-farm. Install: brew tap $TAP_SHORT && brew install $TAP_SHORT/$short" --latest=false
    fi
    rm -rf "$stage_tmp"
  done
else
  echo "[skip-release] skipping gh releases"
fi

# Bottled set (short names from JSON keys) — the closed mapping set for the
# dep rewrite below. Externals never appear here (never bottled).
bottled_names=$(python3 -c "
import json, glob
names = set()
for j in glob.glob('$BOTTLES_DIR/*.json'):
    try:
        d = json.load(open(j))
        for k in d.keys():
            names.add(k.split('/')[-1])
    except Exception:
        pass
print(' '.join(sorted(names)))
" 2>/dev/null || true)
# Merge bottle DSL — into the TAP checkout, not the farm tree.
# `brew bottle --merge` resolves formulae through taps and only writes into
# a checked-out tap; short keys hit API-only core ("No available formula").
# So: ensure the tap is tapped + trusted, copy staged Formulae in, merge
# with LONG-keyed JSON copies, then copy merged files back to the farm tree
# (keeps the farm working copies in sync for the farm-repo commit below).
echo "merging bottle DSL into tap checkout via brew bottle --merge"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] would: brew tap $TAP_SHORT; brew trust $TAP_SHORT; copy bottled Formulae; brew bottle --merge <long-keyed JSONs> --write --no-commit"
  # Show preview without writing: brew bottle --merge prints to stdout? Use --write dry-run manually
  for json in "${jsons[@]}"; do
    echo "  json $json:"
    cat "$json" | python3 -m json.tool | sed 's/^/    /' | head -n 40 || true
  done
  # Preview the dep rewrite (no writes in dry-run): placeholder refs plus any
  # bare bottled-dep refs that would be tap-qualified.
  echo "[dry-run] would rewrite deps -> $TAP_SHORT/ in bottled Formulae:"
  grep -rhn 'farm/local/' "$FORMULA_DIR" --include='*.rb' 2>/dev/null | sed 's/^/    /' | head -n 10 || echo "    (no farm/local/ refs found)"
  for _n in $bottled_names; do
    grep -rhn --include='*.rb' -E "depends_on +\"$_n\"|Formula\\[\"$_n\"\\]" "$FORMULA_DIR" 2>/dev/null | grep -v "$TAP_SHORT/" | sed 's/^/    /' | head -n 5 || true
  done
  exit 0
fi

echo "ensuring tap $TAP_SHORT is tapped + trusted..."
brew tap "$TAP_SHORT" 2>&1 | sed 's/^/  tap: /' || {
  echo "error: brew tap $TAP_SHORT failed" >&2
  exit 1
}
brew trust "$TAP_SHORT" 2>&1 | sed 's/^/  trust: /' || true
TAP_DIR="$(brew --repository "$TAP_SHORT" 2>/dev/null || true)"
if [[ -z "$TAP_DIR" || ! -d "$TAP_DIR/Formula" ]]; then
  echo "error: tap dir not found for $TAP_SHORT (expected brew --repository output/Formula)" >&2
  exit 1
fi
echo "  tap dir: $TAP_DIR"
for _n in $bottled_names; do
  if [[ -f "$FORMULA_DIR/$_n.rb" ]]; then
    cp "$FORMULA_DIR/$_n.rb" "$TAP_DIR/Formula/$_n.rb"
  else
    echo "warn: staged Formula missing for $_n — merge will use tap's copy" >&2
  fi
done
# Long-keyed JSON copies for merge (short keys resolve to unwritable core).
merge_tmp=$(mktemp -d /tmp/farm-publish-merge.XXXXXX)
merge_jsons=()
for json in "${jsons[@]}"; do
  python3 - "$json" "$TAP_SHORT" "$merge_tmp" <<'PYEOF'
import json, os, sys
src, tap, dest = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    d = json.load(f)
out = {}
for k, v in d.items():
    short = k.split("/")[-1]
    out[f"{tap}/{short}"] = v
name = [k.split("/")[-1] for k in d.keys()][0]
path = os.path.join(dest, name + ".bottle.json")
with open(path, "w") as f:
    json.dump(out, f, indent=2, sort_keys=True)
    f.write("\n")
print(path)
PYEOF
done > "$merge_tmp/list.txt" || {
  echo "error: could not prepare long-keyed merge JSONs" >&2
  rm -rf "$merge_tmp"
  exit 1
}
merge_jsons=()
while IFS= read -r _mj || [[ -n "$_mj" ]]; do
  [[ -z "$_mj" ]] && continue
  merge_jsons+=("$_mj")
done < "$merge_tmp/list.txt"
if [[ ${#merge_jsons[@]} -eq 0 || ! -e "${merge_jsons[0]}" ]]; then
  echo "error: no merge JSONs prepared" >&2
  rm -rf "$merge_tmp"
  exit 1
fi
# brew bottle --merge expects JSONs and writes into the tap checkout's files.
# We pass all jsons at once to merge multi-formula correctly.
brew bottle --merge "${merge_jsons[@]}" --write --no-commit
rm -rf "$merge_tmp"

# Dep rewrite for self-containment: every bottled dep must resolve within the
# tap (Tier-3 consumers get no core bottles at all). Runs against the TAP
# checkout files (the published artifacts). Two passes over the
# bottled set only:
#   (i)  builder placeholder `farm/local/X` -> `<tap>/X` (safety net; the
#        stage step already maps these, so this is normally a no-op), then
#   (ii) bare `depends_on "N"` / `Formula["N"]` -> tap-qualified for every
#        bottled N — comments skipped, scope suffixes preserved.
# External build tools (rust/go/...) are never bottled, so they can never
# map; consumers install prebuilt bottles and need no toolchain. Shim refs
# (`<tap>/python@3.15`, `<tap>/ruby`) have no bottled provider — intentionally
# left for the publish-time shim decision (see plan).
echo "rewriting deps -> $TAP_SHORT/ in tap bottled Formulae"
python3 - "$TAP_DIR/Formula" "$TAP_SHORT" "$bottled_names" <<'PYEOF'
import os, re, sys
fdir, tap, names = sys.argv[1], sys.argv[2], sys.argv[3].split()
touched = 0
for n in names:
    rb = os.path.join(fdir, n + ".rb")
    if not os.path.isfile(rb):
        continue
    with open(rb) as f:
        lines = f.readlines()
    out, changed = [], False
    for line in lines:
        if "farm/local/" in line:
            line = line.replace("farm/local/", tap + "/")
            changed = True
        if not line.lstrip().startswith("#"):
            if re.search(r'depends_on\s+"' + re.escape(n) + r'"', line):
                line = re.sub(r'(depends_on\s+")' + re.escape(n) + r'"', r"\1" + tap + "/" + n + '"', line)
                changed = True
            if re.search(r'Formula\["' + re.escape(n) + r'"\]', line):
                line = re.sub(r'Formula\["' + re.escape(n) + r'"\]', f'Formula["{tap}/{n}"]', line)
                changed = True
        out.append(line)
    if changed:
        with open(rb, "w") as f:
            f.writelines(out)
        print(f"  rewrote {n}.rb")
        touched += 1
print(f"dep rewrite done ({touched} bottled Formulae touched)")
PYEOF

# Copy merged formulae back to the farm working tree (keeps farm in sync;
# the farm-repo commit below covers them as usual).
for _n in $bottled_names; do
  if [[ -f "$TAP_DIR/Formula/$_n.rb" ]]; then
    cp "$TAP_DIR/Formula/$_n.rb" "$FORMULA_DIR/$_n.rb"
  fi
done

echo "tap checkout state:"
git -C "$TAP_DIR" status --short | sed 's/^/  /' || true

if [[ "$PUSH" == "true" ]]; then
  if [[ -z "${GH_TOKEN:-}" ]]; then
    resolve_gh_token || exit 1
  fi
  echo "pushing tap checkout..."
  git -C "$TAP_DIR" add Formula/
  if git -C "$TAP_DIR" diff --cached --quiet; then
    echo "  tap checkout: no changes to push"
  else
    git -C "$TAP_DIR" -c user.name="brew-bottle-farm" -c user.email="farm@localhost" commit -m "bottles: $bottled_names ($TAG)" --no-verify --quiet
    git -C "$TAP_DIR" push "https://oauth2:${GH_TOKEN}@github.com/${TAP_REPO}.git" HEAD:main 2>&1 | sed 's/^/  push: /' || {
      echo "error: tap push failed" >&2
      exit 1
    }
  fi
else
  echo "tap checkout updated (not pushed — rerun with --push, or push manually from $TAP_DIR)"
fi

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

echo "publish done. Next: git push && brew tap $TAP_SHORT && brew install $TAP_SHORT/<formula>"
