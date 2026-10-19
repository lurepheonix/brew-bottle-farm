#!/usr/bin/env bash
set -euo pipefail

# Host JSON helper: plain python3 only — never the VM's asdf slots.
# The repo .tool-versions pins VM-only interpreters; if the asdf shim
# cannot satisfy them on this host, drop it so brewed/system python3 is used.
if ! python3 -c 'pass' >/dev/null 2>&1; then
  PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '/\.asdf/shims' | paste -sd: -)"
fi

# packages.sh — manual management of packages.txt (explicit installs) with validation
# Usage: ./scripts/packages.sh <list|add|remove|edit|sync|status> [args...]
#
# Validation (strict):
#  - formula must exist in homebrew/core (brew info --json=v2) or allowed tap
#  - rejects casks, disabled/deprecated formulae
#  - checks brew deps resolvable

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_FILE="$ROOT_DIR/packages.txt"
LOCK_FILE="$ROOT_DIR/packages.lock.json"

# Allow override for testing
PACKAGES_FILE="${PACKAGES_FILE_OVERRIDE:-$PACKAGES_FILE}"

ensure_packages_file() {
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    touch "$PACKAGES_FILE"
  fi
}

read_packages() {
  # output normalized: stripped, no comments, no empty, sorted -u
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    return 0
  fi
  grep -v '^[[:space:]]*#' "$PACKAGES_FILE" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u
}

write_packages() {
  # $1 is tempfile with normalized list — preserve header comment block if present
  local tmp_in="$1"
  local header_tmp
  header_tmp=$(mktemp)
  # Extract leading # comments from existing file (if any) to preserve header
  if [[ -f "$PACKAGES_FILE" ]]; then
    awk ' /^#/ {print; next} /^$/ {next} {exit}' "$PACKAGES_FILE" > "$header_tmp" 2>/dev/null || true
    # If no header, use default
    if [[ ! -s "$header_tmp" ]]; then
      cat > "$header_tmp" <<'HDR'
# packages.txt — explicitly-installed formulae (one per line)
# Managed ONLY via ./scripts/packages.sh (validated). Do not edit manually without validation.
# Add: ./scripts/packages.sh add <formula>
# Sync from current brew leaves: ./scripts/packages.sh sync --from-brew
# This file is the source of truth; transitive deps are resolved fresh via `brew deps --include-build`.
HDR
    fi
    cat "$header_tmp" > "$PACKAGES_FILE"
    sort -u "$tmp_in" >> "$PACKAGES_FILE"
    rm -f "$header_tmp"
  else
    sort -u "$tmp_in" > "$PACKAGES_FILE"
  fi
}

