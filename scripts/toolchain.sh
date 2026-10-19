#!/usr/bin/env bash
set -euo pipefail

# toolchain.sh — provision external build toolchains inside the VM (or local build host)
# Usage: ./scripts/toolchain.sh [--check] [--tag sequoia]
#   --check   verify only (no install), exit non-zero on mismatch
#
# Reads:
#   build-deps.conf (single pin per tool)
#   .tool-versions (asdf python pin, must match build-deps.conf for python)
# Provisions:
#   asdf via precompiled release tarball (pinned in build-deps.conf, no brew needed)
#   rust via rustup (x86_64-apple-darwin, pinned)
#   go   via official tarball (darwin-amd64, pinned)
#   python via asdf (local-machine rule, compiles from source once)
# Writes:
#   /tmp/shared/toolchain.env (or $TOOLCHAIN_ENV) — sourced by build.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DEPS_CONF="$ROOT_DIR/build-deps.conf"
TOOL_VERSIONS="$ROOT_DIR/.tool-versions"
TOOLCHAIN_ENV="${TOOLCHAIN_ENV:-/tmp/shared/toolchain.env}"
CHECK_ONLY="false"
TAG="${TAG:-sequoia}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY="true"; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    --env) TOOLCHAIN_ENV="$2"; shift 2 ;;
    -h|--help) cat <<'EOF'
Usage: ./scripts/toolchain.sh [--check] [--tag sequoia] [--env /tmp/shared/toolchain.env]
  Provisions rustup + go tarball + asdf (precompiled) + asdf python per build-deps.conf.
  --check  verify installed versions match pins, do not install.
EOF
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$BUILD_DEPS_CONF" ]]; then
  echo "error: $BUILD_DEPS_CONF not found" >&2
  exit 1
fi

parse_conf() {
  # output: name strategy pin source
  grep -v '^[[:space:]]*#' "$BUILD_DEPS_CONF" | grep -v '^[[:space:]]*$' | awk '{print $1, $2, $3, $4}'
}

echo "=== toolchain.sh (tag $TAG, check $CHECK_ONLY) ==="
echo "conf: $BUILD_DEPS_CONF"
echo "env:  $TOOLCHAIN_ENV"
cat "$BUILD_DEPS_CONF" | sed 's/^/  /'

# Collect pins
RUST_PIN=""; RUST_SOURCE=""
GO_PIN=""; GO_SOURCE=""
PY_PIN=""; PY_SOURCE=""
ASDF_PIN=""; ASDF_SOURCE=""
while read -r name strategy pin source; do
  case "$name" in
    rust) RUST_PIN="$pin"; RUST_SOURCE="$source" ;;
    go) GO_PIN="$pin"; GO_SOURCE="$source" ;;
    python@3.13) PY_PIN="$pin"; PY_SOURCE="$source" ;;
    python) PY_PIN="$pin"; PY_SOURCE="$source" ;;
    asdf) ASDF_PIN="$pin"; ASDF_SOURCE="$source" ;;
  esac
done < <(parse_conf)

echo "pins: rust=${RUST_PIN:-none} go=${GO_PIN:-none} python=${PY_PIN:-none} asdf=${ASDF_PIN:-none}"

# Headless prlctl exec ships a minimal PATH — brew may be installed but invisible,
# and user-local tool dirs are never on it. Normalize before check/provision.
export PATH="/usr/local/bin:/usr/local/sbin:/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"

