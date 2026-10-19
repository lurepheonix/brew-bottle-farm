#!/usr/bin/env bash
set -euo pipefail

# Host JSON helper: plain python3 only — never the VM's asdf slots.
# The repo .tool-versions pins VM-only interpreters; if the asdf shim
# cannot satisfy them on this host, drop it so brewed/system python3 is used.
if ! python3 -c 'pass' >/dev/null 2>&1; then
  PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '/\.asdf/shims' | paste -sd: -)"
fi

# check-toolchain-updates.sh — read-only drift check: build-deps.conf pins vs upstream
# Usage: ./scripts/check-toolchain-updates.sh
#
# Compares each conf pin against:
#   brew formulae (external rows that exist in homebrew/core) → `brew info --json=v2` stable
#   python slots → latest `uv python list` downloadable build for that minor
#   asdf/uv bootstraps → host-installed version (heuristic only; authority is the
#                         upstream release page, checked manually on bump)
# Also verifies .tool-versions ↔ build-deps.conf per-slot consistency.
#
# Exit 0: all pins current. Exit 1: at least one UPDATE available.
# Missing tools (no uv, no network) produce WARN lines, not failures.
# This is the detector for step 1 of the brew → local pin workflow; it changes nothing.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF="$ROOT_DIR/build-deps.conf"
TOOL_VERSIONS="$ROOT_DIR/.tool-versions"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [[ ! -f "$CONF" ]]; then
  echo "error: $CONF not found" >&2
  exit 2
fi

updates=0
checked=0

say() { printf "  %-6s %-14s %-14s conf=%-28s upstream=%-12s %s\n" "$1" "$2" "$3" "$4" "$5" "$6"; }
mark_ok() { say "OK" "$@"; checked=$((checked + 1)); }
mark_update() { say "UPDATE" "$@"; checked=$((checked + 1)); updates=$((updates + 1)); }
mark_warn() { say "WARN" "$@"; }

# 1. .tool-versions consistency (same rule as orchestrate.sh)
conf_py=$(grep -E '^python@' "$CONF" 2>/dev/null | awk '$2=="external"{print $3}' | sort -n | tr '\n' ' ' | sed 's/ *$//' || true)
tool_py=$(grep -E '^python[[:space:]]' "$TOOL_VERSIONS" 2>/dev/null | sed -E 's/^python[[:space:]]+//' | tr ' ' '\n' | grep -v '^#' | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ *$//' || true)
if [[ -n "$conf_py" && -n "$tool_py" ]]; then
  if [[ "$conf_py" == "$tool_py" ]]; then
    mark_ok ".tool-versions" "python" "$tool_py" "$conf_py" "(in sync)"
  else
    mark_update ".tool-versions" "python" "$tool_py" "$conf_py" "(conf wins — copy to .tool-versions)"
  fi
fi

# 2. brew stables for conf rows that exist in homebrew/core
while read -r name _strategy pin _source; do
  [[ -z "$name" ]] && continue
  case "$name" in
    asdf|uv|farm-toolchain) continue ;; # not brew formulae / not in core
  esac
  stable=$(brew info --json=v2 --formula "$name" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['formulae'][0]['versions']['stable'] if d.get('formulae') else '')" 2>/dev/null || true)
  if [[ -z "$stable" ]]; then
    mark_warn "brew" "$name" "$pin" "?" "(brew info failed — skipped)"
    continue
  fi
  if [[ "$stable" == "$pin" ]]; then
    mark_ok "brew" "$name" "$pin" "$stable" ""
  else
    mark_update "brew" "$name" "$pin" "$stable" ""
  fi
done < <(grep -v '^[[:space:]]*#' "$CONF" | grep -v '^[[:space:]]*$' | awk 'NF>=3 && ($2=="external" || $2=="bottled") {print $1" "$2" "$3" "$4}' || true)

# 3. python slots vs latest uv-downloadable build (per minor)
if command -v uv >/dev/null 2>&1; then
  uv_list=$(uv python list --only-downloads 2>/dev/null || true)
  for minor in 3.13 3.14 3.15; do
    pin=$(grep -E "^python@${minor}[[:space:]]" "$CONF" 2>/dev/null | awk '{print $3}' | head -n1 || true)
    [[ -z "$pin" ]] && continue
    latest=$(echo "$uv_list" | grep -oE "cpython-${minor//./\\.}\.[0-9]+" | sort -u | python3 -c "import sys; vs=[l.strip().split('-')[1] for l in sys.stdin if l.strip()]; print(sorted(vs, key=lambda v: [int(x) for x in v.split('.')])[-1] if vs else '')" 2>/dev/null || true)
    if [[ -z "$latest" ]]; then
      mark_warn "uv" "python@$minor" "$pin" "?" "(no $minor build listed — asdf fallback covers it)"
    elif [[ "$latest" == "$pin" ]]; then
      mark_ok "uv" "python@$minor" "$pin" "$latest" ""
    else
      mark_update "uv" "python@$minor" "$pin" "$latest" ""
    fi
  done
else
  mark_warn "uv" "python-slots" "?" "?" "(uv not on host PATH — skipped)"
fi

# 4. bootstrap heuristics vs host-installed versions (NOT authoritative).
# Only a NEWER host signals a stale pin; an older host is expected
# (the VM uses the pinned tarball, the host need not match).
ver_is_newer() { # $1=candidate $2=baseline → exit 0 if candidate newer
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import sys
def t(v):
    return [int(x) for x in v.split('.') if x.isdigit()]
sys.exit(0 if t(sys.argv[1]) > t(sys.argv[2]) else 1)
PY
}
if command -v asdf >/dev/null 2>&1; then
  have=$(asdf --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  pin=$(grep -E '^asdf[[:space:]]' "$CONF" 2>/dev/null | awk '{print $3}' | head -n1 || true)
  if [[ -n "$have" && -n "$pin" ]]; then
    if [[ "$have" == "$pin"* ]]; then mark_ok "host" "asdf" "$pin" "$have" "(in sync)";
    elif ver_is_newer "$have" "$pin"; then mark_update "host" "asdf" "$pin" "$have" "(host newer — confirm on release page)";
    else mark_ok "host" "asdf" "$pin" "$have" "(host behind pin — VM uses pinned tarball)"; fi
  fi
fi
if command -v uv >/dev/null 2>&1; then
  have=$(uv --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  pin=$(grep -E '^uv[[:space:]]' "$CONF" 2>/dev/null | awk '{print $3}' | head -n1 || true)
  if [[ -n "$have" && -n "$pin" ]]; then
    if [[ "$have" == "$pin"* ]]; then mark_ok "host" "uv" "$pin" "$have" "(in sync)";
    elif ver_is_newer "$have" "$pin"; then mark_update "host" "uv" "$pin" "$have" "(host newer — confirm on release page)";
    else mark_ok "host" "uv" "$pin" "$have" "(host behind pin — VM uses pinned tarball)"; fi
  fi
fi

echo ""
echo "checked $checked pins, $updates updates available"
if [[ "$updates" -gt 0 ]]; then
  echo "next: bump pins in build-deps.conf (+ .tool-versions), re-provision, sync (auto-queues), rebuild"
  exit 1
fi
exit 0
