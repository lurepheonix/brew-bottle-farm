#!/usr/bin/env bash
set -euo pipefail

# Host JSON helper: plain python3 only — never the VM's asdf slots.
# The repo .tool-versions pins VM-only interpreters; if the asdf shim
# cannot satisfy them on this host, drop it so brewed/system python3 is used.
if ! python3 -c 'pass' >/dev/null 2>&1; then
  PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '/\.asdf/shims' | paste -sd: -)"
fi

# orchestrate.sh — host glue: sync → build → publish
# Usage: ./scripts/orchestrate.sh [--dry-run] [--skip-vm] [--skip-publish] [--tag sequoia] [--force] [--local] [--transport ssh|prlctl|local] [--output-dir DIR]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG="${TAG:-sequoia}"
DRY_RUN="false"
SKIP_VM="false"
SKIP_PUBLISH="false"
FORCE="false"
LOCAL_MODE="false"
LOCAL_OUTPUT="${LOCAL_OUTPUT:-/tmp/farm-local-bottles}"
FARM_TRANSPORT="${FARM_TRANSPORT:-ssh}"
OUTPUT_DIR_OVERRIDE=""

VM_NAME="${VM_NAME:-brew-sequoia}"
SHARED_DIR="${SHARED_DIR:-$HOME/Parallels/shared-brew}"
BOTTLES_DIR="$ROOT_DIR/bottles"
VM_BOTTLES_DIR="/tmp/shared/bottles"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --skip-vm) SKIP_VM="true"; shift ;;
    --skip-publish) SKIP_PUBLISH="true"; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    --force) FORCE="true"; shift ;;
    --local) LOCAL_MODE="true"; shift ;;
    --transport) FARM_TRANSPORT="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR_OVERRIDE="$2"; shift 2 ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/orchestrate.sh [--dry-run] [--skip-vm] [--skip-publish] [--tag sequoia] [--force] [--local] [--transport T] [--output-dir DIR]
  --dry-run      sync dry-run + build dry-run (no VM, no publish)
  --skip-vm      assume build-queue.txt already built, skip VM build, go straight to publish
  --skip-publish run sync+VM build but do not publish (leave bottles in ./bottles)
  --force        force rebuild all (sync --force)
  --tag          bottle tag
  --local        host dry path: sync → patch → build on host (publish untouched,
                 VM stays canonical; output defaults to /tmp/farm-local-bottles)
  --transport    FARM_TRANSPORT=ssh|prlctl|local (default: ssh; --local forces local)
  --output-dir   bottle output dir (VM path default: ./bottles; --local default:
                 /tmp/farm-local-bottles)
EOF
      exit 0 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done

case "$FARM_TRANSPORT" in
  ssh|prlctl|local) ;;
  *) echo "error: unknown FARM_TRANSPORT=$FARM_TRANSPORT (want ssh|prlctl|local)" >&2; exit 1 ;;
esac
export FARM_TRANSPORT
if [[ "$LOCAL_MODE" == "true" ]]; then
  FARM_TRANSPORT="local"
  export FARM_TRANSPORT
  SKIP_PUBLISH="true"
  if [[ -n "$OUTPUT_DIR_OVERRIDE" ]]; then
    LOCAL_OUTPUT="$OUTPUT_DIR_OVERRIDE"
  fi
fi

