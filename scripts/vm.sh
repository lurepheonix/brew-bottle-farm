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
SSH_KEY="${SSH_KEY:-$HOME/.ssh/brew-farm}"
VM_GUEST_SHARED="${VM_GUEST_SHARED:-/tmp/shared}"
# Transport dispatch (Phase 2): ssh | prlctl | local. Default ssh.
#   ssh    — steady-state transport (key-only SSH + rsync). Re-resolves DHCP IP
#            each run; requires explicit VM_USER (auto-detect is flaky).
#   prlctl — bootstrap/control plane only (prlctl exec as GUI user). run works;
#            push/pull fail closed (no pipe transport — use ssh).
#   local  — host-local dry path: run in place, copy via cp. No guest, no SSH.
FARM_TRANSPORT="${FARM_TRANSPORT:-ssh}"

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

# Re-resolve the guest DHCP IP on every run (never trust a stale cache).
# Order: guest en0 via prlctl exec -> prlctl list -> cache. Validates IPv4,
# updates the cache, prints the IP. (prlctl use here is bootstrap/control plane.)
resolve_vm_ip() {
  local ip=""
  ip=$(prlctl exec "$VM_NAME" ipconfig getifaddr en0 2>/dev/null | tr -d '[:space:]' || true)
  if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip=$(prlctl list -a 2>/dev/null | grep "$VM_NAME" | awk '{print $3}' | tr -d '[:space:]' || true)
  fi
  if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip=$(cat "$VM_IP_CACHE" 2>/dev/null | tr -d '[:space:]' || true)
  fi
  if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: guest IP unknown (DHCP re-resolve failed) — is the VM running?" >&2
    echo "hint: ./scripts/vm.sh status; ./scripts/vm.sh start" >&2
    return 1
  fi
  echo "$ip" > "$VM_IP_CACHE"
  echo "$ip"
}

# Resolve user for ssh/rsync: explicit VM_USER preferred (auto-detect is flaky).
resolve_ssh_user() {
  local user
  user="$(resolve_vm_user)"
  if [[ -z "$user" ]]; then
    echo "error: VM_USER unresolved — export VM_USER=<guest-gui-user>" >&2
    return 1
  fi
  if [[ -z "${VM_USER:-}" ]]; then
    echo "warn: VM_USER unset, auto-detected '$user' (flaky) — export VM_USER=$user for reliability" >&2
  fi
  echo "$user"
}
# Low-level runners: root (system tasks) vs user (brew/rust/asdf/toolchain/build).
# prlctl exec stays for bootstrap/debug only; steady-state transport is ssh/rsync.
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
                       Bootstrap/debug only — steady-state transport is ssh/rsync.
  exec-as-root <cmd> [...]  run as root (plain prlctl exec; for /usr/local ops/debug)
  scp <src> <dest>     deprecated stub: use rsync-to/rsync-from (kept for compat)
  ip                   print guest IP (re-resolves DHCP, updates cache)
  ssh-setup [--reset]  one-time SSH bootstrap: host keypair ~/.ssh/brew-farm,
                       Remote Login on, seed key via root, ssh-keyscan known_hosts.
                       Requires explicit VM_USER. Uses prlctl exec (bootstrap).
  ssh [cmd]            run command as $VM_USER over SSH (key auth, no passwords).
                       No args = interactive shell. Re-resolves DHCP IP each run.
  rsync-to <src> <dst> host -> guest over SSH (e.g. rsync-to ./build-queue.txt /tmp/shared/)
  rsync-from <src> <dst> guest -> host over SSH (e.g. rsync-from /tmp/shared/bottles/ ./bottles/)
  run <cmd> [...]  transport-dispatched guest command (FARM_TRANSPORT=ssh|prlctl|local)
  push <src> <dst> transport-dispatched host -> guest copy (local mode: cp)
  pull <src> <dst> transport-dispatched guest -> host copy (local mode: cp)
  shared-setup         setup shared folder host -> /Volumes/SharedFolders/shared inside guest
  shared-sync          stage toolchain + patches + queue: host $SHARED_DIR → VM $VM_GUEST_SHARED (rsync over SSH)
  shared-stage         transfer $SHARED_DIR into VM $VM_GUEST_SHARED only (rsync over SSH, no host sync)