validate_formula() {
  local name="$1"
  local allow_local="${2:-false}"

  # Basic name sanity
  if ! [[ "$name" =~ ^[a-z0-9._@+-]+$ ]]; then
    echo "error: invalid formula name '$name'" >&2
    return 1
  fi

  # Try brew info JSON — pipe directly to python to avoid variable quoting issues
  local count
  count=$(brew info --json=v2 --formula "$name" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('formulae',[])))" 2>/dev/null || echo 0)
  if [[ "$count" -eq 0 ]]; then
    if [[ "$allow_local" == "true" ]]; then
      count=$(brew info --json=v2 "$name" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('formulae',[])))" 2>/dev/null || echo 0)
      if [[ "$count" -eq 0 ]]; then
        echo "error: formula '$name' not found (brew info --json=v2 $name failed)" >&2
        echo "       hint: brew search --formula $name" >&2
        return 1
      fi
    else
      echo "error: formula '$name' not found (brew info --json=v2 --formula $name failed)" >&2
      echo "       hint: brew search --formula $name" >&2
      return 1
    fi
  fi

  # Check cask vs formula: formulae array should contain it; if only casks, error
  # Also check disabled/deprecated — use temp file to avoid heredoc+pipe stdin conflict
  local tmp_json
  tmp_json=$(mktemp)
  local check
  if [[ "$allow_local" == "true" ]]; then
    brew info --json=v2 "$name" 2>/dev/null > "$tmp_json" || true
    check=$(FORMULA_NAME="$name" JSON_FILE="$tmp_json" python3 <<'PY' 2>&1
import json, os
name=os.environ["FORMULA_NAME"]
path=os.environ["JSON_FILE"]
with open(path) as f:
    d=json.load(f)
for formula in d.get('formulae',[]):
    if formula.get('name')==name or name in (formula.get('full_name') or ''):
        disabled=formula.get('disabled', False)
        deprecated=formula.get('deprecated', False)
        tap=formula.get('tap','')
        print(f"tap={tap}")
        print(f"disabled={disabled}")
        print(f"deprecated={deprecated}")
        print(f"disable_reason={formula.get('disable_reason')}")
        print(f"deprecation_reason={formula.get('deprecation_reason')}")
        raise SystemExit(0)
print("not_found")
PY
)
  else
    brew info --json=v2 --formula "$name" 2>/dev/null > "$tmp_json" || true
    check=$(FORMULA_NAME="$name" JSON_FILE="$tmp_json" python3 <<'PY' 2>&1
import json, os
name=os.environ["FORMULA_NAME"]
path=os.environ["JSON_FILE"]
with open(path) as f:
    d=json.load(f)
for formula in d.get('formulae',[]):
    if formula.get('name')==name or name in (formula.get('full_name') or ''):
        disabled=formula.get('disabled', False)
        deprecated=formula.get('deprecated', False)
        tap=formula.get('tap','')
        print(f"tap={tap}")
        print(f"disabled={disabled}")
        print(f"deprecated={deprecated}")
        print(f"disable_reason={formula.get('disable_reason')}")
        print(f"deprecation_reason={formula.get('deprecation_reason')}")
        raise SystemExit(0)
print("not_found")
PY
)
  fi
  rm -f "$tmp_json"
  if echo "$check" | grep -q "not_found"; then
    echo "error: '$name' is not a formula (maybe a cask?)" >&2
    echo "       hint: this tap only handles formulae (brew info --cask $name)" >&2
    return 1
  fi

  local disabled deprecated tap
  disabled=$(echo "$check" | grep '^disabled=' | cut -d= -f2)
  deprecated=$(echo "$check" | grep '^deprecated=' | cut -d= -f2)
  tap=$(echo "$check" | grep '^tap=' | cut -d= -f2)

  if [[ "$disabled" == "True" ]]; then
    echo "error: formula '$name' is disabled (tap: $tap)" >&2
    echo "$check" | grep disable_reason >&2
    return 1
  fi
  if [[ "$deprecated" == "True" ]]; then
    echo "warn: formula '$name' is deprecated (tap: $tap) — allowed but will warn" >&2
    # not fatal, just warn
  fi

  # Check tap is homebrew/core unless --allow-local
  if [[ "$allow_local" != "true" ]] && [[ "$tap" != "homebrew/core" ]]; then
    # allow any tap but warn; strict mode would reject non-core
    # For this project we only want homebrew/core explicit, so reject others
    echo "error: formula '$name' is from tap '$tap', expected 'homebrew/core'" >&2
    echo "       hint: use --allow-local to permit non-core taps" >&2
    return 1
  fi

  # Check deps resolvable
  if ! brew deps --include-build --formula "$name" >/dev/null 2>&1; then
    echo "error: dependencies for '$name' not resolvable (brew deps failed)" >&2
    return 1
  fi

  return 0
}

cmd_list() {
  ensure_packages_file
  if [[ ! -s "$PACKAGES_FILE" ]]; then
    echo "# packages.txt is empty"
    echo "# add formulae via: $0 add <formula>"
    return 0
  fi
  echo "=== packages.txt (explicit, $(read_packages | wc -l | tr -d ' ') formulae) ==="
  read_packages | sed 's/^/  /'
  if [[ -f "$LOCK_FILE" ]]; then
    echo ""
    echo "=== packages.lock.json (resolved: $(python3 -c "import json; print(len(json.load(open('$LOCK_FILE')).get('resolved',{})))" 2>/dev/null || echo "?") formulae) ==="
  fi
}

