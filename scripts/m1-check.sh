#!/usr/bin/env bash
# m1-check.sh — M1 local-validation coverage test (host-only, no VM running)
# Usage: ./scripts/m1-check.sh [--help]
#
# Covers plan/brew-bottle-farm.md M1:
#   1. every scripts/*.sh answers --help (RC=0, non-empty), and every
#      side-effect-free make target runs green (mutating/interactive/VM
#      targets are listed as skipped, with reasons — their scripts are still
#      covered via --help above);
#   2. packages.sh status + sync.sh --dry-run green on the starter set
#      (the lock core_sha refresh itself is a real `sync.sh --force` run,
#      committed separately — this test asserts the green steady state);
#   3. apply-patches.sh --check-only green (asserts 5/5), plus a .rej
#      fail-closed self-test in a scratch dir (synthetic bad patch must
#      exit non-zero; patch(1) must leave a .rej behind).
# Asserts the repo tree is unchanged afterwards (tracked files identical).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
if [[ $# -gt 0 ]]; then
  echo "unknown arg: $1 (see --help)" >&2
  exit 1
fi

pass=0
fail=0
ok() { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1" >&2; fail=$((fail + 1)); }

before_status="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no || true)"

echo "=== M1-1: every scripts/*.sh answers --help ==="
for script in "$SCRIPT_DIR"/*.sh; do
  name="$(basename "$script")"
  if out="$("$script" --help 2>&1)" && [[ -n "$out" ]]; then
    ok "$name --help (RC=0, non-empty)"
  else
    bad "$name --help (RC=$? or empty)"
  fi
done

echo "=== M1-1: side-effect-free make targets ==="
# Targets that only read/preview: help list status sync-dry toolchain-updates
# patches-check publish-dry orchestrate-dry vm-status.
for target in help list status sync-dry patches-check publish-dry orchestrate-dry vm-status; do
  if make -C "$ROOT_DIR" "$target" >/tmp/m1-check-make.log 2>&1; then
    ok "make $target (RC=0)"
  else
    bad "make $target (RC=$?; see /tmp/m1-check-make.log)"
  fi
done
# toolchain-updates is read-only but exits 1 when upstream drift exists
# (that is a signal, not a harness failure).
if make -C "$ROOT_DIR" toolchain-updates >/tmp/m1-check-make.log 2>&1; then
  ok "make toolchain-updates (RC=0, pins current)"
else
  rc=$?
  if [[ "$rc" == "1" ]]; then
    ok "make toolchain-updates ran (RC=1: upstream drift signalled, see log)"
  else
    bad "make toolchain-updates (RC=$rc; see /tmp/m1-check-make.log)"
  fi
fi
echo "  (skipped by design — mutate/build/need-VM/interactive, scripts covered via --help above:"
echo "   add remove sync patches vm-ssh-setup vm-ssh vm-brew vm-toolchain vm-toolchain-check vm-shell"
echo "   orchestrate orchestrate-local farm-toolchain)"

echo "=== M1-2: status + sync-dry green ==="
if make -C "$ROOT_DIR" status >/tmp/m1-check-make.log 2>&1; then
  ok "make status (RC=0)"
else
  bad "make status (RC=$?; see /tmp/m1-check-make.log)"
fi
if sync_out="$(make -C "$ROOT_DIR" sync-dry 2>&1)"; then
  if echo "$sync_out" | grep -q "all up to date"; then
    ok "make sync-dry (RC=0, queue settled)"
  else
    bad "make sync-dry (RC=0 but queue not settled — run ./scripts/sync.sh --force)"
  fi
else
  bad "make sync-dry (RC=$?; see output above)"
fi

echo "=== M1-3: patches --check-only (5/5) + .rej fail-closed ==="
if check_out="$("$SCRIPT_DIR/apply-patches.sh" --check-only 2>&1)"; then
  if echo "$check_out" | grep -q "all 5 patches ok"; then
    ok "apply-patches --check-only (5/5)"
  else
    bad "apply-patches --check-only (RC=0 but count mismatch)"
  fi
else
  bad "apply-patches --check-only (RC=$?)"
fi

# Fail-closed self-test in scratch (repo untouched): a patch that cannot
# apply must exit non-zero and leave the tree clean of .rej/.orig.
demo="$(mktemp -d /tmp/m1-check-rej.XXXXXX)"
trap 'rm -rf "$demo"' EXIT
mkdir -p "$demo/patches"
cat > "$demo/patches/series" <<'EOF'
demo-fail.patch
EOF
cat > "$demo/patches/demo-fail.patch" <<'EOF'
# Formula: demo-fail (synthetic M1 fail-closed probe, never applied)
--- a/Formula/demo-fail.rb
+++ b/Formula/demo-fail.rb
@@ -1,3 +1,3 @@
 class DemoFail < Formula
-  url "https://example.com/this-line-does-not-exist-1.0.tar.gz"
+  url "https://example.com/that-line-either-1.0.tar.gz"
 end
EOF
if "$SCRIPT_DIR/apply-patches.sh" --patches-dir "$demo/patches" >/tmp/m1-check-rej.log 2>&1; then
  bad "fail-closed probe unexpectedly applied (expected non-zero exit)"
else
  ok "fail-closed probe rejected with non-zero exit"
fi
if grep -q "does not apply cleanly" /tmp/m1-check-rej.log; then
  ok "fail-closed probe reported drift hint"
else
  bad "fail-closed probe missing drift hint"
fi
# patch(1) .rej mechanics: a hunk whose context does not match must exit
# non-zero and leave a .rej file — the artifact the tripwire guards.
mkdir -p "$demo/rej"
printf 'line one\nline two\nline three\n' > "$demo/rej/victim.txt"
cat > "$demo/rej/split.patch" <<'EOF'
--- a/victim.txt
+++ b/victim.txt
@@ -1,3 +1,3 @@
 line one
-line 2
+line TWO
 line three
EOF
if (cd "$demo/rej" && patch -p1 --forward < split.patch >/tmp/m1-check-patch.log 2>&1); then
  bad "patch(1) unexpectedly applied a bad hunk"
else
  if ls "$demo/rej"/*.rej >/dev/null 2>&1; then
    ok "patch(1) left a .rej on partial apply (tripwire artifact confirmed)"
  else
    bad "patch(1) failed but left no .rej"
  fi
fi

echo "=== M1: tree unchanged (no side effects) ==="
after_status="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no || true)"
if [[ "$before_status" == "$after_status" ]]; then
  ok "tracked tree identical before/after"
else
  bad "tree changed during check:"
  diff <(echo "$before_status") <(echo "$after_status") | sed 's/^/  /' >&2 || true
fi

echo ""
echo "M1 check: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
