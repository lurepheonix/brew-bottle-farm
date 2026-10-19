#!/usr/bin/env bash
set -euo pipefail

# Host JSON helper: plain python3 only — never the VM's asdf slots.
# The repo .tool-versions pins VM-only interpreters; if the asdf shim
# cannot satisfy them on this host, drop it so brewed/system python3 is used.
if ! python3 -c 'pass' >/dev/null 2>&1; then
  PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '/\.asdf/shims' | paste -sd: -)"
fi

# orchestrate.sh — host glue: sync → VM build → publish
# Usage: ./scripts/orchestrate.sh [--dry-run] [--skip-vm] [--skip-publish] [--tag sequoia] [--force]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG="${TAG:-sequoia}"
DRY_RUN="false"
SKIP_VM="false"
SKIP_PUBLISH="false"
FORCE="false"
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
    -h|--help) cat <<'EOF'
Usage: ./scripts/orchestrate.sh [--dry-run] [--skip-vm] [--skip-publish] [--tag sequoia] [--force]
  --dry-run      sync dry-run + build dry-run (no VM, no publish)
  --skip-vm      assume build-queue.txt already built, skip VM build, go straight to publish
  --skip-publish run sync+VM build but do not publish (leave bottles in ./bottles)
  --force        force rebuild all (sync --force)
  --tag          bottle tag
EOF
      exit 0 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done

echo "=== orchestrate (tag $TAG, dry-run $DRY_RUN, force $FORCE) ==="
echo "root: $ROOT_DIR"
echo "vm: $VM_NAME shared: $SHARED_DIR -> $VM_BOTTLES_DIR"
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
# Ensure Formulae for queued items exist, then apply patches
# publish.sh:ensure_formula is not idempotent here, so do a lightweight mirror
for f in $(cat "$QUEUE_FILE"); do
  dest="$ROOT_DIR/Formula/$f.rb"
  if [[ ! -f "$dest" ]]; then
    echo "mirroring Formula/$f.rb..."
    mkdir -p "$ROOT_DIR/Formula"
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
else
  echo "no patches/series — skipping patch step"
fi

# 2. VM build — now with toolchain provision
if [[ "$SKIP_VM" == "true" ]]; then
  echo ""
  echo ">>> 2/3 VM build — skipped (--skip-vm)"
