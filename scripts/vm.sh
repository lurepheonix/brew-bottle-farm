#!/usr/bin/env bash
set -euo pipefail

# vm.sh — Parallels VM helpers for brew-sequoia (Intel host, Intel guest)
# Usage: ./scripts/vm.sh <create|start|stop|suspend|resume|status|snapshot|exec|scp> [args...]
#
# VM defaults: name brew-sequoia, 8 vCPU, 16GB RAM, 80GB disk, macOS 15
# Requires: prlctl (Parallels Desktop 26.3+), Parallels Tools in guest for shared folders

VM_NAME="${VM_NAME:-brew-sequoia}"
VM_USER="${VM_USER:-}"
VM_CPUS="${VM_CPUS:-8}"
VM_MEM="${VM_MEM:-16384}" # MB
VM_DISK="${VM_DISK:-80000}" # MB
SHARED_DIR="${SHARED_DIR:-$HOME/Parallels/shared-brew}"
VM_IP_CACHE="/tmp/$VM_NAME.ip"

# Resolve the GUI (non-root) user inside the guest.
# Order: $VM_USER env -> owner of /dev/console (queried as root) -> empty.
resolve_vm_user() {
  if [[ -n "${VM_USER:-}" ]]; then
    echo "$VM_USER"
    return 0
  fi
  local owner
  owner=$(prlctl exec "$VM_NAME" stat -f %Su /dev/console 2>/dev/null || true)
  owner="$(echo "$owner" | tr -d '[:space:]')"
  if [[ -n "$owner" && "$owner" != "root" ]]; then
    echo "$owner"
    return 0
  fi
  echo ""
}

# Low-level runners: root (system tasks) vs user (brew/rust/asdf/toolchain/build).
vm_exec_root() {
  prlctl exec "$VM_NAME" "$@"
}
vm_exec_user() {
  local user
  user="$(resolve_vm_user)"
  if [[ -z "$user" ]]; then
    echo "warn: VM_USER unresolved — running as root (rust/brew will fail with HOME=/)." >&2
    echo "hint: export VM_USER=<gui-user> or ensure guest is logged in." >&2
    prlctl exec "$VM_NAME" "$@"
  else
    prlctl exec "$VM_NAME" --user "$user" "$@"
  fi
}

usage() {
  cat <<'EOF'
Usage: ./scripts/vm.sh <command> [args]

Commands:
  create               Create VM brew-sequoia (prompts for macOS IPSW/ISO path)
  status               prlctl list + info
  start                prlctl start (or resume if suspended)
  stop                 prlctl stop --kill
  suspend              prlctl suspend
  resume               prlctl resume
  restart              prlctl restart
  snapshot [name]      prlctl snapshot <VM> (default: clean)
  snapshot-list        prlctl snapshot-list
  snapshot-switch <id> prlctl snapshot-switch
  snapshot-delete <id> prlctl snapshot-delete
  exec <cmd> [...]     run as GUI user via prlctl exec --user $VM_USER (auto-detected
                       from /dev/console; override with VM_USER=<name>)
  exec-as-root <cmd> [...]  run as root (plain prlctl exec; for /usr/local ops/debug)
  scp <src> <dest>     helper: prlctl + scp via shared folder or prlcopy
  ip                   print guest IP
  ssh [cmd]            ssh into VM (requires ssh enabled, uses prlctl exec to get IP)
  shared-setup         setup shared folder host -> /Volumes/SharedFolders/shared inside guest
  shared-sync          stage toolchain + patches + queue: host $SHARED_DIR → VM $VM_GUEST_SHARED (tar+base64)
  shared-stage         transfer $SHARED_DIR into VM $VM_GUEST_SHARED only (no host sync)

Env:
  VM_NAME=brew-sequoia VM_CPUS=8 VM_MEM=16384 VM_DISK=80000
  VM_USER=<guest gui user> (default: auto-detect owner of /dev/console)
  Example: VM_USER=<gui-user> ./scripts/vm.sh exec bash /tmp/shared/scripts/toolchain.sh
EOF
}