echo "=== orchestrate (tag $TAG, dry-run $DRY_RUN, force $FORCE, transport $FARM_TRANSPORT) ==="
echo "root: $ROOT_DIR"
echo "vm: $VM_NAME shared: $SHARED_DIR -> $VM_BOTTLES_DIR"
# Tap release target (same source publish.sh uses): repo-root .env TAP_REPO,
# else TAP_REPO env. Never inferred from the farm checkout's git remote
# (that points at brew-bottle-farm, not the tap). TAP_REPO is REQUIRED on all
# paths (set it in .env even if nothing is ever uploaded): it names the tap
# the builder resolves against (FARM_TAP_NAME) and the release target.
# Derived TAP_ROOT_URL is passed through to the guest build so bottle JSONs
# carry real release URLs.
if [[ -f "$ROOT_DIR/.env" ]]; then
  _tap_from_env=$(grep -E '^TAP_REPO=' "$ROOT_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- || true)
  _tap_from_env="${_tap_from_env%\"}"; _tap_from_env="${_tap_from_env#\"}"
  _tap_from_env="${_tap_from_env%\'}"; _tap_from_env="${_tap_from_env#\'}"
  if [[ -n "${_tap_from_env:-}" && -z "${TAP_REPO:-}" ]]; then
    TAP_REPO="$_tap_from_env"
  fi
fi
if [[ -z "${TAP_REPO:-}" ]]; then
  echo "error: TAP_REPO must be set (.env or env, e.g. TAP_REPO=<user>/homebrew-intel)" >&2
  echo "hint: the builder resolves deps through this tap name on every path (VM and --local)" >&2
  exit 1
fi
TAP_ROOT_URL="https://github.com/${TAP_REPO}/releases/download"
export TAP_ROOT_URL
# Consumer shorthand + tap-dir parts: <user>/homebrew-intel -> short
# <user>/intel, dir Library/Taps/<user>/homebrew-intel. FARM_TAP_NAME is the
# single tap name the builder resolves against (no legacy fallback tap).
TAP_USER="${TAP_REPO%%/*}"
TAP_REPO_NAME="${TAP_REPO##*/}"
TAP_SHORT="$TAP_REPO"
if [[ "$TAP_REPO_NAME" == homebrew-* ]]; then
  TAP_SHORT="$TAP_USER/${TAP_REPO_NAME#homebrew-}"
fi
FARM_TAP_NAME="$TAP_SHORT"
export FARM_TAP_NAME TAP_USER TAP_REPO_NAME TAP_SHORT
echo "tap: $TAP_REPO (build resolves $FARM_TAP_NAME)"
echo "tap root_url base: $TAP_ROOT_URL/<formula>-<version>"
# Per-slot pins: build-deps.conf ↔ .tool-versions must match before any work
if [[ -f "$ROOT_DIR/build-deps.conf" && -f "$ROOT_DIR/.tool-versions" ]]; then
  conf_py=$(grep -E '^python@' "$ROOT_DIR/build-deps.conf" 2>/dev/null | awk '$2=="external"{print $3}' | sort -n | tr '\n' ' ' | sed 's/ *$//' || true)
  tool_py=$(grep -E '^python[[:space:]]' "$ROOT_DIR/.tool-versions" 2>/dev/null | sed -E 's/^python[[:space:]]+//' | tr ' ' '\n' | grep -v '^#' | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ *$//' || true)
  if [[ -n "$conf_py" && -n "$tool_py" && "$conf_py" != "$tool_py" ]]; then
    echo "error: build-deps.conf python [$conf_py] != .tool-versions python [$tool_py] (per-slot pin rule)" >&2
    exit 1
  fi
  conf_node=$(grep -E '^node[[:space:]]' "$ROOT_DIR/build-deps.conf" 2>/dev/null | awk '$2=="external"{print $3}' | head -n1 || true)
  tool_node=$(grep -E '^nodejs[[:space:]]' "$ROOT_DIR/.tool-versions" 2>/dev/null | awk '{print $2}' | head -n1 || true)
  if [[ -n "$conf_node" && -n "$tool_node" && "$conf_node" != "$tool_node" ]]; then
    echo "error: build-deps.conf node $conf_node != .tool-versions nodejs $tool_node (per-slot pin rule)" >&2
    exit 1
  fi
fi

# 1. Sync
echo ""
echo ">>> 1/4 sync (explicit + deps -> build-queue.txt)  [external build-deps filtered per build-deps.conf]"
sync_args=()
if [[ "$FORCE" == "true" ]]; then sync_args+=(--force); fi
sync_args+=(--tag "$TAG")
if [[ "$DRY_RUN" == "true" ]]; then
  "$SCRIPT_DIR/sync.sh" "${sync_args[@]}" --dry-run
  echo "[dry-run] would proceed to VM build, skipping"
  exit 0
else
  "$SCRIPT_DIR/sync.sh" "${sync_args[@]}"
fi

QUEUE_FILE="$ROOT_DIR/build-queue.txt"
queue_count=$(grep -c . "$QUEUE_FILE" 2>/dev/null || true)
if [[ "$queue_count" -eq 0 ]]; then
  echo "queue empty — nothing to build"
  # Still show what was skipped / tap-provided
  if [[ -f "$ROOT_DIR/packages.lock.json" ]]; then
    skipped=$(python3 -c "import json; d=json.load(open('$ROOT_DIR/packages.lock.json')); print(', '.join(d.get('skipped_build_deps',[])))" 2>/dev/null || true)
    if [[ -n "$skipped" ]]; then
      echo "skipped external build-deps (provided by toolchain, not bottled): $skipped"
    fi
    tapped=$(python3 -c "import json; d=json.load(open('$ROOT_DIR/packages.lock.json')); print(', '.join(d.get('tap_provided',[])))" 2>/dev/null || true)
    if [[ -n "$tapped" ]]; then
      echo "tap-provided build-deps (own pipeline, bottled separately): $tapped"
    fi
  fi
  exit 0
fi
echo "queue: $queue_count formulae"
# Show skipped external + tap-provided deps for visibility
if [[ -f "$ROOT_DIR/packages.lock.json" ]]; then
  skipped=$(python3 -c "import json; d=json.load(open('$ROOT_DIR/packages.lock.json')); print(', '.join(d.get('skipped_build_deps',[])))" 2>/dev/null || true)
  if [[ -n "$skipped" ]]; then
    echo "skipped external build-deps: $skipped (via toolchain.sh)"
  fi
  tapped=$(python3 -c "import json; d=json.load(open('$ROOT_DIR/packages.lock.json')); print(', '.join(d.get('tap_provided',[])))" 2>/dev/null || true)
  if [[ -n "$tapped" ]]; then
    echo "tap-provided build-deps: $tapped (own pipeline, bottled separately)"
  fi
fi

# 1b. Mirror Formulae + apply patches (B1)
echo ""
echo ">>> 1b/4 mirror + patches (B1)"
# Mirror every queued Formula fresh from homebrew-core at the locked
# core_sha (raw URL — deterministic, no `brew cat` download-cache staleness).
# The lock was just written by sync above, so the SHA matches its versions.
core_sha_for_mirror=$(python3 -c "import json; print(json.load(open('$ROOT_DIR/packages.lock.json')).get('core_sha',''))" 2>/dev/null || true)
if [[ -z "$core_sha_for_mirror" ]]; then
  echo "warn: no core_sha in lock — mirrors fall back to brew cat (may be stale)" >&2
fi
for f in $(cat "$QUEUE_FILE"); do
  dest="$ROOT_DIR/Formula/$f.rb"
  echo "mirroring Formula/$f.rb..."
  mkdir -p "$ROOT_DIR/Formula"
  mirrored="false"
  if [[ -n "${core_sha_for_mirror:-}" ]]; then
    first="${f:0:1}"
    _paths=("Formula/${first}/$f.rb")
    if [[ "$f" == lib* ]]; then
      _paths+=("Formula/lib/$f.rb")
    fi
    for _p in "${_paths[@]}"; do
      if curl -fsSL "https://raw.githubusercontent.com/Homebrew/homebrew-core/${core_sha_for_mirror}/${_p}" -o "$dest.tmp" 2>/dev/null; then
        mv "$dest.tmp" "$dest"
        mirrored="true"
        break
      fi
      rm -f "$dest.tmp"
    done
  fi
  if [[ "$mirrored" != "true" ]]; then
    echo "  warn: raw mirror failed for $f — falling back to brew cat (may be stale)" >&2
    if brew cat "$f" >/dev/null 2>&1; then
      brew cat "$f" > "$dest" 2>/dev/null || true
    fi
  fi
done
if [[ -f "$ROOT_DIR/patches/series" ]]; then
  echo "applying patches from patches/series..."
  if ! "$SCRIPT_DIR/apply-patches.sh" 2>&1 | sed 's/^/  apply: /'; then
    echo "error: patch apply failed — refresh patches after core_sha bump" >&2
    exit 1
  fi
  # Propagate patched Formulae into shared dir for VM (VM's build.sh will use bottled deps + patched formulae)
  # VM will brew cat the same Formula, so we copy patched files to shared for reference
  mkdir -p "$SHARED_DIR/Formula"
  cp -v "$ROOT_DIR"/Formula/*.rb "$SHARED_DIR/Formula/" 2>/dev/null || true
  # Mirror tap aliases (<tap>/Aliases): installs record tab.aliases from
  # the installing tap, and superenv hardcodes some opt paths (notably
  # opt/pkg-config) that only exist via alias links. Without them, Tier-3
  # configure builds fail even with the keg installed.
  echo "mirroring tap aliases for queued formulae..."
  rm -rf "$SHARED_DIR/Aliases"
  mkdir -p "$SHARED_DIR/Aliases"
  _alias_json=$(brew info --json=v2 --formula $(cat "$QUEUE_FILE" | tr '\n' ' ') 2>/dev/null || echo '{"formulae":[]}')
  echo "$_alias_json" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f\"{a} {x['name']}\") for x in d.get('formulae',[]) for a in x.get('aliases',[])]" 2>/dev/null | while IFS=' ' read -r _a _f; do
    [[ -z "${_a:-}" || -z "${_f:-}" ]] && continue
    ln -sfn "../Formula/$_f.rb" "$SHARED_DIR/Aliases/$_a" 2>/dev/null || true
  done
  _alias_n=$(ls "$SHARED_DIR/Aliases/" 2>/dev/null | wc -l | tr -d ' ')
  echo "  tap aliases staged: ${_alias_n:-0}"
else
  echo "no patches/series — skipping patch step"
fi

# 1c. Stage normalization: every bottled dep resolves within the tap.
# Patch text stays fork-agnostic (`farm/local/` placeholder + bare core names
# allowed), so the staged copies (what the builder installs and what gets
# published) are normalized here, deterministically, every run:
#   (i)  `farm/local/X` -> `<tap-short>/X` (placeholder mapping), then
#   (ii) bare `depends_on "N"` / `Formula["N"]` -> tap-qualified for every
#        queued (bottled) N — comments skipped, scope suffixes preserved.
# The mapping set is closed (queue only): externals (rust/go/...) can never
# map, and a tap-qualified external aborts the run (patch-coverage tripwire:
# an unpatched external dep would otherwise fail obscurely mid-build).
echo ""
echo ">>> 1c/4 stage normalization (all bottled deps -> $FARM_TAP_NAME)"
python3 - "$SHARED_DIR/Formula" "$FARM_TAP_NAME" "$QUEUE_FILE" "$ROOT_DIR/build-deps.conf" <<'PYEOF'
import glob, os, re, sys
staged, tap, queue_file, conf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
queued = sorted({l.strip() for l in open(queue_file) if l.strip()})
externals = set()
try:
    for line in open(conf):
        p = line.split()
        if len(p) >= 3 and p[1] == "external":
            externals.add(p[0])
except FileNotFoundError:
    pass
files = sorted(glob.glob(os.path.join(staged, "*.rb")))
if not files:
    print("error: no staged Formulae to normalize", file=sys.stderr)
    sys.exit(1)
rewritten = 0
for path in files:
    with open(path) as f:
        lines = f.readlines()
    out, changed = [], False
    for line in lines:
        stripped = line.lstrip()
        if "farm/local/" in line:
            line = line.replace("farm/local/", tap + "/")
            changed = True
        if not stripped.startswith("#"):
            for n in queued:
                if re.search(r'depends_on\s+"' + re.escape(n) + r'"', line):
                    line = re.sub(r'(depends_on\s+")' + re.escape(n) + r'"', r"\1" + tap + "/" + n + '"', line)
                    changed = True
                if re.search(r'Formula\["' + re.escape(n) + r'"\]', line):
                    line = re.sub(r'Formula\["' + re.escape(n) + r'"\]', f'Formula["{tap}/{n}"]', line)
                    changed = True
        out.append(line)
    if changed:
        with open(path, "w") as f:
            f.writelines(out)
        rewritten += 1
print(f"normalized {rewritten}/{len(files)} staged Formulae to {tap}")
# Fail-closed asserts on the staged output.
problems = 0
for path in files:
    with open(path) as f:
        text = f.read()
    if "farm/local/" in text:
        print(f"error: {os.path.basename(path)}: placeholder farm/local/ leaked past normalization", file=sys.stderr)
        problems += 1
    for line in text.split("\n"):
        if line.lstrip().startswith("#"):
            continue
        for n in queued:
            if re.search(r'depends_on\s+"' + re.escape(n) + r'"', line) or \
               re.search(r'Formula\["' + re.escape(n) + r'"\]', line):
                print(f"error: {os.path.basename(path)}: bare bottled dep {n} survived normalization", file=sys.stderr)
                problems += 1
    for ext in sorted(externals):
        if tap + "/" + ext in text:
            # Authored shim-kegs (python@3.15.rb, ruby.rb) intentionally carry
            # the tap name on the builder; they resolve through the seeded tap
            # and are never bottled (publish-time dangling is a recorded,
            # deferred decision — not a stage error).
            if os.path.isfile(os.path.join(staged, ext + ".rb")):
                continue
            print(f"error: {os.path.basename(path)}: external {ext} tap-qualified (no such formula can exist)", file=sys.stderr)
            problems += 1
if problems:
    print(f"error: stage normalization failed with {problems} problem(s)", file=sys.stderr)
    sys.exit(1)
print("stage asserts clean: no placeholder, no bare bottled deps, no tap-qualified externals")
PYEOF

# 1d. In-tap patch files: some core formulae apply patch files that live
# inside the tap repo itself (`file "Patches/<name>/..."`, e.g. lua). The
# guest tap must carry them or the build fails with "Patch file does not
# exist". Mirrored from homebrew-core at the locked core_sha (same trust
# model as Formula mirrors + Aliases); fail closed when unmirrorable.
# Dest is $SHARED_DIR/tap-files/ (NOT $SHARED_DIR/Patches/): on
# case-insensitive filesystems Patches/ collides with the farm's patches/
# staging dir, and nothing ever copied it into the guest tap anyway —
# build.sh overlays each referenced file into the tap next to the Formula.
echo ""
echo ">>> 1d/4 in-tap patch files (Patches/)"
if [[ -z "${core_sha_for_mirror:-}" ]]; then
  echo "warn: no core_sha in lock — cannot mirror in-tap patch files; build may fail on Patches/ refs" >&2
else
  _refs=$(grep -rh --include='*.rb' -o -E 'file "Patches/[^"]+"' "$SHARED_DIR/Formula/" 2>/dev/null | sed -E 's/^file "//; s/"$//' | sort -u || true)
  if [[ -z "$_refs" ]]; then
    echo "  no Patches/ refs in staged Formulae"
  else
    # NOTE: herestring loop (not a pipe) so `exit 1` aborts the script.
    while IFS= read -r _rp; do
      [[ -z "$_rp" ]] && continue
      _dest="$SHARED_DIR/tap-files/$_rp"
      if [[ -f "$_dest" ]]; then
        echo "  present: $_rp"
        continue
      fi
      echo "  mirroring $_rp..."
      mkdir -p "$(dirname "$_dest")"
      if curl -fsSL "https://raw.githubusercontent.com/Homebrew/homebrew-core/${core_sha_for_mirror}/${_rp}" -o "$_dest.tmp" 2>/dev/null; then
        mv "$_dest.tmp" "$_dest"
      else
        rm -f "$_dest.tmp"
        echo "error: cannot mirror in-tap patch file $_rp at $core_sha_for_mirror" >&2
        exit 1
      fi
    done <<< "$_refs"
    # Fail closed: every referenced file must now exist staged.
    _missing=$(grep -rh --include='*.rb' -o -E 'file "Patches/[^"]+"' "$SHARED_DIR/Formula/" 2>/dev/null | sed -E 's/^file "//; s/"$//' | sort -u | while IFS= read -r _rp; do [[ -f "$SHARED_DIR/tap-files/$_rp" ]] || echo "$_rp"; done || true)
    if [[ -n "$_missing" ]]; then
      echo "error: in-tap patch files still missing after mirror:" >&2
      echo "$_missing" | sed 's/^/  /' >&2
      exit 1
    fi
    echo "  in-tap patch files staged"
  fi
fi

# 2. Build — VM guest (transport-dispatched) or host-local dry path
if [[ "$LOCAL_MODE" == "true" ]]; then
  echo ""
  echo ">>> 2/3 host-local build (--local; publish untouched, VM stays canonical)"
  if [[ -n "$OUTPUT_DIR_OVERRIDE" ]]; then
    echo "output: $LOCAL_OUTPUT (explicit --output-dir)"
  else
    echo "output: $LOCAL_OUTPUT (default scratch; ./bottles untouched)"
  fi
  echo "warn: host-local bottles are non-canonical (VM stays canonical until Phase 3 decides)" >&2
  echo "host additive-only: built kegs stay installed (local consumer), no host cache cleanup, wrappers in temp dir"
  echo "verifying host toolchains match pins (--check only, no install)..."
  if ! bash "$SCRIPT_DIR/toolchain.sh" --check 2>&1 | sed 's/^/  toolchain-check: /'; then
    echo "error: host toolchain check failed — local build needs matching pins" >&2
    exit 1
  fi
  mkdir -p "$LOCAL_OUTPUT"
  FARMBIN_DIR="$(mktemp -d /tmp/farm-farmbin.XXXXXX)"
  trap 'rm -rf "$FARMBIN_DIR"' EXIT
  if ! env TAG="$TAG" OUTPUT_DIR="$LOCAL_OUTPUT" BUILD_LOG_DIR="/tmp" TAP_ROOT_URL="${TAP_ROOT_URL:-}" FARM_TAP_NAME="$FARM_TAP_NAME" TAP_USER="$TAP_USER" TAP_REPO_NAME="$TAP_REPO_NAME" FARM_TOOLCHAIN_GATE=skip FARM_CLEANUP=0 FARM_RESTORE_KEGS=1 FARM_KEEP_INSTALLED=1 FARMBIN="$FARMBIN_DIR" bash "$SCRIPT_DIR/build.sh" "$QUEUE_FILE" 2>&1 | sed 's/^/  build-local: /'; then
    echo "error: host-local build failed (see /tmp/build-*.log)" >&2
    exit 1
  fi
  echo "local artifacts in $LOCAL_OUTPUT:"
  ls -lh "$LOCAL_OUTPUT" | sed 's/^/  /'
elif [[ "$SKIP_VM" == "true" ]]; then
  echo ""
  echo ">>> 2/3 VM build — skipped (--skip-vm)"
else
  echo ""
  echo ">>> 2/3 VM build ($VM_NAME, transport $FARM_TRANSPORT)"
  mkdir -p "$SHARED_DIR"
  mkdir -p "$BOTTLES_DIR"
  # Stage everything the VM needs (shared helper — same as manual `vm.sh shared-sync`;
  # transport is rsync over SSH, re-resolving the DHCP IP each run)
  "$SCRIPT_DIR/vm.sh" shared-sync 2>&1 | sed 's/^/  shared-sync: /' || true
  # Ensure queue is fresh (shared-sync copies stale queue if present; overwrite with current)
  cp -v "$QUEUE_FILE" "$SHARED_DIR/build-queue.txt" 2>&1 | sed 's/^/  /' || true
  # Guest /tmp/shared is reboot-volatile (seen live: a guest wedge + restart
  # wiped it clean). The durable bottle store is host ./bottles, so:
  # resume (FARM_RESUME=1) re-seeds guest bottles from host before shared-sync
  # (guest-side skip logic needs the artifacts present); from-scratch clears
  # the guest dir so stale artifacts can never be collected as fresh.
  if [[ "${FARM_RESUME:-0}" == "1" ]]; then
    echo "reseeding guest bottles from host (resume)..."
    mkdir -p "$SHARED_DIR/bottles"
    _reseed_n=0
    for _b in "$BOTTLES_DIR"/*.tar.gz "$BOTTLES_DIR"/*.json; do
      [[ -e "$_b" ]] || continue
      cp -v "$_b" "$SHARED_DIR/bottles/" 2>&1 | sed 's/^/  reseed: /' || true
      _reseed_n=$((_reseed_n + 1))
    done
    echo "  reseeded $_reseed_n bottle files for resume"
  fi
  # Push the fresh queue to the guest (dispatch: ssh rsync-to; prlctl fails closed).
  "$SCRIPT_DIR/vm.sh" push "$QUEUE_FILE" /tmp/shared/build-queue.txt 2>&1 | sed 's/^/  queue-push: /' || {
    echo "error: queue push failed — run: VM_USER=<gui-user> ./scripts/vm.sh ssh-setup" >&2
    exit 1
  }
  # Start VM if not running (reuses persistent VM — setup once, snapshot clean/toolchain-ready)
  echo "ensuring VM running (reused, setup once)..."
  if ! "$SCRIPT_DIR/vm.sh" status 2>&1 | grep "running" >/dev/null; then
    "$SCRIPT_DIR/vm.sh" start || {
      echo "error: could not start VM $VM_NAME" >&2
      echo "hint: ./scripts/vm.sh status; ./scripts/vm.sh create if missing" >&2
      exit 1
    }
  fi
  # Ensure shared dirs exist on the guest (dispatch; prlctl exec stays for bootstrap only)
  "$SCRIPT_DIR/vm.sh" run mkdir -p "$VM_BOTTLES_DIR" 2>/dev/null || {
    echo "error: guest mkdir failed (transport $FARM_TRANSPORT) — VM path needs ssh: VM_USER=<gui-user> ./scripts/vm.sh ssh-setup" >&2
    exit 1
  }
  "$SCRIPT_DIR/vm.sh" run mkdir -p "/tmp/shared/Formula" 2>/dev/null || true
  # From-scratch runs must not inherit stale guest artifacts (a reboot-volatile
  # /tmp/shared can also resurrect old files via reseed — reseed only runs for
  # resume, so clearing here is safe and keeps full-collect honest).
  if [[ "${FARM_RESUME:-0}" != "1" ]]; then
    echo "clearing guest bottles (from-scratch)..."
    # find -delete (not rm glob): argv crosses ssh join+reparse and both host
    # and guest zsh fail bare non-matching globs — noglob passes the patterns
    # literally and find matches nothing cleanly with RC=0 (seen live:
    # unquoted rm silently cleared nothing, stale bottles were recollected).
    "$SCRIPT_DIR/vm.sh" run noglob find "$VM_BOTTLES_DIR" -maxdepth 1 -name '*.tar.gz' -delete 2>/dev/null || true
    "$SCRIPT_DIR/vm.sh" run noglob find "$VM_BOTTLES_DIR" -maxdepth 1 -name '*.json' -delete 2>/dev/null || true
  fi
  # Provision external toolchains in VM (rustup + go + asdf python) — idempotent, skipped if snapshot toolchain-ready
  echo "provisioning toolchain in VM (rustup + go + uv/asdf runtimes per build-deps.conf)..."
  cp -v "$SCRIPT_DIR/toolchain.sh" "$SHARED_DIR/scripts/toolchain.sh"
  if ! "$SCRIPT_DIR/vm.sh" run bash /tmp/shared/scripts/toolchain.sh 2>&1 | sed 's/^/  toolchain: /'; then
    echo "error: toolchain provision failed" >&2
    echo "hint: VM_USER=<gui-user> ./scripts/vm.sh ssh bash  # to inspect" >&2
    exit 1
  fi

  # TAP_ROOT_URL was resolved from TAP_REPO at startup (see top of script);
  # it travels with the guest command env below so build.sh needs no git remote.

  echo "executing build.sh inside VM (sources /tmp/shared/toolchain.env, uses external rust/go)..."
  # Copy build.sh + launcher into shared so VM can run them
  cp -v "$SCRIPT_DIR/build.sh" "$SHARED_DIR/scripts/build.sh"
  cp -v "$SCRIPT_DIR/guest-build-detached.sh" "$SHARED_DIR/scripts/guest-build-detached.sh"
  # Also copy patched Formulae into VM's shared Formula cache so `brew cat` sees patches
  # (VM's homebrew will still read from Formula/*.rb we mirrored)
  if [[ -d "$SHARED_DIR/Formula" ]]; then
    echo "patched Formulae available at /tmp/shared/Formula (VM can diff vs /usr/local/Homebrew if needed)"
  fi
  # Run on the guest via transport dispatch — build.sh sources the staged
  # toolchain.env (env vars for TAG/OUTPUT_DIR travel with the command).
  # Re-push build.sh + launcher first so the guest always runs current versions.
  "$SCRIPT_DIR/vm.sh" push "$SCRIPT_DIR/build.sh" /tmp/shared/scripts/build.sh 2>&1 | sed 's/^/  stage-build: /' || {
    echo "error: build.sh stage failed" >&2
    exit 1
  }
  "$SCRIPT_DIR/vm.sh" push "$SCRIPT_DIR/guest-build-detached.sh" /tmp/shared/scripts/guest-build-detached.sh 2>&1 | sed 's/^/  stage-launch: /' || {
    echo "error: launcher stage failed" >&2
    exit 1
  }
  # Detached launch: the guest build daemonizes into its own session and
  # survives ssh/host death (a dropped ssh SIGHUPs foreground remote process
  # groups — seen live). This ssh exits immediately; the poll loop below
  # waits for /tmp/farm-build.rc. Ctrl-C here stops polling only — re-run to
  # re-attach to the live guest build.
  echo "launching detached guest build (re-run to re-attach if interrupted)..."
  if ! "$SCRIPT_DIR/vm.sh" run env TAG="$TAG" OUTPUT_DIR="$VM_BOTTLES_DIR" TAP_ROOT_URL="${TAP_ROOT_URL:-}" FARM_TAP_NAME="$FARM_TAP_NAME" TAP_USER="$TAP_USER" TAP_REPO_NAME="$TAP_REPO_NAME" FARM_KEEP_INSTALLED=1 FARM_END_CLEANUP=1 HOMEBREW_NO_AUTO_UPDATE=1 FARM_RESUME="${FARM_RESUME:-0}" bash /tmp/shared/scripts/guest-build-detached.sh /tmp/shared/build-queue.txt 2>&1 | sed 's/^/  build-launch: /'; then
    echo "error: detached guest launch failed" >&2
    echo "hint: VM_USER=<gui-user> ./scripts/vm.sh ssh bash  # to inspect the guest" >&2
    exit 1
  fi
  echo "polling guest completion (/tmp/farm-build.rc)..."
  while true; do
    sleep 60
    if "$SCRIPT_DIR/vm.sh" run test -f /tmp/farm-build.rc 2>/dev/null; then
      break
    fi
    # Still building (or transport hiccup) — show a pulse, keep polling.
    "$SCRIPT_DIR/vm.sh" run "ls /tmp/shared/bottles/*.tar.gz 2>/dev/null | wc -l" 2>/dev/null | sed 's/^/  build: bottles so far: /' || true
    "$SCRIPT_DIR/vm.sh" run "tail -n 3 /tmp/farm-build.out 2>/dev/null" 2>/dev/null | sed 's/^/  build: /' || true
  done
  _guest_rc="$("$SCRIPT_DIR/vm.sh" run cat /tmp/farm-build.rc 2>/dev/null || echo "unknown")"
  echo "guest build finished (rc=$_guest_rc)"
  if [[ "$_guest_rc" != "0" ]]; then
    echo "error: VM build failed (rc=$_guest_rc)" >&2
    echo "hint: VM_USER=<gui-user> ./scripts/vm.sh ssh bash  # to inspect /tmp/build-*.log on the guest" >&2
    echo "hint: collecting partial artifacts from $VM_BOTTLES_DIR" >&2
    # Try to collect whatever was built (dispatch; never via shared-folder mount)
    "$SCRIPT_DIR/vm.sh" pull "$VM_BOTTLES_DIR/" "$BOTTLES_DIR/" 2>&1 | sed 's/^/  collect-partial: /' || true
    exit 1
  fi

  # Collect artifacts from the guest (dispatch; the old shared-folder-mount
  # assumption is gone — guest→host never worked that way)
  echo "collecting bottles $VM_BOTTLES_DIR -> $BOTTLES_DIR (transport $FARM_TRANSPORT)"
  if "$SCRIPT_DIR/vm.sh" run "ls $VM_BOTTLES_DIR/*.tar.gz" >/dev/null 2>&1; then
    "$SCRIPT_DIR/vm.sh" pull "$VM_BOTTLES_DIR/" "$BOTTLES_DIR/" 2>&1 | sed 's/^/  collect: /' || {
      echo "error: bottle collect failed" >&2
      exit 1
    }
    # Clear guest bottles to avoid re-upload on next run (noglob find, same
    # ssh-reparse/zsh rationale as the from-scratch clear above)
    "$SCRIPT_DIR/vm.sh" run noglob find "$VM_BOTTLES_DIR" -maxdepth 1 -name '*.tar.gz' -print -delete 2>/dev/null || true
    "$SCRIPT_DIR/vm.sh" run noglob find "$VM_BOTTLES_DIR" -maxdepth 1 -name '*.json' -print -delete 2>/dev/null || true
    "$SCRIPT_DIR/vm.sh" run noglob find /tmp/shared/Formula -maxdepth 1 -name '*.rb' -print -delete 2>/dev/null || true
  else
    echo "warn: no bottles found after VM build" >&2
    "$SCRIPT_DIR/vm.sh" run "ls -lh $VM_BOTTLES_DIR" 2>&1 | sed 's/^/  /' || true
    ls -lh "$BOTTLES_DIR" 2>&1 | sed 's/^/  /' || true
    exit 1
  fi
  ls -lh "$BOTTLES_DIR" | sed 's/^/  /'
fi

# 2b. Post-build linkage gate (ensure patched formulae didn't leak external toolchain)
echo ""
echo ">>> 2b/4 linkage check (patched formulae must not link external python/rust/go)"
# VM: brew linkage --test for each built bottle (if available)
# Host fallback: warn — full check happens in VM's build.sh linkage step; here we just list
if ls "$BOTTLES_DIR"/*.tar.gz >/dev/null 2>&1; then
  echo "  bottles built: $(ls -1 "$BOTTLES_DIR"/*.tar.gz | wc -l | tr -d ' ') (linkage verified inside VM: brew linkage --test, otool -L)"
fi

# 3. Publish (never in --local mode: host bottles are non-canonical)
if [[ "$LOCAL_MODE" == "true" ]]; then
  echo ""
  echo ">>> 3/4 publish — untouched (--local dry path)"
  echo "local artifacts in $LOCAL_OUTPUT (non-canonical; VM stays the bottle source)"
  echo "=== orchestrate --local done ==="
  exit 0
fi
if [[ "$SKIP_PUBLISH" == "true" ]]; then
  echo ""
  echo ">>> 3/4 publish — skipped (--skip-publish)"
  echo "bottles ready in $BOTTLES_DIR, run ./scripts/publish.sh when ready"
  exit 0
fi

echo ""
echo ">>> 3/4 publish (gh releases + bottle merge)"
if [[ "$DRY_RUN" == "true" ]]; then
  "$SCRIPT_DIR/publish.sh" --dry-run --bottles-dir "$BOTTLES_DIR"
else
  "$SCRIPT_DIR/publish.sh" --bottles-dir "$BOTTLES_DIR"
fi

echo ""
echo "=== orchestrate done ==="
echo "next: git -C $ROOT_DIR push"
echo "then: brew tap <user>/tap && brew install <user>/tap/<formula>"
