#!/usr/bin/env bash
set -euo pipefail

# Host JSON helper: plain python3 only — never the VM's asdf slots.
# The repo .tool-versions pins VM-only interpreters; if the asdf shim
# cannot satisfy them on this host, drop it so brewed/system python3 is used.
if ! python3 -c 'pass' >/dev/null 2>&1; then
  PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '/\.asdf/shims' | paste -sd: -)"
fi

# sync.sh — recompute explicit + transitive deps, diff vs lock, produce build-queue.txt
# Usage: ./scripts/sync.sh [--dry-run] [--force] [--tag sequoia]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_FILE="$ROOT_DIR/packages.txt"
LOCK_FILE="$ROOT_DIR/packages.lock.json"
QUEUE_FILE="$ROOT_DIR/build-queue.txt"
TAG="${TAG:-sequoia}"
DRY_RUN="false"
FORCE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --force) FORCE="true"; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/sync.sh [--dry-run] [--force] [--tag sequoia]
  --dry-run   preview build queue, do not write lock/queue files
  --force     rebuild all resolved formulae regardless of lock
  --tag       bottle tag (default: sequoia, future: tahoe)
EOF
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$PACKAGES_FILE" ]]; then
  echo "error: $PACKAGES_FILE not found. Run ./scripts/packages.sh add <formula>" >&2
  exit 1
fi

explicit_list=$(grep -v '^[[:space:]]*#' "$PACKAGES_FILE" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u || true)
if [[ -z "$explicit_list" ]]; then
  echo "error: packages.txt is empty" >&2
  exit 1
fi
explicit_count=$(echo "$explicit_list" | wc -l | tr -d ' ')
echo "explicit: $explicit_count formulae"
echo "$explicit_list" | sed 's/^/  /'