# 0. HOME sanity: prlctl exec without --user runs as root with HOME=/,
# which makes rustup fail with "$HOME differs from euid-obtained home
# directory" and CARGO_HOME resolve to /.cargo (read-only).
# Try to recover the real user's HOME; otherwise fail with an actionable hint.
if [[ "$(id -u)" -eq 0 ]]; then
  euid_home="$(eval echo ~root 2>/dev/null || echo /var/root)"
  if [[ "${HOME:-/}" == "/" || "${HOME:-}" != "$euid_home" ]]; then
    real_user="${SUDO_USER:-}"
    if [[ -z "${real_user:-}" && -e /dev/console ]]; then
      real_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
    fi
    if [[ -n "${real_user:-}" && "$real_user" != "root" ]]; then
      real_home="$(dscl . -read "/Users/$real_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
      [[ -z "${real_home:-}" ]] && real_home="/Users/$real_user"
      if [[ -d "$real_home" ]]; then
        echo "note: running as root with HOME=${HOME:-<unset>} — switching HOME to $real_home (user $real_user)" >&2
        export HOME="$real_home"
      fi
    fi
  fi
  if [[ "${HOME:-/}" == "/" || "${HOME:-}" == "$euid_home" ]]; then
    if [[ "${ALLOW_ROOT:-0}" != "1" ]]; then
      echo "error: running as root with bogus HOME (${HOME:-<unset>} vs euid-home $euid_home)." >&2
      echo "hint: re-run as the GUI user instead of root:" >&2
      echo "  VM_USER=\$(stat -f %Su /dev/console) ./scripts/vm.sh exec bash /tmp/shared/scripts/toolchain.sh" >&2
      echo "  (e.g. VM_USER=kotiara ./scripts/vm.sh exec bash /tmp/shared/scripts/toolchain.sh)" >&2
      echo "  or: prlctl exec <vm> --user <gui-user> bash /tmp/shared/scripts/toolchain.sh" >&2
      exit 1
    fi
    echo "warn: ALLOW_ROOT=1 — proceeding as root with HOME=$HOME (rust/go only; brew/asdf will fail)" >&2
  fi
fi
# Refuse a CARGO_HOME that would land on the read-only root filesystem.
if [[ "${CARGO_HOME:-$HOME/.cargo}" == "/.cargo" || "${CARGO_HOME:-$HOME/.cargo}" == "//.cargo"* ]]; then
  echo "error: CARGO_HOME would be '${CARGO_HOME:-$HOME/.cargo}' (HOME=$HOME) — refusing (read-only /)." >&2
  exit 1
fi

