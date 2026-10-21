#!/usr/bin/env bash
set -euo pipefail

# Host JSON helper: plain python3 only — never the VM's asdf slots.
if ! python3 -c 'pass' >/dev/null 2>&1; then
  PATH="$(echo "$PATH" | tr -d '\n' | tr ':' '\n' | grep -v '/\.asdf/shims' | paste -sd: -)"
fi

# skip-built.sh — prune the build queue against the tap (host-only).
# Usage: ./scripts/skip-built.sh [--dry-run] [--queue build-queue.txt] [--tag sequoia]
#
# For each queued formula, asks the TAP (what consumers see) instead of
# rebuilding blindly: skip when the tap already bottles the LOCKED version
# for our tag. No token needed (public tap read), never fails the run —
# on any doubt it prunes nothing and the build proceeds as before.
# Local bottles need not exist: the check is the tap DSL, and the guest
# reseed + version-aware resume handle the rest.
# Safe direction: exact version+tag match or keep queued.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
QUEUE_FILE="$ROOT_DIR/build-queue.txt"
LOCK_FILE="$ROOT_DIR/packages.lock.json"
TAG="${TAG:-sequoia}"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --queue) QUEUE_FILE="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/skip-built.sh [--dry-run] [--queue build-queue.txt] [--tag sequoia]
  Prune queued formulae the tap already bottles at the locked version.
  --dry-run   preview only, do not rewrite the queue file
  --queue     queue file to filter (default: ./build-queue.txt)
  --tag       bottle tag that must be present (default: sequoia)
  Env: TAP_REPO (to derive the tap name), TAP_SHORT (wins over TAP_REPO), TAG
EOF
      exit 0 ;;
    --*) echo "unknown arg $1" >&2; exit 1 ;;
    *) QUEUE_FILE="$1"; shift ;;
  esac
done

if [[ ! -f "$QUEUE_FILE" ]]; then
  echo "queue file not found: $QUEUE_FILE (nothing to prune)" >&2
  exit 0
fi
if [[ ! -f "$LOCK_FILE" ]]; then
  echo "warn: lock not found ($LOCK_FILE) — pruning nothing" >&2
  exit 0
fi

# Tap name: explicit TAP_SHORT wins, else derived from TAP_REPO the same
# way orchestrate.sh derives it (<user>/homebrew-intel -> <user>/intel).
if [[ -z "${TAP_SHORT:-}" ]]; then
  if [[ -z "${TAP_REPO:-}" ]]; then
    _tap_from_env="$(grep -E '^TAP_REPO=' "$ROOT_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    _tap_from_env="${_tap_from_env%\"}"; _tap_from_env="${_tap_from_env#\"}"
    _tap_from_env="${_tap_from_env%\'}"; _tap_from_env="${_tap_from_env#\'}"
    if [[ -n "${_tap_from_env:-}" ]]; then TAP_REPO="$_tap_from_env"; fi
  fi
  if [[ -z "${TAP_REPO:-}" ]]; then
    echo "warn: TAP_REPO/TAP_SHORT unset — cannot query the tap, pruning nothing" >&2
    echo "hint: set TAP_REPO in .env (e.g. TAP_REPO=<user>/homebrew-intel)" >&2
    exit 0
  fi
  TAP_USER="${TAP_REPO%%/*}"
  TAP_REPO_NAME="${TAP_REPO##*/}"
  TAP_SHORT="$TAP_REPO"
  if [[ "$TAP_REPO_NAME" == homebrew-* ]]; then
    TAP_SHORT="$TAP_USER/${TAP_REPO_NAME#homebrew-}"
  fi
fi