core_sha=""
if command -v git >/dev/null 2>&1; then
  if [[ -d "/usr/local/Homebrew/Library/Taps/homebrew/homebrew-core" ]]; then
    # rev-parse may return "HEAD" literal on empty shallow tap — validate SHA
    tmp_sha=$(git -C /usr/local/Homebrew/Library/Taps/homebrew/homebrew-core rev-parse HEAD 2>/dev/null || true)
    if [[ "$tmp_sha" =~ ^[0-9a-f]{40}$ ]]; then
      core_sha="$tmp_sha"
    fi
  fi
  if [[ -z "$core_sha" ]]; then
    tmp_sha=$(git ls-remote https://github.com/Homebrew/homebrew-core HEAD 2>/dev/null | awk '{print $1}' || true)
    if [[ "$tmp_sha" =~ ^[0-9a-f]{40}$ ]]; then
      core_sha="$tmp_sha"
    fi
  fi
fi
echo "core SHA: ${core_sha:-unknown}"

echo "resolving dependencies (brew deps --include-build)..."
deps_tmp=$(mktemp)
: > "$deps_tmp"
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  if ! brew deps --include-build --full-name "$pkg" 2>/dev/null | tr ' ' '\n' >> "$deps_tmp"; then
    brew deps --full-name "$pkg" 2>/dev/null | tr ' ' '\n' >> "$deps_tmp" || true
  fi
  echo "$pkg" >> "$deps_tmp"
done <<< "$explicit_list"
resolved_list=$(cat "$deps_tmp" | grep -v '^[[:space:]]*$' | sed 's|.*/||' | sort -u || true)
rm -f "$deps_tmp"
resolved_count=$(echo "$resolved_list" | wc -l | tr -d ' ')
echo "resolved (explicit + transitive): $resolved_count formulae"
echo "$resolved_list" | sed 's/^/  /'

# Filter external build-deps (single-pin, B1) — never bottled, provided by toolchain.sh
BUILD_DEPS_CONF="$ROOT_DIR/build-deps.conf"
external_list=""
skipped_list=""
if [[ -f "$BUILD_DEPS_CONF" ]]; then
  # Collect names where strategy == external
  external_list=$(grep -v '^[[:space:]]*#' "$BUILD_DEPS_CONF" | grep -v '^[[:space:]]*$' | awk '$2=="external" {print $1}' | sort -u || true)
  if [[ -n "$external_list" ]]; then
    echo "external build-deps (build-deps.conf, not bottled):"
    echo "$external_list" | sed 's/^/  - /'
    # Remove external names from resolved unless they are explicitly requested
    filtered_tmp=$(mktemp)
    skipped_tmp=$(mktemp)
    : > "$filtered_tmp"; : > "$skipped_tmp"
    while IFS= read -r r; do
      [[ -z "$r" ]] && continue
      if echo "$external_list" | grep -qx "$r"; then
        if echo "$explicit_list" | grep -qx "$r"; then
          echo "  note: $r is external but also explicit — will still be bottled (explicit overrides)"
          echo "$r" >> "$filtered_tmp"
        else
          echo "$r" >> "$skipped_tmp"
        fi
      else
        echo "$r" >> "$filtered_tmp"
      fi
    done <<< "$resolved_list"
    skipped_count=$(grep -c . "$skipped_tmp" || true)
    if [[ "$skipped_count" -gt 0 ]]; then
      echo "  skipped $skipped_count external build-deps (provided by toolchain.sh):"
      cat "$skipped_tmp" | sed 's/^/    /'
    fi
    resolved_list=$(cat "$filtered_tmp" | sort -u || true)
    resolved_count=$(echo "$resolved_list" | wc -l | tr -d ' ')
    echo "resolved after external filter: $resolved_count formulae"
    echo "$resolved_list" | sed 's/^/  /'
    # Persist for lock
    SKIPPED_FILE=$(mktemp)
    cat "$skipped_tmp" | sort -u > "$SKIPPED_FILE"
    rm -f "$filtered_tmp" "$skipped_tmp"
  fi
fi

lock_core_sha=""
if [[ -f "$LOCK_FILE" ]]; then
  lock_core_sha=$(python3 -c "import json; d=json.load(open('$LOCK_FILE')); print(d.get('core_sha',''))" 2>/dev/null || echo "")
fi

echo "checking pkgVersions..."
current_json_tmp=$(mktemp)
info_json=$(brew info --json=v2 --formula $(echo "$resolved_list" | tr '\n' ' ') 2>/dev/null || echo '{"formulae":[]}')
python3 - "$info_json" "$current_json_tmp" <<'PY'
import json, sys
info_json_str=sys.argv[1]
out_path=sys.argv[2]
d=json.loads(info_json_str)
out={}
for f in d.get('formulae',[]):
    name=f.get('name')
    stable=f.get('versions',{}).get('stable','')
    revision=f.get('revision',0)
    pkg_version=stable if not revision else f"{stable}_{revision}"
    out[name]=pkg_version
with open(out_path,'w') as fp:
    json.dump(out, fp, indent=2, sort_keys=True)
PY
cat "$current_json_tmp" | python3 -m json.tool | sed 's/^/  /'

queue_tmp=$(mktemp)
: > "$queue_tmp"
resolved_changed="false"
if [[ "$FORCE" == "true" ]]; then
  resolved_changed="true"
else
  lock_keys=$(python3 -c "import json,os; p='$LOCK_FILE'; print('\n'.join(sorted(json.load(open(p)).get('resolved',{}).keys()))) if os.path.exists(p) else print('')" 2>/dev/null || true)
  if [[ "$(echo "$resolved_list" | sort)" != "$(echo "$lock_keys" | sort)" ]]; then
    resolved_changed="true"
    echo "dep set changed vs lock"
    echo "  lock: $(echo "$lock_keys" | grep -c . || true) formulae"
    echo "  now:  $resolved_count formulae"
  fi
fi
if [[ -n "$core_sha" && -n "$lock_core_sha" && "$core_sha" != "$lock_core_sha" ]]; then
  echo "core SHA changed: $lock_core_sha -> $core_sha"
fi

python3 - "$current_json_tmp" "$LOCK_FILE" "$queue_tmp" "$resolved_changed" "$FORCE" <<'PY'
import json, os, sys
current_path, lock_path, queue_path, resolved_changed, force = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]=="true", sys.argv[5]=="true"
with open(current_path) as f:
    current=json.load(f)
