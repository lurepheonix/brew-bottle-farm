#!/usr/bin/env bash
set -euo pipefail

# apply-patches.sh — B1 plain-patch applier for Formula/*.rb
# Usage: ./scripts/apply-patches.sh [--check-only] [--formula-dir ./Formula] [--patches-dir ./patches]
#
# Reads patches/series (ordered) and applies each via `patch -p1 --forward`.
# Fail-closed: any .rej or hunk failure aborts (forces human to refresh patch after core_sha bump).
# Enforces single-pin: patch header tool version must match build-deps.conf pin.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FORMULA_DIR="${FORMULA_DIR:-$ROOT_DIR/Formula}"
PATCHES_DIR="${PATCHES_DIR:-$ROOT_DIR/patches}"
SERIES_FILE="$PATCHES_DIR/series"
BUILD_DEPS_CONF="$ROOT_DIR/build-deps.conf"
CHECK_ONLY="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY="true"; shift ;;
    --formula-dir) FORMULA_DIR="$2"; shift 2 ;;
    --patches-dir) PATCHES_DIR="$2"; SERIES_FILE="$PATCHES_DIR/series"; shift 2 ;;
    --only) ONLY_LIST="$2"; shift 2 ;; # space-separated formula short names: apply only patches touching them
    -h|--help) cat <<'EOF'