cmd_add() {
  ensure_packages_file
  if [[ $# -eq 0 ]]; then
    echo "usage: $0 add <formula> [...] [--allow-local]" >&2
    return 1
  fi
  local allow_local="false"
  local args=()
  for a in "$@"; do
    if [[ "$a" == "--allow-local" ]]; then
      allow_local="true"
    else
      args+=("$a")
    fi
  done
  if [[ ${#args[@]} -eq 0 ]]; then
    echo "error: no formulae specified" >&2
    return 1
  fi

  local existing
  existing=$(read_packages || true)
  local tmp
  tmp=$(mktemp)
  # seed with existing
  if [[ -n "$existing" ]]; then
    echo "$existing" > "$tmp"
  else
    : > "$tmp"
  fi

  local failed=0
  for name in "${args[@]}"; do
    echo "validating '$name'..."
    if ! validate_formula "$name" "$allow_local"; then
      failed=1
      continue
    fi
    if echo "$existing" | grep -qx "$name"; then
      echo "skip: '$name' already in packages.txt"
      continue
    fi
    echo "$name" >> "$tmp"
    echo "ok: '$name' validated"
  done

  if [[ $failed -ne 0 ]]; then
    rm -f "$tmp"
    echo "error: one or more formulae failed validation, no changes made" >&2
    return 1
  fi

  write_packages "$tmp"
  rm -f "$tmp"
  echo "updated packages.txt ($(read_packages | wc -l | tr -d ' ') formulae)"
  read_packages | sed 's/^/  + /'
}

cmd_remove() {
  ensure_packages_file
  if [[ $# -eq 0 ]]; then
    echo "usage: $0 remove <formula> [...]" >&2
    return 1
  fi
  local existing
  existing=$(read_packages || true)
  if [[ -z "$existing" ]]; then
    echo "error: packages.txt is empty" >&2
    return 1
  fi
  local failed=0
  for name in "$@"; do
    if ! echo "$existing" | grep -qx "$name"; then
      echo "error: '$name' not in packages.txt" >&2
      failed=1
    fi
  done
  if [[ $failed -ne 0 ]]; then
    return 1
  fi
  local tmp
  tmp=$(mktemp)
  echo "$existing" | grep -vxF -f <(printf "%s\n" "$@") | sort -u > "$tmp" || true
  write_packages "$tmp"
  rm -f "$tmp"
  echo "updated packages.txt ($(read_packages | wc -l | tr -d ' ') formulae)"
  if [[ -f "$LOCK_FILE" ]]; then
    echo "note: run ./scripts/sync.sh --dry-run to preview orphaned deps"
  fi
}

cmd_edit() {
  ensure_packages_file
  local editor="${EDITOR:-vi}"
  local tmp
  tmp=$(mktemp)
  cp "$PACKAGES_FILE" "$tmp"
  "$editor" "$tmp"
  # validate each line
  local normalized
  normalized=$(mktemp)
  grep -v '^[[:space:]]*#' "$tmp" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u > "$normalized" || true
  local failed=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! validate_formula "$name" "false"; then
      failed=1
    fi
  done < "$normalized"
  if [[ $failed -ne 0 ]]; then
    echo "error: validation failed, packages.txt not updated (edit tmp kept at $tmp)" >&2
    rm -f "$normalized"
    return 1
  fi
  write_packages "$normalized"
  rm -f "$tmp" "$normalized"
  echo "updated packages.txt"
}

cmd_sync_from_brew() {
  # overwrite packages.txt from brew leaves with validation
  local leaves
  if ! leaves=$(brew leaves 2>/dev/null); then
    echo "error: brew leaves failed" >&2
    return 1
  fi
  if [[ -z "$leaves" ]]; then
    echo "error: brew leaves returned empty" >&2
    return 1
  fi
  echo "found $(echo "$leaves" | wc -l | tr -d ' ') leaves"
  echo "$leaves" | sed 's/^/  /'
  echo ""
  read -rp "Overwrite packages.txt with these leaves? [y/N] " ans
  if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
    echo "aborted"
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  local failed=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! validate_formula "$name" "false"; then
      echo "warn: leaf '$name' failed validation — skipping" >&2
      failed=1
      continue
    fi
    echo "$name" >> "$tmp"
  done <<< "$leaves"
  if [[ $failed -ne 0 ]]; then
    echo "warn: some leaves skipped due to validation" >&2
  fi
  write_packages "$tmp"
  rm -f "$tmp"
  echo "updated packages.txt from brew leaves ($(read_packages | wc -l | tr -d ' ') formulae)"
}

cmd_status() {
  ensure_packages_file
  echo "=== packages.txt ==="
  if [[ -s "$PACKAGES_FILE" ]]; then
    read_packages | sed 's/^/  /'
  else
    echo "  (empty)"
  fi
  echo ""
  if [[ -f "$LOCK_FILE" ]]; then
    echo "=== packages.lock.json ==="
    cat "$LOCK_FILE" | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || cat "$LOCK_FILE" | sed 's/^/  /'
  else
    echo "=== packages.lock.json: not found (run ./scripts/sync.sh) ==="
  fi
  echo ""
  echo "=== validation ==="
  local failed=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! validate_formula "$name" "false" >/dev/null 2>&1; then
      echo "  ✗ $name (failed)"
      failed=1
    else
      echo "  ✓ $name"
    fi
  done < <(read_packages)
  if [[ $failed -ne 0 ]]; then
    echo "  some formulae failed validation"
    return 1
  fi
  echo ""
  echo "run ./scripts/sync.sh --dry-run to preview build queue"
}

usage() {
  cat <<'EOF'
Usage: ./scripts/packages.sh <command> [args]

Commands:
  list                        Show packages.txt
  add <formula> [...] [--allow-local]
                              Add formulae with validation
  remove <formula> [...]      Remove formulae
  edit                        Edit packages.txt in $EDITOR with validation
  sync --from-brew            Overwrite packages.txt from `brew leaves` (validated, prompts)
  status                      Validate all entries and show lock status

Validation (strict, fails closed):
  - brew info --json=v2 --formula <name> must succeed, tap==homebrew/core
  - rejects casks/disabled formulae, warns on deprecated
  - brew deps --include-build must be resolvable

Examples:
  ./scripts/packages.sh add ffmpeg
  ./scripts/packages.sh add custom/formula --allow-local
  ./scripts/packages.sh sync --from-brew
  ./scripts/packages.sh status
EOF
}

case "${1:-}" in
  list) cmd_list ;;
  add) shift; cmd_add "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  edit) cmd_edit ;;
  sync) shift; if [[ "${1:-}" == "--from-brew" ]]; then cmd_sync_from_brew; else echo "usage: $0 sync --from-brew" >&2; exit 1; fi ;;
  status) cmd_status ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $1" >&2; usage; exit 1 ;;
esac