lock={}
if os.path.exists(lock_path):
    try:
        with open(lock_path) as f:
            lock=json.load(f)
    except: pass
lock_resolved=lock.get('resolved',{})
queue=[]
for name, ver in current.items():
    if force or resolved_changed or lock_resolved.get(name) != ver:
        queue.append(name)
        print(f"  queue: {name} {lock_resolved.get(name,'∅')} -> {ver}")
with open(queue_path,'w') as f:
    for n in sorted(queue):
        f.write(n+"\n")
PY

queue_count=$(grep -c . "$queue_tmp" || true)
if [[ "$queue_count" -eq 0 ]]; then
  echo "build queue: 0 (all up to date for tag $TAG)"
else
  echo "build queue: $queue_count formulae"
  cat "$queue_tmp" | sed 's/^/  /'
  echo "toposorting..."
  sorted_tmp=$(mktemp)
  python3 - "$queue_tmp" "$sorted_tmp" <<'PY'
import subprocess, sys
with open(sys.argv[1]) as f:
    queue=[l.strip() for l in f if l.strip()]
graph={}
for pkg in queue:
    try:
        out=subprocess.check_output(["brew","deps","--include-build","--full-name",pkg], text=True)
        deps=[d.split('/')[-1].strip() for d in out.strip().split() if d.strip()]
        graph[pkg]=[d for d in deps if d in queue]
    except:
        graph[pkg]=[]
visited=set(); order=[]
def dfs(n, stack):
    if n in visited: return
    if n in stack: return
    stack.add(n)
    for dep in graph.get(n,[]):
        dfs(dep, stack)
    stack.remove(n)
    visited.add(n)
    order.append(n)
for pkg in queue:
    dfs(pkg, set())
with open(sys.argv[2],'w') as f:
    for p in order:
        f.write(p+"\n")
PY
  mv "$sorted_tmp" "$queue_tmp"
  echo "sorted queue:"
  cat "$queue_tmp" | sed 's/^/  /'
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "[dry-run] queue would be written to $QUEUE_FILE, lock not updated"
  rm -f "$current_json_tmp" "$queue_tmp"
  exit 0
fi

if [[ "$queue_count" -eq 0 ]]; then
  : > "$QUEUE_FILE"
else
  cp "$queue_tmp" "$QUEUE_FILE"
fi

# Update lock
# Pass skipped file if exists
SKIPPED_FILE="${SKIPPED_FILE:-}"
python3 - "$LOCK_FILE" "$PACKAGES_FILE" "$current_json_tmp" "$core_sha" "$TAG" "$SKIPPED_FILE" <<'PY'
import json, os, sys, datetime
lock_path, packages_path, current_path, core_sha, tag, skipped_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
packages=[]
with open(packages_path) as f:
    for line in f:
        line=line.strip()
        if not line or line.startswith('#'): continue
        packages.append(line)
current={}
with open(current_path) as f:
    current=json.load(f)
skipped=[]
if skipped_file and os.path.exists(skipped_file):
    with open(skipped_file) as f:
        skipped=[l.strip() for l in f if l.strip()]
    skipped=sorted(set(skipped))
lock={}
if os.path.exists(lock_path):
    try:
        with open(lock_path) as f:
            lock=json.load(f)
    except: pass
lock['explicit']=sorted(packages)
lock['resolved']=current
lock['core_sha']=core_sha
lock['tag']=tag
lock['generated_at']=datetime.datetime.utcnow().isoformat()+"Z"
if skipped:
    lock['skipped_build_deps']=skipped
else:
    lock.pop('skipped_build_deps', None)
with open(lock_path,'w') as f:
    json.dump(lock, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"wrote {lock_path}")
PY

rm -f "$current_json_tmp" "$queue_tmp"
if [[ -n "${SKIPPED_FILE:-}" && -f "$SKIPPED_FILE" ]]; then rm -f "$SKIPPED_FILE"; fi
echo "wrote $QUEUE_FILE ($queue_count) and $LOCK_FILE"
echo "next: ./scripts/orchestrate.sh or ./scripts/build.sh inside VM"