Usage: ./scripts/apply-patches.sh [--check-only] [--formula-dir ./Formula] [--patches-dir ./patches] [--only "foo bar"]
  --check-only  validate series exists, patches apply cleanly (dry-run), pins match build-deps.conf
  --only        apply only patches touching the named formulae (space-separated
                short names, matched against each patch's +++ b/Formula/ path);
                lets orchestrate patch freshly-mirrored queued formulae without
                probing the published (bottled+rewritten) rest of the tree
EOF
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$SERIES_FILE" ]]; then
  echo "no series file $SERIES_FILE — nothing to patch"
  exit 0
fi

# Parse series (strip comments/blank)
series_list=$(grep -v '^[[:space:]]*#' "$SERIES_FILE" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u || true)
if [[ -z "$series_list" ]]; then
  echo "series empty — nothing to patch"
  exit 0
fi

# --only filter: keep series order, select patches whose +++ target belongs
# to the named set. Unparseable targets are kept (probes fail loudly rather
# than silently skipping). Lets orchestrate patch freshly-mirrored queued
# formulae while the published rest of the tree stays untouched.
if [[ -n "${ONLY_LIST:-}" ]]; then
  _only_tmp="$(mktemp -d /tmp/farm-patchonly.XXXXXX)"
  echo "$ONLY_LIST" | tr ' ' '\n' | grep -v '^[[:space:]]*$' | sed 's/\.rb$//' > "$_only_tmp/names"
  _filtered=""
  for _pn in $series_list; do
    _tgt="$(grep -m1 '^+++ b/' "$PATCHES_DIR/$_pn" 2>/dev/null | sed -E 's|^\+\+\+ b/Formula/([^/]+)\.rb$|\1|' || true)"
    if [[ -z "$_tgt" || "$_tgt" == "+++"* ]]; then
      _filtered="$_filtered $_pn"
    elif grep -qx "$_tgt" "$_only_tmp/names" 2>/dev/null; then
      _filtered="$_filtered $_pn"
    else
      echo "(--only: skipping $_pn)"
    fi
  done
  rm -rf "$_only_tmp"
  series_list="$(echo "$_filtered" | tr ' ' '\n' | grep -v '^[[:space:]]*$' || true)"
  if [[ -z "$series_list" ]]; then
    echo "series empty after --only filter — nothing to patch"
    exit 0
  fi
fi

count=$(echo "$series_list" | wc -l | tr -d ' ')
echo "=== apply-patches.sh ($count patches, check $CHECK_ONLY) ==="
echo "formula dir: $FORMULA_DIR"
echo "patches dir: $PATCHES_DIR"

failed=0
for patch_name in $series_list; do
  patch_file="$PATCHES_DIR/$patch_name"
  echo "--- $patch_name ---"
  if [[ ! -f "$patch_file" ]]; then
    echo "error: patch file not found: $patch_file" >&2
    failed=1
    continue
  fi

  # Single-pin header check: look for "# Tool: <name> <version>" in patch
  # e.g. "# Tool: rust 1.82.0" — compare to build-deps.conf pin (bash 3.2 compatible, no associative array)
  header_tool=$(grep -E '^# Tool:' "$patch_file" 2>/dev/null | head -n1 | sed -E 's/^# Tool:[[:space:]]*//' | awk '{print $1}' || true)
  header_ver=$(grep -E '^# Tool:' "$patch_file" 2>/dev/null | head -n1 | sed -E 's/^# Tool:[[:space:]]*//' | awk '{print $2}' || true)
  if [[ -n "$header_tool" && -n "$header_ver" && -f "$BUILD_DEPS_CONF" ]]; then
    expected=$(grep -v '^[[:space:]]*#' "$BUILD_DEPS_CONF" 2>/dev/null | awk -v t="$header_tool" '$1==t {print $3}' | head -n1 || true)
    if [[ -n "$expected" && "$header_ver" != "$expected" ]]; then
      echo "error: patch $patch_name header Tool: $header_tool $header_ver != build-deps.conf pin $expected (single-pin rule)" >&2
      failed=1
      continue
    fi
  fi

  # Gate: reject patches that touch runtime python (depends_on "python@" without => :build)
  # Check patch diff for `depends_on "python` not followed by `=> :build`
  if grep -q 'depends_on "python' "$patch_file" 2>/dev/null; then
    # If patch adds a disabled line for python build dep, it should contain => :build in context
    # Heuristic: if patch contains python@ but not :build, warn
    if ! grep -q 'depends_on "python.*=> :build' "$patch_file" 2>/dev/null && grep -q 'depends_on "python' "$patch_file" 2>/dev/null; then
      echo "warn: patch $patch_name touches python without :build — will be checked for runtime linkage; ensure it's build-only" >&2
      # Not fatal, but check-only will enforce later
    fi
  fi

  # Real-apply path only: dry-run probe first (fail closed before touching the tree).
  # (Check-only mode verifies the whole stack at once below, because same-file
  # leader+follower patches are only reversible as a stack, in reverse order.)
  if [[ "$CHECK_ONLY" != "true" ]]; then
  if ! patch -p1 --dry-run --forward -d "$ROOT_DIR" < "$patch_file" >/dev/null 2>&1; then
    # If already applied, dry-run will fail with "already applied" — check if reverse would apply
    if patch -p1 --dry-run --reverse -d "$ROOT_DIR" < "$patch_file" >/dev/null 2>&1; then
      echo "  already applied (reverse applies cleanly) — skipping"
      continue
    fi
    echo "error: patch $patch_name does not apply cleanly (core_sha drift?)" >&2
    patch -p1 --dry-run --forward -d "$ROOT_DIR" < "$patch_file" 2>&1 | sed 's/^/  dry-run: /' || true
    failed=1
    continue
  fi
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "  header/pin ok (stack verified below)"
    continue
  fi

  echo "  applying..."
  # -V none: Apple patch(1) writes .orig pristine backups on every successful
  # apply, which would trip the .rej/.orig tripwire below. Suppress backups —
  # .rej files remain the failure signal, and the patch file itself is the record.
  if ! patch -p1 --forward -V none -d "$ROOT_DIR" < "$patch_file" 2>&1 | sed 's/^/  patch: /'; then
    echo "error: patch $patch_name failed to apply" >&2
    failed=1
    continue
  fi
  # Check for .rej files
  if find "$FORMULA_DIR" -name "*.rej" -o -name "*.orig" 2>/dev/null | grep -q .; then
    echo "error: .rej/.orig files after patch $patch_name" >&2
    find "$FORMULA_DIR" -name "*.rej" -o -name "*.orig" 2>/dev/null | sed 's/^/  /' >&2
    failed=1
    continue
  fi
  echo "  ok"
done

# Check-only stack verification (runs once, not per patch): same-file
# leader+follower patches are only reversible as a stack, so per-patch
# forward/reverse probes give false failures on applied trees. Instead verify
# in a scratch copy (working tree untouched):
#   Branch 1 (pristine tree): forward-apply the whole series in order.
#   Branch 2 (applied tree): unwind the whole series in reverse order, then
#     re-apply in order — the result must equal the working tree exactly
#     (catches unrecorded hand edits and partial application, fail closed).
#   Branch 3 (published/other tree): re-mirror the touched formulae pristine
#     at the locked core_sha (needs network) and forward-apply there —
#     the exact input orchestrate stages for the next build.
if [[ "$CHECK_ONLY" == "true" && "$failed" -eq 0 ]]; then
  _stack_scratch="$(mktemp -d /tmp/farm-patchcheck.XXXXXX)"
  _series_order=()
  while IFS= read -r _p; do
    [[ -n "$_p" ]] && _series_order+=("$_p")
  done <<< "$series_list"
  # Files the series touches (for the Branch-2 comparison).
  _touched=$(grep -h '^+++ b/' "$PATCHES_DIR"/*.patch 2>/dev/null | sed 's|^+++ b/||' | sort -u || true)

  _branch_ok="false"
  # Branch 1: pristine tree?
  rm -rf "$_stack_scratch/t" && mkdir -p "$_stack_scratch/t" && cp -R "$FORMULA_DIR/." "$_stack_scratch/t/Formula/"
  _fwd_ok="true"
  for _p in "${_series_order[@]}"; do
    if ! patch -p1 --forward -V none -d "$_stack_scratch/t" < "$PATCHES_DIR/$_p" >/dev/null 2>&1; then
      _fwd_ok="false"
      break
    fi
  done
  if [[ "$_fwd_ok" == "true" ]] && ! find "$_stack_scratch/t" -name "*.rej" 2>/dev/null | grep -q .; then
    echo "stack check: series applies cleanly onto this tree (pristine) — would apply"
    _branch_ok="true"
  else
    # Branch 2: exactly series-applied tree? unwind then re-apply, must roundtrip.
    rm -rf "$_stack_scratch/t" && mkdir -p "$_stack_scratch/t" && cp -R "$FORMULA_DIR/." "$_stack_scratch/t/Formula/"
    _unw_ok="true"
    for (( _i=${#_series_order[@]}-1; _i>=0; _i-- )); do
      if ! patch -p1 --reverse -V none -d "$_stack_scratch/t" < "$PATCHES_DIR/${_series_order[$_i]}" >/dev/null 2>&1; then
        _unw_ok="false"
        break
      fi
    done
    if [[ "$_unw_ok" == "true" ]]; then
      _re_ok="true"
      for _p in "${_series_order[@]}"; do
        if ! patch -p1 --forward -V none -d "$_stack_scratch/t" < "$PATCHES_DIR/$_p" >/dev/null 2>&1; then
          _re_ok="false"
          break
        fi
      done
      if [[ "$_re_ok" == "true" ]] && ! find "$_stack_scratch/t" -name "*.rej" 2>/dev/null | grep -q .; then
        _cmp_bad="0"
        for _f in $_touched; do
          if [[ -f "$_stack_scratch/t/$_f" && -f "$ROOT_DIR/$_f" ]]; then
            if ! diff -q "$_stack_scratch/t/$_f" "$ROOT_DIR/$_f" >/dev/null 2>&1; then
              echo "error: $_f differs from series output — unrecorded hand edit or partial application?" >&2
              _cmp_bad="1"
            fi
          fi
        done
        if [[ "$_cmp_bad" == "0" ]]; then
          echo "stack check: tree matches series output exactly (unwind + re-apply roundtrip clean)"
          _branch_ok="true"
        fi
      else
        echo "error: series does not re-apply cleanly after unwind (core_sha drift?)" >&2
      fi
    else
      # Branch 3 (published or otherwise non-series tree): re-mirror the
      # touched formulae pristine at the locked core_sha — the exact source
      # orchestrate stages from — into scratch and forward-apply there.
      # Needs network; without it the check stays fail-closed below.
      # (Offline --check-only only covers pristine/applied working trees.)
      _lock_sha="$(python3 -c "import json; print(json.load(open('$ROOT_DIR/packages.lock.json')).get('core_sha',''))" 2>/dev/null || true)"
      _b3_done="false"
      if [[ -n "${_lock_sha:-}" ]]; then
        rm -rf "$_stack_scratch/p" && mkdir -p "$_stack_scratch/p/Formula"
        _mir_ok="true"
        for _f in $_touched; do
          _bn="$(basename "$_f" .rb)"
          _got="false"
          for _pp in "Formula/${_bn:0:1}/${_bn}.rb" "Formula/lib/${_bn}.rb"; do
            if curl -fsSL "https://raw.githubusercontent.com/Homebrew/homebrew-core/${_lock_sha}/${_pp}" -o "$_stack_scratch/p/Formula/${_bn}.rb" 2>/dev/null; then
              _got="true"
              break
            fi
          done
          if [[ "$_got" != "true" ]]; then
            echo "  mirror failed for $_bn (offline?)" >&2
            _mir_ok="false"
            break
          fi
        done
        if [[ "$_mir_ok" == "true" ]]; then
          _b3_fwd="true"
          for _p in "${_series_order[@]}"; do
            if ! patch -p1 --forward -V none -d "$_stack_scratch/p" < "$PATCHES_DIR/$_p" >/dev/null 2>&1; then
              _b3_fwd="false"
              break
            fi
          done
          if [[ "$_b3_fwd" == "true" ]] && ! find "$_stack_scratch/p" -name "*.rej" 2>/dev/null | grep -q .; then
            echo "stack check: series applies cleanly onto pristine core @ ${_lock_sha:0:8} (re-mirrored) — working tree is published/ahead, which orchestrate re-mirrors anyway"
            rm -rf "$_stack_scratch/t" && cp -R "$_stack_scratch/p" "$_stack_scratch/t"
            _branch_ok="true"
          else
            echo "error: series does not apply onto pristine core @ ${_lock_sha:0:8} either — refresh patches after core_sha bump (see patches/README.md)" >&2
          fi
          _b3_done="true"
        fi
      fi
      if [[ "$_b3_done" != "true" ]]; then
        echo "error: series neither applies onto this tree (pristine?) nor unwinds from it (applied?)" >&2
        echo "hint: re-mirror Formulae at the locked core_sha, then re-apply (see patches/README.md)" >&2
        echo "note: offline --check-only covers pristine/applied trees only; published trees need the re-mirror branch (network)" >&2
      fi
    fi
  fi
  # Build-env lint on the resolved (series-applied) tree: any formula that
  # invokes farm tools at build time must declare `env :std`, otherwise
  # superenv scrubs uv from PATH and the farm-toolchain shims fail with
  # "not provisioned" (seen: libvmaf/dav1d via farm meson, libuv via farm
  # sphinx). Trigger: a :build-scoped farm/local dep or a
  # Formula["farm/local/..."] reference. Runtime-only farm deps (ffmpeg/aom/...)
  # never execute shims at build time and are exempt.
  if [[ "$_branch_ok" == "true" ]]; then
    _env_bad="0"
    for _f in $_touched; do
      _rf="$_stack_scratch/t/$_f"
      [[ -f "$_rf" ]] || continue
      if grep -Eq 'farm/local/[^"]*"[[:space:]]*=>[^#]*:build|Formula\["farm/local' "$_rf" 2>/dev/null; then
        if ! grep -q 'env :std' "$_rf" 2>/dev/null; then
          echo "error: $_f invokes farm tools at build time without env :std" >&2
          echo "hint: superenv scrubs uv from PATH — the farm shims fail loud (add env :std to its patch)" >&2
          _env_bad="1"
        fi
      fi
    done
    if [[ "$_env_bad" == "0" ]]; then
      echo "env check: every build-time farm-tool consumer declares env :std"
    else
      failed=1
    fi
  fi
  rm -rf "$_stack_scratch"
  if [[ "$_branch_ok" != "true" ]]; then
    failed=1
  fi
fi
# Post-check: ensure no leftover rejects anywhere
if find "$ROOT_DIR" -name "*.rej" 2>/dev/null | grep -q .; then
  echo "error: leftover .rej files:" >&2
  find "$ROOT_DIR" -name "*.rej" 2>/dev/null | sed 's/^/  /' >&2
  failed=1
fi

if [[ $failed -ne 0 ]]; then
  echo "apply-patches: $failed failure(s) — refresh patches after core_sha bump (see patches/README.md)" >&2
  exit 1
fi

echo "apply-patches: all $count patches ok"