queue_list=$(grep -v '^[[:space:]]*$' "$QUEUE_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
if [[ -z "$queue_list" ]]; then
  echo "queue empty — nothing to prune"
  exit 0
fi
queue_count=$(echo "$queue_list" | wc -l | tr -d ' ')
echo "checking $queue_count queued formulae against tap $TAP_SHORT (tag $TAG)..."

# Per-formula tap queries (not one batch call): a single missing formula
# makes brew exit non-zero, which would discard every other answer.
# Cheap pre-filter first: only formulae with a .rb in the tap checkout can
# possibly be bottled — the rest stay queued with zero brew calls.
tap_formulas=""
if tap_dir="$(brew --repository "$TAP_SHORT" 2>/dev/null)" && [[ -d "$tap_dir/Formula" ]]; then
  tap_formulas="$(ls "$tap_dir/Formula" 2>/dev/null | sed 's/\.rb$//' || true)"
fi
info_tmp=$(mktemp -d /tmp/farm-skip-info.XXXXXX)
for _q in $queue_list; do
  if [[ -n "$tap_formulas" ]] && ! echo "$tap_formulas" | grep -qx "$_q"; then
    echo '{"formulae":[]}' > "$info_tmp/$_q.json"
    continue
  fi
  if brew info --json=v2 --formula "$TAP_SHORT/$_q" > "$info_tmp/$_q.json" 2>/dev/null; then
    : # ok
  else
    echo '{"formulae":[]}' > "$info_tmp/$_q.json"
  fi
done
info_json="$(python3 - "$info_tmp" <<'PYEOF'
import json, glob, os, sys
d = {"formulae": []}
for p in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        with open(p) as f:
            d["formulae"].extend(json.load(f).get("formulae", []))
    except Exception:
        pass
print(json.dumps(d))
PYEOF
)"
rm -rf "$info_tmp"

decide_tmp=$(mktemp)
echo "$info_json" > "$decide_tmp.info"
echo "$queue_list" > "$decide_tmp.queue"
python3 - "$decide_tmp.info" "$LOCK_FILE" "$TAG" "$decide_tmp.queue" <<'PYEOF' > "$decide_tmp.skipped" 2> "$decide_tmp.report"
import json, sys
info_path, lock_path, tag, queue_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(info_path) as f:
    info = json.load(f)
with open(lock_path) as f:
    lock = json.load(f)
with open(queue_path) as f:
    queue = [l.strip() for l in f if l.strip()]
resolved = lock.get("resolved", {})
by_short = {}
for x in info.get("formulae", []):
    full = x.get("name", "")
    short = full.split("/")[-1]
    stable = (x.get("versions") or {}).get("stable", "")
    rev = x.get("revision", 0) or 0
    pkg = stable if not rev else f"{stable}_{rev}"
    files = (((x.get("bottle") or {}).get("stable") or {}).get("files") or {})
    by_short[short] = (pkg, tag in files)
for short in queue:
    want = resolved.get(short)
    if want is None:
        print(f"  keep: {short} (not in lock — unusual, keeping)", file=sys.stderr)
        continue
    got, has_tag = by_short.get(short, (None, False))
    if got == want and has_tag:
        print(f"  skip: {short} {want} already bottled for {tag} in tap", file=sys.stderr)
        print(short)
    else:
        why = "not in tap" if got is None else f"tap has {got or '∅'}{'' if has_tag else ' (no ' + tag + ' bottle)'}"
        print(f"  keep: {short} (lock {want}; {why})", file=sys.stderr)
PYEOF
cat "$decide_tmp.report" | sed 's/^/  /' || true

# The keep-set: queue lines minus skipped (order preserved for toposort).
skipped=$(cat "$decide_tmp.skipped" 2>/dev/null || true)
if [[ -z "$skipped" ]]; then
  echo "nothing to prune (no queued formula bottled in tap at lock version)"
  rm -f "$decide_tmp" "$decide_tmp.info" "$decide_tmp.queue" "$decide_tmp.skipped" "$decide_tmp.report"
  exit 0
fi
echo "$skipped" | sed 's/^/  already bottled, pruning: /'
kept_tmp=$(mktemp)
while IFS= read -r q; do
  [[ -z "$q" ]] && continue
  if echo "$skipped" | grep -qx "$q"; then continue; fi
  echo "$q" >> "$kept_tmp"
done <<< "$queue_list"
kept_count=$(grep -c . "$kept_tmp" || true)
echo "pruned $(echo "$skipped" | wc -l | tr -d ' ') formulae, $kept_count remain"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] queue file untouched ($QUEUE_FILE)"
  rm -f "$decide_tmp" "$decide_tmp.info" "$decide_tmp.queue" "$decide_tmp.skipped" "$decide_tmp.report" "$kept_tmp"
  exit 0
fi
cp "$kept_tmp" "$QUEUE_FILE"
rm -f "$decide_tmp" "$decide_tmp.info" "$decide_tmp.queue" "$decide_tmp.skipped" "$decide_tmp.report" "$kept_tmp"
echo "wrote $QUEUE_FILE ($kept_count)"