vm_exists() {
  prlctl list -a 2>/dev/null | grep -q "$VM_NAME"
}

cmd_create() {
  if vm_exists; then
    echo "error: VM $VM_NAME already exists (prlctl list -a)" >&2
    prlctl list -a | sed 's/^/  /'
    exit 1
  fi
  echo "Creating Parallels VM $VM_NAME ($VM_CPUS cpus, ${VM_MEM}MB RAM, ${VM_DISK}MB disk)"
  echo "Parallels macOS guest requires manual ISO/IPSW selection in GUI."
  echo ""
  echo "Steps:"
  echo "  1. Verify available installers:"
  echo "     mist list installer \"Sequoia\"        # should show 15.7.9 / 24G830 / ~16 GB"
  echo "     mist list installer \"15.7.9\""
  echo "  2. Download Sequoia installer ISO for Parallels (use ISO, not IPSW):"
  echo "     # On Intel hosts like this one (x86_64), you need an ISO — IPSW/firmware is Apple Silicon only."
  echo "     # mist syntax is: mist download installer <search> <output-type>"
  echo "     sudo mist download installer \"15.7.9\" iso --iso-name \"Sequoia-15.7.9-%BUILD%.iso\" -f"
  echo "     # Tip: add --output-directory ~/Downloads to control where the .iso lands; otherwise check /Users/Shared/Mist or ~/Downloads."
  echo "     # If you truly need an IPSW (Apple Silicon host only): mist download firmware \"15.7.9\" -f"
  echo "     # BROKEN (mist 2.3 has no such flags): mist download --os macOS --version 15.7.9 --output ~/Downloads/Sequoia.ipsw"
  echo "  3. Open Parallels Desktop -> File -> New -> Install macOS from ISO/IPSW"
  echo "     Pick the downloaded .iso (Intel) or .ipsw (Apple Silicon). Name the VM \"$VM_NAME\"."
  echo "  4. After the VM is created, run (or press Enter to auto-configure):"
  echo "     prlctl set $VM_NAME --cpus $VM_CPUS --memsize $VM_MEM"
  echo "     prlctl set $VM_NAME --device-set hdd0 --size $VM_DISK"
  echo "     prlctl set $VM_NAME --shf-host-add shared --path $SHARED_DIR --mode rw"
  echo ""
  read -rp "After creating VM in GUI, press Enter to configure, or Ctrl-C to abort... "
  if vm_exists; then
    echo "configuring $VM_NAME..."
    prlctl set "$VM_NAME" --cpus "$VM_CPUS" --memsize "$VM_MEM" || true
    prlctl set "$VM_NAME" --shf-host-add shared --path "$SHARED_DIR" --mode rw 2>/dev/null || echo "warn: shared folder setup needs VM running + Tools" >&2
    mkdir -p "$SHARED_DIR"
    echo "created shared dir $SHARED_DIR -> VM /Volumes/SharedFolders/shared (mount via Parallels Tools)"
    echo "note: /Volumes/SharedFolders/ is TCC-restricted in Sequoia — use 'shared-sync' to stage to VM /tmp/shared/"
    echo "next:"
    echo "  1. prlctl start $VM_NAME   # open VM window, finish Sequoia setup"
    echo "  2. Inside the VM's Terminal.app (GUI session required):"
    echo "     xcode-select --install   # pops GUI dialog — WON'T work via 'vm.sh exec' headless"
    echo "     # then: brew install (/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"), gh, gnu-tar"
    echo "  3. Back on host: ./scripts/vm.sh snapshot clean"
  else
    echo "VM not found — create it in GUI first" >&2
    exit 1
  fi
}