Env:
  VM_NAME=brew-sequoia VM_CPUS=8 VM_MEM=16384 VM_DISK=80000
  VM_USER=<guest gui user> (default: auto-detect owner of /dev/console)
  SSH_KEY=$HOME/.ssh/brew-farm (host keypair, never in repo)
  FARM_TRANSPORT=ssh|prlctl|local (default: ssh; prlctl = bootstrap only, local = host dry path)
  Example: VM_USER=<gui-user> ./scripts/vm.sh ssh-setup
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
  echo "deprecated: 'scp' is a compat stub — use rsync-to / rsync-from (SSH transport)." >&2
  echo "hint: ./scripts/vm.sh rsync-to <host-src> <guest-dest>" >&2
  echo "hint: ./scripts/vm.sh rsync-from <guest-src> <host-dest>" >&2
  if [[ $# -ne 2 ]]; then
    echo "usage: $0 scp <src> <dest>  (deprecated; prefer rsync-to/rsync-from)" >&2
    exit 1
  fi
  echo "  cp $1 $2"
  cp -v "$1" "$2"
}

cmd_ip() {
  local ip
  ip=$(resolve_vm_ip)
  echo "  $ip"
}

# One-time SSH bootstrap. Requires explicit VM_USER (auto-detect is flaky).
# Uses prlctl exec (bootstrap): enables Remote Login, seeds the host pubkey,
# refreshes host known_hosts (pruning stale DHCP entries), verifies login.
cmd_ssh_setup() {
  local reset="false"
  if [[ "${1:-}" == "--reset" ]]; then reset="true"; fi
  if [[ -z "${VM_USER:-}" ]]; then
    echo "error: VM_USER must be set explicitly for ssh-setup (auto-detect is flaky)" >&2
    echo "hint: VM_USER=<guest-gui-user> ./scripts/vm.sh ssh-setup" >&2
    exit 1
  fi
  if ! vm_exists; then
    echo "error: VM $VM_NAME not found" >&2; exit 1
  fi
  # 1. Host keypair (never in repo).
  if [[ ! -f "$SSH_KEY" ]]; then
    echo "generating host keypair $SSH_KEY (ed25519, no passphrase)..."
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "brew-farm $VM_NAME"
  elif [[ "$reset" == "true" ]]; then
    echo "keypair exists, keeping $SSH_KEY (--reset only refreshes known_hosts + guest seeding)"
  else
    echo "keypair exists: $SSH_KEY"
  fi
  chmod 600 "$SSH_KEY" 2>/dev/null || true
  # 2. Resolve guest IP (DHCP re-discovery; bootstrap prlctl use).
  local ip
  ip=$(resolve_vm_ip)
  echo "guest IP: $ip"
  # 3. Enable Remote Login (launchd directly — systemsetup needs FDA/TCC
  # that headless prlctl exec lacks; enable+bootstrap is equivalent).
  echo "enabling Remote Login..."
  if vm_exec_root systemsetup -getremotelogin 2>/dev/null | grep -qi "on"; then
    echo "  already on"
  else
    if ! vm_exec_root launchctl enable system/com.openssh.sshd 2>&1 | sed 's/^/  /'; then
      echo "error: launchctl enable failed" >&2
      echo "hint: in the VM open System Settings → General → Sharing → Remote Login (one-time GUI toggle)," >&2
      echo "hint: then re-run: VM_USER=$VM_USER ./scripts/vm.sh ssh-setup" >&2
      exit 1
    fi
    if ! vm_exec_root launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>&1 | sed 's/^/  /'; then
      echo "error: launchctl bootstrap failed" >&2
      echo "hint: in the VM open System Settings → General → Sharing → Remote Login (one-time GUI toggle)," >&2
      echo "hint: then re-run: VM_USER=$VM_USER ./scripts/vm.sh ssh-setup" >&2
      exit 1
    fi
  fi
  if ! vm_exec_root systemsetup -getremotelogin 2>&1 | grep -qi "on"; then
    echo "error: Remote Login still off after enable attempt" >&2
    echo "hint: in the VM open System Settings → General → Sharing → Remote Login (one-time GUI toggle)," >&2
    echo "hint: then re-run: VM_USER=$VM_USER ./scripts/vm.sh ssh-setup" >&2
    exit 1
  fi
  echo "  Remote Login on"
  # 4. Seed host pubkey via root (idempotent append).
  echo "seeding host pubkey for $VM_USER..."
  local pub
  pub=$(cat "$SSH_KEY.pub")
  vm_exec_root mkdir -p "/Users/$VM_USER/.ssh" 2>&1 | sed 's/^/  /'
  # Append only if not already present (grep exit 1 = absent, fine under if).
  if vm_exec_root "grep -qFx '$pub' /Users/$VM_USER/.ssh/authorized_keys" 2>/dev/null; then
    echo "  pubkey already seeded"
  else
    echo "$pub" | vm_exec_root "cat >> /Users/$VM_USER/.ssh/authorized_keys" 2>&1 | sed 's/^/  /'
    echo "  pubkey appended"
  fi
  vm_exec_root chmod 700 "/Users/$VM_USER/.ssh" 2>&1 | sed 's/^/  /' || true
  vm_exec_root chmod 600 "/Users/$VM_USER/.ssh/authorized_keys" 2>&1 | sed 's/^/  /' || true
  vm_exec_root chown -R "$VM_USER" "/Users/$VM_USER/.ssh" 2>&1 | sed 's/^/  /' || true
  # 5. Refresh host known_hosts: prune stale entries (old cache + current IP), re-scan.
  echo "refreshing host known_hosts..."
  local old_ip
  old_ip=$(cat "$VM_IP_CACHE" 2>/dev/null || true)
  if [[ -n "$old_ip" && "$old_ip" != "$ip" ]]; then
    ssh-keygen -R "$old_ip" >/dev/null 2>&1 || true
    echo "  pruned stale $old_ip"
  fi
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  if ! ssh-keyscan -t ed25519,rsa "$ip" >> ~/.ssh/known_hosts 2>/dev/null; then
    echo "error: ssh-keyscan failed for $ip" >&2; exit 1
  fi
  echo "  scanned $ip"
  # 6. Verify key login (no passwords, fail fast).
  echo "verifying SSH login..."
  # shellcheck disable=SC2086
  if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$VM_USER@$ip" "echo ok" 2>&1 | sed 's/^/  /'; then
    echo "error: SSH login failed for $VM_USER@$ip" >&2
    echo "hint: re-run with --reset; check Remote Login + authorized_keys in the VM" >&2
    exit 1
  fi
  echo "ssh-setup complete: $VM_USER@$ip (key $SSH_KEY)"
}

cmd_ssh() {
  local ip user
  ip=$(resolve_vm_ip)
  user=$(resolve_ssh_user)
  # shellcheck disable=SC2086
  if [[ $# -eq 0 ]]; then
    ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$user@$ip"
  else
    ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$user@$ip" "$@"
  fi
}

cmd_rsync_to() {
  if [[ $# -ne 2 ]]; then
    echo "usage: $0 rsync-to <host-src> <guest-dest>" >&2; exit 1
  fi
  command -v rsync >/dev/null || { echo "error: rsync not found on host" >&2; exit 1; }
  local ip user
  ip=$(resolve_vm_ip)
  user=$(resolve_ssh_user)
  # Ensure parent dir exists on the guest for file targets.
  # shellcheck disable=SC2086
  ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$user@$ip" "mkdir -p '$(dirname "$2")'" 2>&1 | sed 's/^/  /' || true
  # shellcheck disable=SC2086
  rsync -avz -e "ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes" "$1" "$user@$ip:$2" 2>&1 | sed 's/^/  /'
}

cmd_rsync_from() {
  if [[ $# -ne 2 ]]; then
    echo "usage: $0 rsync-from <guest-src> <host-dest>" >&2; exit 1
  fi
  command -v rsync >/dev/null || { echo "error: rsync not found on host" >&2; exit 1; }
  local ip user
  ip=$(resolve_vm_ip)
  user=$(resolve_ssh_user)
  mkdir -p "$(dirname "$2")"
  # shellcheck disable=SC2086
  rsync -avz -e "ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes" "$user@$ip:$1" "$2" 2>&1 | sed 's/^/  /'
}

# Transport dispatch (Phase 2). orchestrate.sh and callers use run/push/pull
# so the same flow works over ssh (VM steady-state), prlctl (bootstrap/
# debug only — push/pull fail closed, there is no pipe transport), and local
# (host dry path — commands run in place, copies via cp).
cmd_run() {
  case "$FARM_TRANSPORT" in
    ssh) cmd_ssh "$@" ;;
    prlctl) cmd_exec "$@" ;;
    local)
      if [[ $# -eq 0 ]]; then
        echo "usage: $0 run <cmd> [...] (FARM_TRANSPORT=local runs on host)" >&2; exit 1
      fi
      "$@" ;;
    *) echo "error: unknown FARM_TRANSPORT=$FARM_TRANSPORT (want ssh|prlctl|local)" >&2; exit 1 ;;
  esac
}

cmd_push() {
  if [[ $# -ne 2 ]]; then
    echo "usage: $0 push <host-src> <guest-dest>" >&2; exit 1
  fi
  case "$FARM_TRANSPORT" in
    ssh) cmd_rsync_to "$@" ;;
    prlctl)
      echo "error: FARM_TRANSPORT=prlctl has no copy transport — use ssh (or local)" >&2
      exit 1 ;;
    local)
      mkdir -p "$(dirname "$2")"
      if [[ -d "$1" ]]; then
        mkdir -p "$2"
        cp -R "$1/." "$2/"
      else
        cp -v "$1" "$2"
      fi ;;
    *) echo "error: unknown FARM_TRANSPORT=$FARM_TRANSPORT (want ssh|prlctl|local)" >&2; exit 1 ;;
  esac
}

cmd_pull() {
  if [[ $# -ne 2 ]]; then
    echo "usage: $0 pull <guest-src> <host-dest>" >&2; exit 1
  fi
  case "$FARM_TRANSPORT" in
    ssh) cmd_rsync_from "$@" ;;
    prlctl)
      echo "error: FARM_TRANSPORT=prlctl has no copy transport — use ssh (or local)" >&2
      exit 1 ;;
    local)
      mkdir -p "$(dirname "$2")"
      if [[ -d "$1" ]]; then
        mkdir -p "$2"
        cp -R "$1/." "$2/"
      else
        cp -v "$1" "$2"
      fi ;;
    *) echo "error: unknown FARM_TRANSPORT=$FARM_TRANSPORT (want ssh|prlctl|local)" >&2; exit 1 ;;
  esac
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

cmd_shared_stage() {
  # Transfer host $SHARED_DIR into VM at $VM_GUEST_SHARED via rsync over SSH.
  # (Replaces the old tar+base64 prlctl pipe, which is gone; Sequoia TCC still
  # blocks direct /Volumes/SharedFolders/ use, so rsync is the only transport.)
  if ! vm_exists; then
    echo "error: VM $VM_NAME not found" >&2; exit 1
  fi
  if [[ ! -d "$SHARED_DIR" ]]; then
    echo "error: host shared dir $SHARED_DIR does not exist — run shared-sync first" >&2; exit 1
  fi
  echo "staging $SHARED_DIR -> VM $VM_GUEST_SHARED (rsync over SSH)..."
  local ip user
  ip=$(resolve_vm_ip) || exit 1
  user=$(resolve_ssh_user) || exit 1
  # shellcheck disable=SC2086
  if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$user@$ip" "mkdir -p '$VM_GUEST_SHARED'" 2>&1 | sed 's/^/  /'; then
    echo "error: SSH mkdir failed — run: VM_USER=$user ./scripts/vm.sh ssh-setup" >&2; exit 1
  fi
  cmd_rsync_to "$SHARED_DIR/" "$VM_GUEST_SHARED/" || {
    echo "error: rsync transfer failed — run: VM_USER=$user ./scripts/vm.sh ssh-setup" >&2; exit 1
  }
  echo "staged. Verifying..."
  # shellcheck disable=SC2086
  ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$user@$ip" "ls -la '$VM_GUEST_SHARED/'" 2>&1 | sed 's/^/  /'
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
  # Stage the bottled farm-toolchain (bottled strategy: the VM hand-pours the
  # local bottle file; publish stays deferred so no tap/URL install).
  for _bf in "$root/bottles/farm-toolchain--"*.bottle.tar.gz "$root/bottles/farm-toolchain--"*.json; do
    [[ -e "$_bf" ]] || continue
    cp -v "$_bf" "$SHARED_DIR/bottles/" 2>&1 | sed 's/^/  /' || true
  done
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
  ssh-setup) shift; cmd_ssh_setup "${1:-}" ;;
  ssh) shift; cmd_ssh "$@" ;;
  rsync-to) shift; cmd_rsync_to "$@" ;;
  rsync-from) shift; cmd_rsync_from "$@" ;;
  run) shift; cmd_run "$@" ;;
  push) shift; cmd_push "$@" ;;
  pull) shift; cmd_pull "$@" ;;
  shared-setup) cmd_shared_setup ;;
  shared-sync) cmd_shared_sync ;;
  shared-stage) cmd_shared_stage ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $1" >&2; usage; exit 1 ;;
esac