# Verify .tool-versions sync for python (single-pin rule)
if [[ -n "$PY_PIN" && -f "$TOOL_VERSIONS" ]]; then
  asdf_py_pin=$(grep -E '^python[[:space:]]' "$TOOL_VERSIONS" 2>/dev/null | awk '{print $2}' | head -n1 || true)
  if [[ -n "$asdf_py_pin" && "$asdf_py_pin" != "$PY_PIN" ]]; then
    echo "error: build-deps.conf python pin $PY_PIN != .tool-versions python $asdf_py_pin (single-pin rule)" >&2
    exit 1
  fi
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
  echo "checking toolchain..."
  failed=0
  if [[ -n "$ASDF_PIN" ]]; then
    if ! command -v asdf >/dev/null 2>&1; then
      echo "  ✗ asdf: not on PATH" >&2; failed=1
    else
      ver=$(asdf --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
      if [[ "$ver" != "$ASDF_PIN"* ]]; then
        echo "  ✗ asdf: have $ver, want $ASDF_PIN*" >&2; failed=1
      else
        echo "  ✓ asdf $ver"
      fi
    fi
  fi
  if [[ -n "$RUST_PIN" ]]; then
    if ! command -v cargo >/dev/null 2>&1; then
      echo "  ✗ rust: cargo not on PATH" >&2; failed=1
    else
      ver=$(cargo --version 2>/dev/null | awk '{print $2}' || true)
      if [[ "$ver" != "$RUST_PIN"* ]]; then
        echo "  ✗ rust: have $ver, want $RUST_PIN*" >&2; failed=1
      else
        echo "  ✓ rust $ver"
      fi
    fi
  fi
  if [[ -n "$GO_PIN" ]]; then
    # Resolve GOROOT in order: $GOROOT env (if version matches) -> user-local
    # -> legacy /usr/local (pre-Option-A installs). User-local is the default
    # for fresh installs so no sudo is needed headless (prlctl exec --user).
    user_base="${TOOLCHAIN_PREFIX:-$HOME/.local}"
    user_pin="$user_base/go-$GO_PIN"
    legacy_pin="/usr/local/go-$GO_PIN"
    candidates=()
    [[ -n "${GOROOT:-}" ]] && candidates+=("$GOROOT")
    candidates+=("$user_pin" "$legacy_pin")
    go_bin=""
    for cand in "${candidates[@]}"; do
      if [[ -x "$cand/bin/go" ]]; then
        ver=$("$cand/bin/go" version 2>/dev/null | awk '{print $3}' | sed 's/go//' || true)
        if [[ "$ver" == "$GO_PIN" ]]; then
          go_bin="$cand/bin/go"
          break
        fi
      fi
    done
    if [[ -n "$go_bin" ]]; then
      ver=$("$go_bin" version 2>/dev/null | awk '{print $3}' | sed 's/go//' || true)
      echo "  ✓ go $ver ($go_bin)"
    elif command -v go >/dev/null 2>&1; then
      ver=$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//' || true)
      if [[ "$ver" != "$GO_PIN" ]]; then
        echo "  ✗ go: have $ver, want $GO_PIN" >&2; failed=1
      else
        echo "  ✓ go $ver ($(command -v go))"
      fi
    else
      echo "  ✗ go not found" >&2; failed=1
    fi
  fi
  if [[ -n "$PY_PIN" ]]; then
    py_bin=""
    if [[ -x "$HOME/.asdf/shims/python3" ]]; then
      py_bin="$HOME/.asdf/shims/python3"
      ver=$("$py_bin" --version 2>&1 | awk '{print $2}' || true)
    elif command -v python3 >/dev/null 2>&1; then
      py_bin=$(command -v python3)
      ver=$(python3 --version 2>&1 | awk '{print $2}' || true)
    else
      ver=""
    fi
    if [[ -z "$ver" ]]; then
      echo "  ✗ python: not found" >&2; failed=1
    elif [[ "$ver" != "$PY_PIN"* ]]; then
      echo "  ✗ python: have $ver, want $PY_PIN* ($py_bin)" >&2; failed=1
    else
      echo "  ✓ python $ver ($py_bin)"
    fi
  fi
  exit $failed
fi

# Provision

# 1. Rust via rustup
if [[ -n "$RUST_PIN" ]]; then
  export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
  if [[ -x "$CARGO_HOME/bin/cargo" ]]; then
    have=$( "$CARGO_HOME/bin/cargo" --version 2>/dev/null | awk '{print $2}' || true)
    if [[ "$have" == "$RUST_PIN"* ]]; then
      echo "rust $have already installed at $CARGO_HOME"
    else
      echo "rust have $have, want $RUST_PIN — reinstalling"
      curl --proto '=https' --tlsv1.2 -sSf "$RUST_SOURCE" | sh -s -- -y --profile minimal --default-toolchain "$RUST_PIN" --no-modify-path || \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain "$RUST_PIN" --no-modify-path
    fi
  else
    echo "installing rust $RUST_PIN via rustup..."
    # RUST_SOURCE is like rustup:https://sh.rustup.rs
    url="${RUST_SOURCE#rustup:}"
    [[ -z "$url" ]] && url="https://sh.rustup.rs"
    curl --proto '=https' --tlsv1.2 -sSf "$url" | sh -s -- -y --profile minimal --default-toolchain "$RUST_PIN" --no-modify-path
  fi
  # Ensure toolchain pinned
  "$CARGO_HOME/bin/rustup" toolchain list | grep -q "$RUST_PIN" || "$CARGO_HOME/bin/rustup" toolchain install "$RUST_PIN" --profile minimal --no-self-update
  "$CARGO_HOME/bin/rustup" default "$RUST_PIN"
  echo "rust: $("$CARGO_HOME/bin/cargo" --version) $("$CARGO_HOME/bin/rustc" --version | head -n1)"
else
  echo "rust: not configured (skip)"
fi

# 2. Go via official tarball into user-writable prefix (no sudo needed headless).
# GOROOT = ${TOOLCHAIN_PREFIX:-$HOME/.local}/go-<pin> (override with TOOLCHAIN_PREFIX
# or GOROOT env). Legacy /usr/local/go-<pin> installs are reused if present and
# version-matched, so existing snapshots keep working.
if [[ -n "$GO_PIN" ]]; then
  # GO_SOURCE is full URL like https://go.dev/dl/go1.27.1.darwin-amd64.tar.gz
  url="$GO_SOURCE"
  GOROOT_BASE="${TOOLCHAIN_PREFIX:-$HOME/.local}"
  GOROOT_PIN="$GOROOT_BASE/go-$GO_PIN"
  LEGACY_PIN="/usr/local/go-$GO_PIN"
  # Reuse a version-matched install wherever it lives (GOROOT env > user-local > legacy).
  if [[ -n "${GOROOT:-}" && -x "$GOROOT/bin/go" ]]; then
    have=$("$GOROOT/bin/go" version 2>/dev/null | awk '{print $3}' | sed 's/go//' || true)
    if [[ "$have" == "$GO_PIN" ]]; then
      echo "go $have already at $GOROOT (from \$GOROOT)"
      GOROOT_PIN="$GOROOT"
    fi
  fi
  if [[ ! -x "$GOROOT_PIN/bin/go" && -x "$LEGACY_PIN/bin/go" ]]; then
    have=$("$LEGACY_PIN/bin/go" version 2>/dev/null | awk '{print $3}' | sed 's/go//' || true)
    if [[ "$have" == "$GO_PIN" ]]; then
      echo "go $have already at $LEGACY_PIN (legacy /usr/local, reusing)"
      GOROOT_PIN="$LEGACY_PIN"
    fi
  fi
  if [[ -x "$GOROOT_PIN/bin/go" ]]; then
    have=$("$GOROOT_PIN/bin/go" version 2>/dev/null | awk '{print $3}' | sed 's/go//' || true)
    if [[ "$have" != "$GO_PIN" ]]; then
      echo "go have $have, want $GO_PIN — reinstalling"
      rm -rf "$GOROOT_PIN"
    else
      echo "go $have already at $GOROOT_PIN"
    fi
  fi
  if [[ ! -x "$GOROOT_PIN/bin/go" ]]; then
    # Fresh install always goes to the user-local prefix (writable without sudo).
    GOROOT_PIN="$GOROOT_BASE/go-$GO_PIN"
    # Drop a stale mismatched install at the target before reinstalling.
    if [[ -x "$GOROOT_PIN/bin/go" ]]; then
      rm -rf "$GOROOT_PIN"
    fi
    echo "installing go $GO_PIN from $url to $GOROOT_PIN ..."
    tmp=$(mktemp -d)
    curl -fsSL "$url" -o "$tmp/go.tar.gz"
    mkdir -p "$GOROOT_BASE"
    tar -xz -f "$tmp/go.tar.gz" -C "$tmp"
    # tar contains go/ dir
    rm -rf "$GOROOT_PIN"
    mv "$tmp/go" "$GOROOT_PIN"
    rm -rf "$tmp"
  fi
  # Best-effort convenience symlink; never fatal headless (no TTY for sudo).
  if [[ -L /usr/local/go || ! -e /usr/local/go ]]; then
    sudo -n ln -sfn "$GOROOT_PIN" /usr/local/go 2>/dev/null || true
  fi
  echo "go: $($GOROOT_PIN/bin/go version)"
  export GOROOT="$GOROOT_PIN"
  export PATH="$GOROOT/bin:$PATH"
else
  echo "go: not configured (skip)"
fi

# 3. Python via asdf
if [[ -n "$PY_PIN" ]]; then
  echo "python via asdf $PY_PIN ..."
  if ! command -v git >/dev/null 2>&1; then
    echo "error: git not found — required by asdf (plugin installs) and implied by the CLT step" >&2
    echo "hint: inside the VM's Terminal.app run: xcode-select --install" >&2
    exit 1
  fi
  if ! command -v asdf >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      echo "installing asdf via brew..."
      brew install asdf
      # brew asdf needs sourcing
      if [[ -f "/usr/local/opt/asdf/libexec/asdf.sh" ]]; then
        # shellcheck disable=SC1091
        source "/usr/local/opt/asdf/libexec/asdf.sh" || true
      fi
    elif [[ -n "${ASDF_PIN:-}" && -n "${ASDF_SOURCE:-}" ]]; then
      echo "installing asdf $ASDF_PIN from precompiled tarball (no brew)..."
      tmp=$(mktemp -d)
      # Fail loud: no fallback URL. 404 / asset rename => curl -f exits non-zero (set -e).
      curl -fsSL "$ASDF_SOURCE" -o "$tmp/asdf.tar.gz"
      tar -xz -f "$tmp/asdf.tar.gz" -C "$tmp"
      # Go-era archives contain a single top-level `asdf` binary.
      if [[ ! -f "$tmp/asdf" ]]; then
        echo "error: asdf tarball has no top-level ./asdf binary — asset layout changed?" >&2
        echo "hint: update the asdf line in build-deps.conf (see releases page)" >&2
        tar -tzf "$tmp/asdf.tar.gz" >&2 || true
        rm -rf "$tmp"
        exit 1
      fi
      mkdir -p "$HOME/.local/bin"
      if command -v install >/dev/null 2>&1; then
        install -m 755 "$tmp/asdf" "$HOME/.local/bin/asdf"
      else
        cp "$tmp/asdf" "$HOME/.local/bin/asdf"
        chmod 755 "$HOME/.local/bin/asdf"
      fi
      rm -rf "$tmp"
      export PATH="$HOME/.local/bin:$PATH"
      # `asdf --version` prints e.g. "asdf version 0.20.0 (revision unknown)" — extract semver.
      have_asdf=$("$HOME/.local/bin/asdf" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
      if [[ "$have_asdf" != "$ASDF_PIN"* ]]; then
        echo "error: bootstrapped asdf version '$have_asdf' != pinned $ASDF_PIN" >&2
        exit 1
      fi
      echo "asdf $have_asdf installed to $HOME/.local/bin/asdf"
    else
      echo "error: asdf not found, brew unavailable, and no asdf bootstrap pin in build-deps.conf" >&2
      exit 1
    fi
  fi
  # Ensure asdf binary + shims on PATH (both Go-era and legacy layouts)
  export PATH="$HOME/.local/bin:$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"
  if [[ -f "$HOME/.asdf/asdf.sh" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.asdf/asdf.sh" || true
  fi
  if ! asdf plugin list 2>/dev/null | grep -q "^python$"; then
    echo "adding asdf python plugin..."
    asdf plugin add python || true
  fi
  # Ensure .tool-versions has correct pin (repo file)
  if [[ -f "$ROOT_DIR/.tool-versions" ]]; then
    cp "$ROOT_DIR/.tool-versions" "$HOME/.tool-versions" 2>/dev/null || true
  fi
  # Install (compiles from source — one-time per snapshot)
  if ! asdf list python 2>/dev/null | grep -q "$PY_PIN"; then
    echo "asdf installing python $PY_PIN (this compiles CPython, ~10-20 min)..."
    asdf install python "$PY_PIN"
  else
    echo "python $PY_PIN already installed via asdf"
  fi
  asdf set -u python "$PY_PIN" 2>/dev/null || asdf global python "$PY_PIN" 2>/dev/null || asdf local python "$PY_PIN" 2>/dev/null || true
  asdf reshim python 2>/dev/null || true
  echo "python: $(python3 --version 2>&1) ($(command -v python3))"
  # Also expose python3.13 shim explicitly if needed
else
  echo "python: not configured (skip)"
fi

# 4. Write toolchain.env (and source it so the rest of this shell uses it)
mkdir -p "$(dirname "$TOOLCHAIN_ENV")"
_DEFAULT_GOROOT="${GOROOT:-${TOOLCHAIN_PREFIX:-$HOME/.local}/go-$GO_PIN}"
cat > "$TOOLCHAIN_ENV" <<EOF
# toolchain.env — generated by scripts/toolchain.sh (tag $TAG) — source this in build.sh
# Usage: source "$TOOLCHAIN_ENV"  (or: source /tmp/shared/toolchain.env)
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export GOROOT="$_DEFAULT_GOROOT"
export PATH="\$HOME/.local/bin:\$CARGO_HOME/bin:\$GOROOT/bin:\$HOME/.asdf/shims:\$HOME/.asdf/bin:\$PATH"
# Pins for verification:
export TOOLCHAIN_RUST_PIN="$RUST_PIN"
export TOOLCHAIN_GO_PIN="$GO_PIN"
export TOOLCHAIN_PYTHON_PIN="$PY_PIN"
export TOOLCHAIN_ASDF_PIN="$ASDF_PIN"
EOF
echo "wrote $TOOLCHAIN_ENV:"
cat "$TOOLCHAIN_ENV" | sed 's/^/  /'
# Source it so GOROOT/PATH/CARGO_HOME take effect for the --check below
# shellcheck disable=SC1090
source "$TOOLCHAIN_ENV" || true

# Final verify
echo "verifying toolchain..."
bash "$SCRIPT_DIR/toolchain.sh" --check || {
  echo "error: toolchain verification failed" >&2
  exit 1
}
echo "toolchain ready. Snapshot VM with: ./scripts/vm.sh snapshot toolchain-ready"
