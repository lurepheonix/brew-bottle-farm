#!/usr/bin/env bash
set -euo pipefail

# guest-build-detached.sh — launch build.sh detached on the VM guest.
#
# The multi-hour bottle loop must survive ssh/host death (a dropped ssh
# session SIGHUPs the whole remote process group — seen live twice). So the
# build daemonizes into its own session here; the launching ssh exits
# immediately and the host polls for completion (see orchestrate.sh).
#
# macOS has no setsid(1), so daemonization is a tiny /usr/bin/python3
# double-fork (no third-party deps). uv/asdf/rustup state is untouched.
#
# Usage (on the guest; env travels via `env` prefix from orchestrate.sh):
#   env TAG=sequoia OUTPUT_DIR=/tmp/shared/bottles TAP_ROOT_URL=... \
#     FARM_TAP_NAME=<user>/<tap> TAP_USER=<user> TAP_REPO_NAME=homebrew-<tap> \
#     FARM_KEEP_INSTALLED=1 FARM_END_CLEANUP=1 HOMEBREW_NO_AUTO_UPDATE=1 \
#     FARM_RESUME=0 \
#     bash /tmp/shared/scripts/guest-build-detached.sh /tmp/shared/build-queue.txt
#
# Idempotent: a live previous launch re-attaches (no double build); a stale
# pid relaunches. A relaunch with a DIFFERENT queue while the old build lives
# is refused (fail closed — finish or kill the guest build first).
# State: /tmp/farm-build.pid (daemon pid), /tmp/farm-build.queue (queue
# sha256 it runs), /tmp/farm-build.out (full log), /tmp/farm-build.rc
# (build.sh exit code on completion). Override roots via FARM_BUILD_* env.

PIDFILE="${FARM_BUILD_PIDFILE:-/tmp/farm-build.pid}"
QUEUEFILE_STATE="${FARM_BUILD_QUEUESTATE:-/tmp/farm-build.queue}"
RCFILE="${FARM_BUILD_RCFILE:-/tmp/farm-build.rc}"
LOGFILE="${FARM_BUILD_LOG:-/tmp/farm-build.out}"
BUILD_SCRIPT="${FARM_BUILD_SCRIPT:-/tmp/shared/scripts/build.sh}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: [env ...] bash guest-build-detached.sh [build-queue.txt]"
  echo "  Launches build.sh detached on the VM guest (survives ssh/host death)."
  echo "  Env: TAG OUTPUT_DIR TAP_ROOT_URL FARM_TAP_NAME TAP_USER TAP_REPO_NAME"
  echo "       FARM_KEEP_INSTALLED FARM_END_CLEANUP HOMEBREW_NO_AUTO_UPDATE FARM_RESUME"
  echo "       FARM_BUILD_PIDFILE FARM_BUILD_RCFILE FARM_BUILD_LOG FARM_BUILD_SCRIPT"
  exit 0
fi
QUEUE_FILE="${1:-/tmp/shared/build-queue.txt}"

if [[ ! -f "$BUILD_SCRIPT" ]]; then
  echo "error: build script not found: $BUILD_SCRIPT (stage it first)" >&2
  exit 1
fi
if [[ ! -f "$QUEUE_FILE" ]]; then
  echo "error: queue file not found: $QUEUE_FILE" >&2
  exit 1
fi

_queue_sha="$(/usr/bin/shasum -a 256 "$QUEUE_FILE" 2>/dev/null | awk '{print $1}' || echo "unknown")"
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo none)" 2>/dev/null; then
  _running_queue="$(cat "$QUEUEFILE_STATE" 2>/dev/null || echo unknown)"
  if [[ "$_running_queue" != "$_queue_sha" ]]; then
    echo "error: guest build pid $(cat "$PIDFILE") is alive running a DIFFERENT queue ($_running_queue vs $_queue_sha)" >&2
    echo "hint: wait for it (re-run orchestrate to re-attach) or kill it on the guest first" >&2
    exit 1
  fi
  echo "guest build already running (pid $(cat "$PIDFILE")) — attaching, no new launch"
  exit 0
fi
# No live build: drop any stale completion marker so the host poll cannot
# mistake a previous run for this one.
rm -f "$RCFILE"

/usr/bin/python3 - "$LOGFILE" "$PIDFILE" "$QUEUEFILE_STATE" "$RCFILE" "$BUILD_SCRIPT" "$QUEUE_FILE" "$_queue_sha" <<'PYEOF'
import os, subprocess, sys
log, pidfile, queuestate, rcfile, script, queue, qsha = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
# Double-fork into a fresh session: immune to the launching ssh's SIGHUP.
p1 = os.fork()
if p1 > 0:
    sys.exit(0)
os.setsid()
p2 = os.fork()
if p2 > 0:
    os._exit(0)
open(pidfile, "w").write(str(os.getpid()))
open(queuestate, "w").write(qsha)
devnull = os.open(os.devnull, os.O_RDONLY)
logfd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.dup2(devnull, 0)
os.dup2(logfd, 1)
os.dup2(logfd, 2)
os.chdir("/")
rc = subprocess.call(["/bin/bash", script, queue], env=dict(os.environ), close_fds=True)
open(rcfile, "w").write(str(rc))
os._exit(0)
PYEOF

echo "launched (pidfile $PIDFILE, log $LOGFILE, rc $RCFILE)"