cmd_status() {
  echo "=== prlctl list -a ==="
  prlctl list -a | sed 's/^/  /' || true
  echo ""
  if vm_exists; then
    echo "=== prlctl list -i $VM_NAME ==="
    prlctl list -i "$VM_NAME" 2>&1 | head -n 100 | sed 's/^/  /' || true
    echo ""
    echo "=== snapshots ==="
    prlctl snapshot-list "$VM_NAME" 2>&1 | sed 's/^/  /' || true
  fi
}

cmd_start() {
  if ! vm_exists; then
    echo "error: VM $VM_NAME not found" >&2; exit 1
  fi
  status=$(prlctl list -a 2>/dev/null | grep "$VM_NAME" | awk '{print $2}' || true)
  echo "VM status: $status"
  if [[ "$status" == "suspended" ]]; then
    prlctl resume "$VM_NAME"
  elif [[ "$status" == "stopped" ]]; then
    prlctl start "$VM_NAME"
  elif [[ "$status" == "running" ]]; then
    echo "already running"
  else
    prlctl start "$VM_NAME" || prlctl resume "$VM_NAME" || true
  fi
  echo "waiting for Tools/IP..."
  for i in {1..30}; do
    ip=$(prlctl exec "$VM_NAME" ipconfig getifaddr en0 2>/dev/null || prlctl list -a 2>/dev/null | grep "$VM_NAME" | awk '{print $3}' || true)
    if [[ -n "$ip" && "$ip" != "-" ]]; then
      echo "IP: $ip"
      echo "$ip" > "$VM_IP_CACHE"
      break
    fi
    sleep 2
  done
}

cmd_stop() {
  prlctl stop "$VM_NAME" --kill 2>/dev/null || prlctl stop "$VM_NAME" 2>/dev/null || true
}

cmd_suspend() { prlctl suspend "$VM_NAME"; }
cmd_resume() { prlctl resume "$VM_NAME"; }
cmd_restart() { prlctl restart "$VM_NAME"; }

cmd_snapshot() {
  local name="${1:-clean}"
  echo "snapshot $VM_NAME -> $name"
  prlctl snapshot "$VM_NAME" --name "$name"
}

cmd_snapshot_list() { prlctl snapshot-list "$VM_NAME"; }
cmd_snapshot_switch() { prlctl snapshot-switch "$VM_NAME" --id "$1"; }
cmd_snapshot_delete() { prlctl snapshot-delete "$VM_NAME" --id "$1"; }

