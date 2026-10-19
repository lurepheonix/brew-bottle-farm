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

# Filter farm-managed build-deps — never in the normal bottle queue:
#   external = provided by toolchain.sh provision (rust/go/python/ruby/node via uv/asdf)
#   bottled  = bottled by the farm's own fast pipeline (farm-toolchain), filtered here
BUILD_DEPS_CONF="$ROOT_DIR/build-deps.conf"
external_list=""
bottled_list=""
managed_list=""
if [[ -f "$BUILD_DEPS_CONF" ]]; then
  # Collect names by strategy
  external_list=$(grep -v '^[[:space:]]*#' "$BUILD_DEPS_CONF" | grep -v '^[[:space:]]*$' | awk '$2=="external" {print $1}' | sort -u || true)
  bottled_list=$(grep -v '^[[:space:]]*#' "$BUILD_DEPS_CONF" | grep -v '^[[:space:]]*$' | awk '$2=="bottled" {print $1}' | sort -u || true)
  managed_list=$(printf "%s\n%s" "$external_list" "$bottled_list" | grep -v '^$' | sort -u || true)
  if [[ -n "$external_list" ]]; then
    echo "external build-deps (build-deps.conf, not bottled):"
    echo "$external_list" | sed 's/^/  - /'
  fi
  if [[ -n "$bottled_list" ]]; then
    echo "tap-bottled build-deps (own pipeline, not in normal queue):"
    echo "$bottled_list" | sed 's/^/  - /'
  fi
  if [[ -n "$managed_list" ]]; then
    # Remove managed names from resolved unless they are explicitly requested
    filtered_tmp=$(mktemp)
    skipped_tmp=$(mktemp)
    tap_tmp=$(mktemp)
    : > "$filtered_tmp"; : > "$skipped_tmp"; : > "$tap_tmp"
    while IFS= read -r r; do
      [[ -z "$r" ]] && continue
      if echo "$managed_list" | grep -qx "$r"; then
        if echo "$explicit_list" | grep -qx "$r"; then
          if echo "$external_list" | grep -qx "$r"; then
            echo "  note: $r is external but also explicit — will still be bottled (explicit overrides)"
          else
            echo "  note: $r is tap-bottled but also explicit — will still be bottled (explicit overrides)"
          fi
          echo "$r" >> "$filtered_tmp"
        elif echo "$bottled_list" | grep -qx "$r"; then
          echo "$r" >> "$tap_tmp"
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
    tap_count=$(grep -c . "$tap_tmp" || true)
    if [[ "$tap_count" -gt 0 ]]; then
      echo "  tap-provided $tap_count (own pipeline, bottled separately):"
      cat "$tap_tmp" | sed 's/^/    /'
    fi
    resolved_list=$(cat "$filtered_tmp" | sort -u || true)
    resolved_count=$(echo "$resolved_list" | wc -l | tr -d ' ')
    echo "resolved after managed filter: $resolved_count formulae"
    echo "$resolved_list" | sed 's/^/  /'
    # Persist for lock
    SKIPPED_FILE=$(mktemp)
    cat "$skipped_tmp" | sort -u > "$SKIPPED_FILE"
    TAP_FILE=$(mktemp)
    cat "$tap_tmp" | sort -u > "$TAP_FILE"
    rm -f "$filtered_tmp" "$skipped_tmp" "$tap_tmp"
  fi
fi

lock_core_sha=""
if [[ -f "$LOCK_FILE" ]]; then
  lock_core_sha=$(python3 -c "import json; d=json.load(open('$LOCK_FILE')); print(d.get('core_sha',''))" 2>/dev/null || echo "")
fi

