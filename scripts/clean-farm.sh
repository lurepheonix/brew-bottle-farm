#!/usr/bin/env bash
set -euo pipefail

# clean-farm.sh — reset the farm for a from-scratch run (host + guest).
# Usage: ./scripts/clean-farm.sh [--dry-run]
#
# Host: removes bottles/*.tar.gz + *.json (gitignored build artifacts).
# Guest (via vm.sh dispatch, VM must be running): removes guest bottles/logs,
# uninstalls every installed queue keg + shim-keg (farm-toolchain, gnu-tar,
# libyaml and the provisioned toolchains are kept), untaps the legacy
# farm/local tap dir if present, then brew autoremove + cleanup.
# Snapshots, toolchain installs (rustup/go/uv/asdf) and guest Homebrew itself
# are never touched.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/clean-farm.sh [--dry-run]

  Reset the farm for a from-scratch run. Host: wipe bottles/*.
  Guest (VM must be running): wipe guest bottles/logs, uninstall queue kegs
  + shim-kegs (farm-toolchain, gnu-tar, toolchains kept), untap legacy
  farm/local, brew autoremove + cleanup.
EOF
      exit 0 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] would: $*"
  else
    "$@"
  fi
}

echo "=== clean-farm (dry-run $DRY_RUN) ==="

# 1. Host bottles (gitignored artifacts; reproducible via rebuild).
echo "--- host bottles ---"
if ls "$ROOT_DIR"/bottles/*.tar.gz "$ROOT_DIR"/bottles/*.json >/dev/null 2>&1; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] would remove $(ls "$ROOT_DIR"/bottles/*.tar.gz "$ROOT_DIR"/bottles/*.json 2>/dev/null | wc -l | tr -d ' ') files in bottles/"
  else
    rm -v "$ROOT_DIR"/bottles/*.tar.gz "$ROOT_DIR"/bottles/*.json 2>&1 | sed 's/^/  /' | tail -n 5
    echo "  host bottles wiped (kept $(ls "$ROOT_DIR"/bottles 2>/dev/null | wc -l | tr -d ' ') entries)"
  fi
else
  echo "  host bottles already empty"
fi

# 2. Guest side (dispatch; VM must be running).
echo "--- guest (transport ${FARM_TRANSPORT:-ssh}) ---"
if [[ "${FARM_TRANSPORT:-ssh}" == "local" ]]; then
  echo "error: clean-farm targets the VM guest — refusing in local transport" >&2
  exit 1
fi
if ! "$SCRIPT_DIR/vm.sh" status 2>&1 | grep "running" >/dev/null; then
  echo "error: VM not running — start it first (./scripts/vm.sh start)" >&2
  exit 1
fi

QUEUE_FILE="$ROOT_DIR/build-queue.txt"
if [[ ! -f "$QUEUE_FILE" ]]; then
  echo "error: queue file not found: $QUEUE_FILE (run sync first)" >&2
  exit 1
fi

# Refuse while a detached guest build is alive (cleaning under it would orphan
# the daemon and confuse the next poll — finish or kill it on the guest first).
_guest_pid="$("$SCRIPT_DIR/vm.sh" run cat /tmp/farm-build.pid 2>/dev/null || true)"
if [[ -n "$_guest_pid" ]] && "$SCRIPT_DIR/vm.sh" run kill -0 "$_guest_pid" 2>/dev/null; then
  echo "error: detached guest build still alive (pid $_guest_pid) — refusing to clean under it" >&2
  echo "hint: wait for it, or kill the pid on the guest, then re-run" >&2
  exit 1
fi

# Uninstall every installed queue keg + shim-kegs by short name (origin tap
# irrelevant). Keep: farm-toolchain, gnu-tar, libyaml, provisioned toolchains.
# NOTE: transport goes through ssh argv join+reparse, which cannot carry
# multi-word values or inline scripts intact — so the guest script is written
# to a file, pushed, and executed by path (same pattern as toolchain.sh).
KEG_LIST="$(cat "$QUEUE_FILE" | tr '\n' ' ') python@3.15 ruby"
GUEST_SCRIPT="$(mktemp /tmp/farm-clean-guest.XXXXXX.sh)"
cat > "$GUEST_SCRIPT" <<GUESTEOF
#!/usr/bin/env bash
set -uo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:\$PATH"
for k in $KEG_LIST; do
  if brew list --versions "\$k" </dev/null >/dev/null 2>&1; then
    echo "uninstalling \$k"
    # --ignore-dependencies: the loop runs in queue (dep-first) order, so
    # dependents are still installed at each keg's turn; --force alone does
    # not override the dependents check.
    brew uninstall --force --ignore-dependencies "\$k" </dev/null 2>&1 | tail -n 1 || echo "warn: uninstall \$k failed" >&2
  fi
done
_BREW_REPO="\$(brew --repository </dev/null 2>/dev/null || true)"
if [[ -n "\$_BREW_REPO" && -d "\$_BREW_REPO/Library/Taps/farm" ]]; then
  echo "removing legacy farm tap namespace"
  rm -rf "\$_BREW_REPO/Library/Taps/farm"
fi
brew autoremove </dev/null 2>/dev/null || true
brew cleanup </dev/null 2>/dev/null || true
echo "installed now:"
brew list --formula 2>/dev/null | tr "\\n" " "
echo
GUESTEOF
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] would on guest: find-delete /tmp/shared/bottles/*.{tar.gz,json} + /tmp/{build,bottle,linkage}-*.log + /tmp/farm-build.*"
  echo "[dry-run] would push + run guest cleanup for $(echo "$KEG_LIST" | wc -w | tr -d ' ') kegs (queue + shims), untap legacy farm/local, autoremove + cleanup"
  rm -f "$GUEST_SCRIPT"
else
  "$SCRIPT_DIR/vm.sh" run noglob find /tmp/shared/bottles -maxdepth 1 -name '*.tar.gz' -print -delete 2>&1 | sed 's/^/  /' || true
  "$SCRIPT_DIR/vm.sh" run noglob find /tmp/shared/bottles -maxdepth 1 -name '*.json' -print -delete 2>&1 | sed 's/^/  /' || true
  echo "  guest bottles/logs/build markers wiped"
  "$SCRIPT_DIR/vm.sh" run noglob find /tmp -maxdepth 1 -name 'build-*.log' -print -delete 2>&1 | sed 's/^/  /' || true
  "$SCRIPT_DIR/vm.sh" run noglob find /tmp -maxdepth 1 -name 'bottle-*.log' -print -delete 2>&1 | sed 's/^/  /' || true
  "$SCRIPT_DIR/vm.sh" run noglob find /tmp -maxdepth 1 -name 'linkage-*.log' -print -delete 2>&1 | sed 's/^/  /' || true
  "$SCRIPT_DIR/vm.sh" run noglob find /tmp -maxdepth 1 -name 'farm-build.*' -print -delete 2>&1 | sed 's/^/  /' || true
  "$SCRIPT_DIR/vm.sh" push "$GUEST_SCRIPT" /tmp/shared/clean-guest.sh 2>&1 | sed 's/^/  stage: /' || {
    echo "error: guest script stage failed" >&2
    rm -f "$GUEST_SCRIPT"
    exit 1
  }
  rm -f "$GUEST_SCRIPT"
  if ! "$SCRIPT_DIR/vm.sh" run bash /tmp/shared/clean-guest.sh 2>&1 | sed 's/^/  guest: /'; then
    echo "error: guest cleanup failed" >&2
    exit 1
  fi
  "$SCRIPT_DIR/vm.sh" run rm -f /tmp/shared/clean-guest.sh 2>/dev/null || true
fi

echo "=== clean-farm done ==="
echo "next: ./scripts/orchestrate.sh --force --skip-publish"