cmd_exec() {
  if [[ $# -eq 0 ]]; then
    echo "usage: $0 exec <cmd> [...]" >&2; exit 1
  fi
  # Guard: GUI-gated commands need a WindowServer session — headless prlctl exec can't show dialogs.
  # Known offender: `xcode-select --install` pops a GUI prompt. Fail fast with a hint instead of hanging.
  if [[ "$1" == "xcode-select" && " $* " == *" --install"* ]]; then
    echo "error: 'xcode-select --install' requires a GUI session (pops a macOS dialog)" >&2
    echo "hint: run it inside the VM's Terminal.app, not via 'vm.sh exec' (see cmd_create steps)" >&2
    echo "      After it finishes: ./scripts/vm.sh snapshot clean" >&2
    return 2
  fi
  # Run as the GUI user so HOME is /Users/<user> (not /) — rustup/brew/asdf refuse root+HOME=/.
  vm_exec_user "$@"
}

cmd_exec_root() {
  if [[ $# -eq 0 ]]; then
    echo "usage: $0 exec-as-root <cmd> [...]" >&2; exit 1
  fi
  vm_exec_root "$@"
}

cmd_scp() {
  # Use shared folder as transport: host $SHARED_DIR <-> guest /Volumes/SharedFolders/shared/
  # For arbitrary paths, fallback to prlcopy or scp via IP
  if [[ $# -ne 2 ]]; then
    echo "usage: $0 scp <host-src> <guest-dest>  or  <guest-src> <host-dest>" >&2
    echo "hint: use shared folder $SHARED_DIR for bulk bottles: cp $ROOT/bottles/* $SHARED_DIR/" >&2
    exit 1
  fi
  echo "hint: use cp to $SHARED_DIR for shared folder transport" >&2
  echo "  cp $1 $2"
  cp -v "$1" "$2"
}

cmd_ip() {
  prlctl list -a 2>/dev/null | grep "$VM_NAME" | awk '{print $3}' | sed 's/^/  /'
  vm_exec_root ipconfig getifaddr en0 2>/dev/null | sed 's/^/  guest en0: /' || true
}

cmd_ssh() {
  local ip
  ip=$(cat "$VM_IP_CACHE" 2>/dev/null || prlctl list -a 2>/dev/null | grep "$VM_NAME" | awk '{print $3}' || true)
  if [[ -z "$ip" || "$ip" == "-" ]]; then
    echo "error: VM IP unknown, is VM running?" >&2; exit 1
  fi
  # Assume same username as host
  user=$(whoami)
  if [[ $# -eq 0 ]]; then
    ssh "$user@$ip"
  else
    ssh "$user@$ip" "$@"
  fi
}

cmd_shared_setup() {
  mkdir -p "$SHARED_DIR"
  echo "host shared dir: $SHARED_DIR"
  if vm_exists; then
    prlctl set "$VM_NAME" --shf-host-add shared --path "$SHARED_DIR" --mode rw 2>&1 | sed 's/^/  /' || true
    echo "guest mount point: /Volumes/SharedFolders/shared (Parallels Tools shared folders, auto-mounted after Tools install)"
    echo "note: macOS Sequoia TCC blocks direct access — use 'shared-sync' to stage files to VM /tmp/shared/"
  fi
}

VM_GUEST_SHARED="${VM_GUEST_SHARED:-/tmp/shared}"

cmd_shared_stage() {
  # Transfer host $SHARED_DIR into VM at $VM_GUEST_SHARED via tar+base64 pipe
  # (bypasses macOS Sequoia TCC blocking open() on /Volumes/SharedFolders/)
  if ! vm_exists; then
    echo "error: VM $VM_NAME not found" >&2; exit 1
  fi
  if [[ ! -d "$SHARED_DIR" ]]; then
    echo "error: host shared dir $SHARED_DIR does not exist — run shared-sync first" >&2; exit 1
  fi
  echo "staging $SHARED_DIR -> VM $VM_GUEST_SHARED ..."
  # Prefer user context so staged files are owned by the GUI user (toolchain runs as user).
  # Fall back to root + chown when the GUI user cannot be resolved.
  staged_user=""
  if vm_exec_user mkdir -p "$VM_GUEST_SHARED" 2>&1 | sed 's/^/  /'; then
    staged_user="$(resolve_vm_user)"
  else
    vm_exec_root mkdir -p "$VM_GUEST_SHARED" 2>&1 | sed 's/^/  /'
  fi
  # tar+base64 pipe: host filesystem → stdin → base64 → prlctl exec → decode → tar extract
  if [[ -n "$staged_user" ]]; then
    if ! tar czf - -C "$SHARED_DIR" . | base64 | prlctl exec "$VM_NAME" --user "$staged_user" "base64 -d | tar xzf - -C $VM_GUEST_SHARED" 2>&1 | sed 's/^/  /'; then
      echo "error: tar+base64 transfer failed" >&2; exit 1
    fi
  else
    if ! tar czf - -C "$SHARED_DIR" . | base64 | vm_exec_root "base64 -d | tar xzf - -C $VM_GUEST_SHARED" 2>&1 | sed 's/^/  /'; then
      echo "error: tar+base64 transfer failed" >&2; exit 1
    fi
  fi
  echo "staged. Verifying..."
  vm_exec_root ls -la "$VM_GUEST_SHARED/" 2>&1 | sed 's/^/  /'
}

cmd_shared_sync() {
  # Stage everything the VM needs via host $SHARED_DIR → VM $VM_GUEST_SHARED
  # Mirrors repo structure so scripts/toolchain.sh resolves ROOT_DIR correctly
  local root
  root="$(cd "$(dirname "$0")/.." && pwd)"
  mkdir -p "$SHARED_DIR"
  # Clean stale flat copies from old layout (toolchain.sh/build.sh now live under scripts/)
  rm -f "$SHARED_DIR/toolchain.sh" "$SHARED_DIR/build.sh" 2>/dev/null || true
  echo "syncing to $SHARED_DIR (→ guest $VM_GUEST_SHARED)..."
  # Mirror repo structure: scripts/, build-deps.conf, .tool-versions at root level
  mkdir -p "$SHARED_DIR/scripts"
  for f in "$root/build-deps.conf" "$root/.tool-versions"; do
    if [[ -f "$f" ]]; then
      cp -v "$f" "$SHARED_DIR/" 2>&1 | sed 's/^/  /'
    fi
  done
  for f in "$root/scripts/toolchain.sh" "$root/scripts/build.sh"; do
    if [[ -f "$f" ]]; then
      cp -v "$f" "$SHARED_DIR/scripts/" 2>&1 | sed 's/^/  /'
    fi
  done
  # queue (if present)
  if [[ -f "$root/build-queue.txt" ]]; then
    cp -v "$root/build-queue.txt" "$SHARED_DIR/" 2>&1 | sed 's/^/  /'
  fi
  # patches + Formula (mirrored)
  if [[ -d "$root/patches" ]]; then
    mkdir -p "$SHARED_DIR/patches"
    cp -v "$root/patches/series" "$SHARED_DIR/patches/" 2>&1 | sed 's/^/  /' || true
    # copy only referenced patches to keep staging small
    if [[ -f "$SHARED_DIR/patches/series" ]]; then
      while IFS= read -r p; do
        [[ -z "$p" || "$p" == \#* ]] && continue
        cp -v "$root/patches/$p" "$SHARED_DIR/patches/" 2>&1 | sed 's/^/  /' || echo "  warn: patch $p not found" >&2
      done < <(grep -v '^[[:space:]]*#' "$SHARED_DIR/patches/series" | grep -v '^[[:space:]]*$' || true)
    fi
  fi
  if [[ -d "$root/Formula" ]]; then
    mkdir -p "$SHARED_DIR/Formula"
    cp -v "$root/Formula/"*.rb "$SHARED_DIR/Formula/" 2>&1 | sed 's/^/  /' || echo "  (no Formula/*.rb yet)"
  fi
  mkdir -p "$SHARED_DIR/bottles"
  echo "host sync done. Now staging into VM..."
  cmd_shared_stage
  echo "shared sync complete. Guest sees:"
  echo "  $VM_GUEST_SHARED/scripts/toolchain.sh  $VM_GUEST_SHARED/scripts/build.sh"
  echo "  $VM_GUEST_SHARED/build-deps.conf  $VM_GUEST_SHARED/.tool-versions"
  echo "  $VM_GUEST_SHARED/build-queue.txt  $VM_GUEST_SHARED/patches/  $VM_GUEST_SHARED/Formula/  $VM_GUEST_SHARED/bottles/"
}

case "${1:-}" in
  create) cmd_create ;;
  status|list) cmd_status ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  suspend) cmd_suspend ;;
  resume) cmd_resume ;;
  restart) cmd_restart ;;
  snapshot) shift; cmd_snapshot "${1:-}" ;;
  snapshot-list) cmd_snapshot_list ;;
  snapshot-switch) shift; cmd_snapshot_switch "$1" ;;
  snapshot-delete) shift; cmd_snapshot_delete "$1" ;;
  exec) shift; cmd_exec "$@" ;;
  exec-as-root) shift; cmd_exec_root "$@" ;;
  scp) shift; cmd_scp "$@" ;;
  ip) cmd_ip ;;
  ssh) shift; cmd_ssh "$@" ;;
  shared-setup) cmd_shared_setup ;;
  shared-sync) cmd_shared_sync ;;
  shared-stage) cmd_shared_stage ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $1" >&2; usage; exit 1 ;;
esac