# Toolchain pin diff vs lock (per-slot rule: slot changes queue patched formulae;
# patch-only changes are reported but queue nothing).
echo "checking toolchain pins (build-deps.conf vs lock)..."
conf_pins_tmp=$(mktemp)
grep -v '^[[:space:]]*#' "$ROOT_DIR/build-deps.conf" 2>/dev/null | grep -v '^[[:space:]]*$' | awk 'NF>=3 && ($2=="external" || $2=="bottled") {print $1" "$3}' | sort -u > "$conf_pins_tmp" || true
affected_tmp=$(mktemp)
: > "$affected_tmp"
slot_changed_list=$(python3 - "$conf_pins_tmp" "$LOCK_FILE" <<'PY'
import json, os, sys
conf_path, lock_path = sys.argv[1], sys.argv[2]
conf = {}
with open(conf_path) as f:
    for line in f:
        p = line.split()
        if len(p) >= 2:
            conf[p[0]] = p[1]
lock = {}
if os.path.exists(lock_path):
    try:
        with open(lock_path) as f:
            lock = json.load(f)
    except Exception:
        pass
old = lock.get('toolchain', {})
def slot(v):
    parts = (v or '').split('.')
    return '.'.join(parts[:2]) if len(parts) >= 2 else (v or '')
tools = sorted(set(list(conf) + list(old)))
slot_changed = []
for t in tools:
    if conf.get(t) != old.get(t):
        if slot(conf.get(t)) != slot(old.get(t)):
            print(f"  toolchain slot change: {t} {old.get(t, 'absent')} -> {conf.get(t, 'absent')} (queues patched formulae + dependents)", file=sys.stderr)
            slot_changed.append(t)
        else:
            print(f"  toolchain patch change: {t} {old.get(t, 'absent')} -> {conf.get(t, 'absent')} (no rebuild)", file=sys.stderr)
print(' '.join(slot_changed))
PY
)
if [[ -n "$slot_changed_list" && "$FORCE" != "true" ]]; then
  echo "mapping changed tools to patched formulae..."
  series_file="$ROOT_DIR/patches/series"
  if [[ -f "$series_file" ]]; then
    while IFS= read -r patch_name || [[ -n "$patch_name" ]]; do
      patch_name="$(echo "$patch_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      if [[ -z "$patch_name" || "$patch_name" == \#* ]]; then
        continue
      fi
      patch_file="$ROOT_DIR/patches/$patch_name"
      if [[ ! -f "$patch_file" ]]; then
        continue
      fi
      header_tool=$(grep -E '^# Tool:' "$patch_file" 2>/dev/null | head -n1 | sed -E 's/^# Tool:[[:space:]]*//' | awk '{print $1}' || true)
      if [[ -n "$header_tool" ]] && echo "$slot_changed_list" | tr ' ' '\n' | grep -qx "$header_tool"; then
        formula=$(grep -E '^# Formula:' "$patch_file" 2>/dev/null | head -n1 | sed -E 's/^# Formula:[[:space:]]*//' | awk '{print $1}' || true)
        if [[ -z "$formula" ]]; then
          formula=$(basename "$patch_name" | sed -E 's/-use-external-.*\.patch$//;s/\.patch$//')
        fi
        if [[ -n "$formula" ]]; then
          echo "  tool $header_tool -> $formula (via $patch_name)"
          echo "$formula" >> "$affected_tmp"
        fi
      fi
    done < <(grep -v '^[[:space:]]*#' "$series_file" | grep -v '^[[:space:]]*$' || true)
  fi
  # transitive dependents within the resolved closure
  if [[ -s "$affected_tmp" ]]; then
    echo "resolving transitive dependents..."
    resolved_graph_tmp=$(mktemp)
    echo "$resolved_list" > "$resolved_graph_tmp"
    python3 - "$resolved_graph_tmp" "$affected_tmp" <<'PY'
import subprocess, sys
graph_path, affected_path = sys.argv[1], sys.argv[2]
with open(graph_path) as f:
    resolved = [line.strip() for line in f if line.strip()]
with open(affected_path) as f:
    seeds = set(line.strip() for line in f if line.strip())
forward = {}
known = set(resolved)
for pkg in resolved:
    try:
        out = subprocess.check_output(
            ["brew", "deps", "--include-build", "--full-name", pkg],
            text=True, stderr=subprocess.DEVNULL)
        deps = [d.split('/')[-1].strip() for d in out.strip().split() if d.strip()]
        forward[pkg] = [d for d in deps if d in known]
    except Exception:
        forward[pkg] = []
rev = {p: set() for p in resolved}
for p, ds in forward.items():
    for d in ds:
        rev[d].add(p)
seen = set(seeds)
stack = list(seeds)
while stack:
    cur = stack.pop()
    for parent in rev.get(cur, ()):
        if parent not in seen:
            seen.add(parent)
            stack.append(parent)
with open(affected_path, 'w') as f:
    for n in sorted(seen):
        f.write(n + "\n")
print(f"  affected (with dependents): {len(seen)} formulae", file=sys.stderr)
PY
    rm -f "$resolved_graph_tmp"
  fi
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

python3 - "$current_json_tmp" "$LOCK_FILE" "$queue_tmp" "$resolved_changed" "$FORCE" "$affected_tmp" <<'PY'
import json, os, sys
current_path, lock_path, queue_path = sys.argv[1], sys.argv[2], sys.argv[3]
resolved_changed, force = sys.argv[4] == "true", sys.argv[5] == "true"
affected_path = sys.argv[6]
with open(current_path) as f:
    current = json.load(f)
lock = {}
if os.path.exists(lock_path):
    try:
        with open(lock_path) as f:
            lock = json.load(f)
    except Exception:
        pass
lock_resolved = lock.get('resolved', {})
affected = set()
if os.path.exists(affected_path):
    with open(affected_path) as f:
        affected = set(line.strip() for line in f if line.strip())
queue = []
for name, ver in current.items():
    if force or resolved_changed or lock_resolved.get(name) != ver:
        queue.append(name)
        print(f"  queue: {name} {lock_resolved.get(name, '∅')} -> {ver}")
    elif name in affected:
        queue.append(name)
        print(f"  queue: {name} {ver} (toolchain pin change)")
with open(queue_path, 'w') as f:
    for n in sorted(queue):
        f.write(n + "\n")
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
  rm -f "$current_json_tmp" "$queue_tmp" "$conf_pins_tmp" "$affected_tmp"
  if [[ -n "${SKIPPED_FILE:-}" && -f "$SKIPPED_FILE" ]]; then rm -f "$SKIPPED_FILE"; fi
  if [[ -n "${TAP_FILE:-}" && -f "$TAP_FILE" ]]; then rm -f "$TAP_FILE"; fi
  exit 0
fi

if [[ "$queue_count" -eq 0 ]]; then
  : > "$QUEUE_FILE"
else
  cp "$queue_tmp" "$QUEUE_FILE"
fi

# Update lock
# Pass skipped + tap-provided + conf-pins files if they exist
SKIPPED_FILE="${SKIPPED_FILE:-}"
TAP_FILE="${TAP_FILE:-}"
python3 - "$LOCK_FILE" "$PACKAGES_FILE" "$current_json_tmp" "$core_sha" "$TAG" "$SKIPPED_FILE" "$TAP_FILE" "$ROOT_DIR/build-deps.conf" <<'PY'
import json, os, sys, datetime
lock_path, packages_path, current_path, core_sha, tag = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
skipped_file, tap_file, conf_path = sys.argv[6], sys.argv[7], sys.argv[8]
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
tap_provided=[]
if tap_file and os.path.exists(tap_file):
    with open(tap_file) as f:
        tap_provided=[l.strip() for l in f if l.strip()]
    tap_provided=sorted(set(tap_provided))
toolchain={}
if os.path.exists(conf_path):
    with open(conf_path) as f:
        for line in f:
            line=line.strip()
            if not line or line.startswith('#'): continue
            p=line.split()
            if len(p) >= 3 and p[1] in ("external", "bottled"):
                toolchain[p[0]]=p[2]
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
if tap_provided:
    lock['tap_provided']=tap_provided
else:
    lock.pop('tap_provided', None)
if toolchain:
    lock['toolchain']=toolchain
else:
    lock.pop('toolchain', None)
with open(lock_path,'w') as f:
    json.dump(lock, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"wrote {lock_path}")
PY

rm -f "$current_json_tmp" "$queue_tmp" "$conf_pins_tmp" "$affected_tmp"
if [[ -n "${SKIPPED_FILE:-}" && -f "$SKIPPED_FILE" ]]; then rm -f "$SKIPPED_FILE"; fi
if [[ -n "${TAP_FILE:-}" && -f "$TAP_FILE" ]]; then rm -f "$TAP_FILE"; fi
echo "wrote $QUEUE_FILE ($queue_count) and $LOCK_FILE"
echo "next: ./scripts/orchestrate.sh or ./scripts/build.sh inside VM"