else
  echo ""
  echo ">>> 2/3 VM build ($VM_NAME)"
  mkdir -p "$SHARED_DIR"
  mkdir -p "$BOTTLES_DIR"
  # Stage everything the VM needs (shared helper — same as manual `vm.sh shared-sync`;
  # transport is rsync over SSH, re-resolving the DHCP IP each run)
  "$SCRIPT_DIR/vm.sh" shared-sync 2>&1 | sed 's/^/  shared-sync: /' || true
  # Ensure queue is fresh (shared-sync copies stale queue if present; overwrite with current)
  cp -v "$QUEUE_FILE" "$SHARED_DIR/build-queue.txt" 2>&1 | sed 's/^/  /' || true
  # Push the fresh queue into the VM over SSH (replaces the old `cat | prlctl exec` pipe).
  "$SCRIPT_DIR/vm.sh" rsync-to "$QUEUE_FILE" /tmp/shared/build-queue.txt 2>&1 | sed 's/^/  queue-push: /' || {
    echo "error: queue push failed — run: VM_USER=<gui-user> ./scripts/vm.sh ssh-setup" >&2
    exit 1
  }
  # Start VM if not running (reuses persistent VM — setup once, snapshot clean/toolchain-ready)
  echo "ensuring VM running (reused, setup once)..."
  if ! "$SCRIPT_DIR/vm.sh" status 2>&1 | grep -q "running"; then
    "$SCRIPT_DIR/vm.sh" start || {
      echo "error: could not start VM $VM_NAME" >&2
      echo "hint: ./scripts/vm.sh status; ./scripts/vm.sh create if missing" >&2
      exit 1
    }
  fi
  # Ensure shared dirs exist inside VM (over SSH; prlctl exec stays for bootstrap only)
  "$SCRIPT_DIR/vm.sh" ssh mkdir -p "$VM_BOTTLES_DIR" 2>/dev/null || {
    echo "error: SSH mkdir failed — run: VM_USER=<gui-user> ./scripts/vm.sh ssh-setup" >&2
    exit 1
  }
  "$SCRIPT_DIR/vm.sh" ssh mkdir -p "/tmp/shared/Formula" 2>/dev/null || true
  # Provision external toolchains in VM (rustup + go + asdf python) — idempotent, skipped if snapshot toolchain-ready
  echo "provisioning toolchain in VM (rustup + go + uv/asdf runtimes per build-deps.conf)..."
  cp -v "$SCRIPT_DIR/toolchain.sh" "$SHARED_DIR/scripts/toolchain.sh"
  if ! "$SCRIPT_DIR/vm.sh" ssh bash /tmp/shared/scripts/toolchain.sh 2>&1 | sed 's/^/  toolchain: /'; then
    echo "error: toolchain provision failed" >&2
    echo "hint: ./scripts/vm.sh ssh bash  # to inspect" >&2
    exit 1
  fi

  # Determine tap root URL from host git remote
  remote=$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || true)
  tap_root_url=""
  if [[ "$remote" =~ github.com[:/]([^/]+)/([^/.]+) ]]; then
    gh_user="${BASH_REMATCH[1]}"
    gh_repo="${BASH_REMATCH[2]%.git}"
    # build.sh will construct per-formula root_url as https://github.com/$gh_user/$gh_repo/releases/download/<formula>-<ver>
    # Pass base for info
    echo "tap: $gh_user/$gh_repo"
  else
    echo "warn: no GitHub remote, per-formula root_url will use placeholder — set remote.origin.url" >&2
  fi

  echo "executing build.sh inside VM (sources /tmp/shared/toolchain.env, uses external rust/go)..."
  # Copy build.sh into shared so VM can run it
  cp -v "$SCRIPT_DIR/build.sh" "$SHARED_DIR/scripts/build.sh"
  # Also copy patched Formulae into VM's shared Formula cache so `brew cat` sees patches
  # (VM's homebrew will still read from Formula/*.rb we mirrored)
  if [[ -d "$SHARED_DIR/Formula" ]]; then
    echo "patched Formulae available at /tmp/shared/Formula (VM can diff vs /usr/local/Homebrew if needed)"
  fi
  # Run inside VM over SSH — build.sh will source /tmp/shared/toolchain.env
  # (env vars for TAG/OUTPUT_DIR travel as the remote command, no prlctl flag parsing involved)
  # Re-push build.sh itself first so the guest always runs the current version.
  "$SCRIPT_DIR/vm.sh" rsync-to "$SCRIPT_DIR/build.sh" /tmp/shared/scripts/build.sh 2>&1 | sed 's/^/  stage-build: /' || {
    echo "error: build.sh stage failed" >&2
    exit 1
  }
  if ! "$SCRIPT_DIR/vm.sh" ssh env TAG="$TAG" OUTPUT_DIR="$VM_BOTTLES_DIR" bash /tmp/shared/scripts/build.sh /tmp/shared/build-queue.txt 2>&1 | sed 's/^/  build: /'; then
    echo "error: VM build failed" >&2
    echo "hint: ./scripts/vm.sh ssh bash  # to inspect /tmp/build-*.log inside VM" >&2
    echo "hint: collecting partial artifacts from $VM_BOTTLES_DIR" >&2
    # Try to collect whatever was built (over SSH; never via shared-folder mount)
    "$SCRIPT_DIR/vm.sh" rsync-from "$VM_BOTTLES_DIR/" "$BOTTLES_DIR/" 2>&1 | sed 's/^/  collect-partial: /' || true
    exit 1
  fi

  # Collect artifacts from the guest over SSH (rsync-from; the old
  # shared-folder-mount assumption is gone — guest→host never worked that way)
  echo "collecting bottles $VM_BOTTLES_DIR -> $BOTTLES_DIR (rsync over SSH)"
  if "$SCRIPT_DIR/vm.sh" ssh "ls $VM_BOTTLES_DIR/*.tar.gz" >/dev/null 2>&1; then
    "$SCRIPT_DIR/vm.sh" rsync-from "$VM_BOTTLES_DIR/" "$BOTTLES_DIR/" 2>&1 | sed 's/^/  collect: /' || {
      echo "error: bottle collect failed" >&2
      exit 1
    }
    # Clear guest bottles to avoid re-upload on next run
    "$SCRIPT_DIR/vm.sh" ssh rm -v "$VM_BOTTLES_DIR"/*.tar.gz "$VM_BOTTLES_DIR"/*.json 2>/dev/null || true
    "$SCRIPT_DIR/vm.sh" ssh rm -v /tmp/shared/Formula/*.rb 2>/dev/null || true
  else
    echo "warn: no bottles found after VM build" >&2
    "$SCRIPT_DIR/vm.sh" ssh "ls -lh $VM_BOTTLES_DIR" 2>&1 | sed 's/^/  /' || true
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

# 3. Publish
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
