#!/usr/bin/env bash
set -euo pipefail
umask 022 # prlctl exec sessions can carry umask 000; keep provisioned files sane.

# vm-brew.sh — install Homebrew into the Intel VM without the official
# install.sh (which refuses non-Apple-Silicon processors).
# Host driver: privileged steps run via `vm.sh exec-as-root` (prlctl root,
# no password); brew steps run as the GUI user via `vm.sh exec`
# (Homebrew refuses to run as root). Idempotent: skips what is already done.
# Usage: ./scripts/vm-brew.sh [--check]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_NAME="${VM_NAME:-brew-sequoia}"
VM_USER="${VM_USER:-}"
BREW_PREFIX="/usr/local"
BREW_BIN="$BREW_PREFIX/bin/brew"
CHECK_ONLY="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY="true"; shift ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/vm-brew.sh [--check]
  Install Homebrew into the VM guest (Intel) via git clone + symlink,
  then install gnu-tar + libyaml (bottling needs gnu-tar; ruby-build needs
  libyaml for psych). No sudo password needed (prlctl root
  for privileged steps, GUI user for brew steps).
  --check  verify guest brew + helpers exist, install nothing.
Env: VM_NAME=brew-sequoia VM_USER=<gui-user> (auto-detected from /dev/console)
EOF
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

vm_root() { "$SCRIPT_DIR/vm.sh" exec-as-root "$@"; }
vm_user() { VM_USER="$VM_USER" "$SCRIPT_DIR/vm.sh" exec "$@"; }

# Resolve GUI user: env first, else owner of /dev/console (queried as root).
if [[ -z "$VM_USER" ]]; then
  VM_USER="$(vm_root stat -f %Su /dev/console 2>/dev/null | tr -d '[:space:]' || true)"
fi
if [[ -z "$VM_USER" || "$VM_USER" == "root" ]]; then
  echo "error: GUI user unresolved — export VM_USER=<gui-user> (guest login name)" >&2
  exit 1
fi
echo "vm: $VM_NAME user: $VM_USER"

# Privileged layout is cheap — always ensure it (idempotent).
# Full standard Homebrew dir set (mirrors what install.sh prepares), else
# every `brew link` trips on the next root-owned dir.
echo "--- root: ensuring $BREW_PREFIX layout + ownership ---"
vm_root mkdir -p "$BREW_PREFIX/Homebrew" "$BREW_PREFIX/bin" "$BREW_PREFIX/etc" \
  "$BREW_PREFIX/include" "$BREW_PREFIX/lib" "$BREW_PREFIX/sbin" "$BREW_PREFIX/share" \
  "$BREW_PREFIX/Cellar" "$BREW_PREFIX/opt" "$BREW_PREFIX/var/homebrew" "$BREW_PREFIX/Frameworks"
vm_root chown -R "$VM_USER" "$BREW_PREFIX/Homebrew" "$BREW_PREFIX/bin" "$BREW_PREFIX/etc" \
  "$BREW_PREFIX/include" "$BREW_PREFIX/lib" "$BREW_PREFIX/sbin" "$BREW_PREFIX/share" \
  "$BREW_PREFIX/Cellar" "$BREW_PREFIX/opt" "$BREW_PREFIX/var/homebrew" "$BREW_PREFIX/Frameworks"

if vm_root test -d "$BREW_PREFIX/Homebrew/.git" 2>/dev/null; then
  echo "guest Homebrew repo present ($BREW_PREFIX/Homebrew)"
else
  if [[ "$CHECK_ONLY" == "true" ]]; then echo "guest brew: MISSING"; exit 1; fi
  echo "--- user: cloning Homebrew/brew (shallow, stable branch) ---"
  vm_user git clone --depth=1 --branch stable https://github.com/Homebrew/brew "$BREW_PREFIX/Homebrew"
fi
# Symlink is cheap — always ensure it (as root, so no ownership issues).
vm_root ln -sfn "$BREW_PREFIX/Homebrew/bin/brew" "$BREW_BIN"

if vm_user "$BREW_BIN" --version 2>/dev/null | head -n1; then
  echo "guest brew works"
else
  echo "error: $BREW_BIN --version failed in VM" >&2
  echo "hint: VM_USER=$VM_USER ./scripts/vm.sh exec $BREW_BIN doctor" >&2
  exit 1
fi
if [[ "$CHECK_ONLY" == "true" ]]; then
  vm_user "$BREW_BIN" list --formula 2>/dev/null | grep -iE '^(gnu-tar|libyaml)$' || echo "(helpers gnu-tar/libyaml not all installed)"
  exit 0
fi

echo "--- user: brew doctor ---"
doctor_out="$(vm_user "$BREW_BIN" doctor 2>&1 || true)"
echo "$doctor_out" | tail -n 15 | sed 's/^/  /'
if echo "$doctor_out" | grep -qi "license"; then
  echo "--- root: accepting Xcode license (flagged by doctor) ---"
  vm_root xcodebuild -license accept 2>&1 | tail -n 2 || echo "warn: license accept failed — accept manually in VM Terminal.app" >&2
fi

echo "--- user: installing gnu-tar libyaml (gh stays host-only) ---"
vm_user "$BREW_BIN" install gnu-tar libyaml
vm_user "$BREW_BIN" link gnu-tar libyaml 2>&1 | tail -n 3 || true

echo "--- verify ---"
vm_user "$BREW_BIN" --version
vm_user "$BREW_BIN" list --formula 2>/dev/null | grep -iE '^(gnu-tar|libyaml)$'
echo "vm-brew done"
