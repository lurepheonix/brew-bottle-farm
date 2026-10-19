# farm-toolchain — versioned external toolchain bundle for brew-bottle-farm
#
# This formula is authored here (NOT mirrored from homebrew/core). It bottles
# the *provider* of every external build tool: rustup/go/uv+asdf/python/ruby/node
# pins travel with the bottle, so any machine with this formula installed
# resolves the same interpreters at the same stable prefix:
#   /usr/local/opt/farm-toolchain/bin/python3.15 (etc.)
#
# Bottles may therefore reference ("leak to") the toolchain prefix by design —
# leaves never runtime-link interpreters, and bottled intermediaries that do
# (meson/sphinx-doc/asciidoctor) are patched to this prefix instead of core.
# See patches/README.md (runtime-python policy) and docs/stack.md.
#
# Version policy: bump the version on ANY pin change in build-deps.conf
# (sync.sh auto-queues patched formulae on slot changes via the lock).
#
# First-release procedure (url/sha256 below):
#   1. git tag farm-toolchain-0.1.0 && git push origin farm-toolchain-0.1.0
#   2. sha256=$(curl -fsSL <url> | shasum -a 256) and fill `sha256` below
#   3. Build in the VM (fast: no toolchain needed, install only stages files):
#        echo farm-toolchain >> build-queue.txt  # one-off; sync filters it normally
#        ./scripts/vm.sh exec env TAG=sequoia bash /tmp/shared/scripts/build.sh
#   4. publish.sh creates the per-formula release as usual.
class FarmToolchain < Formula
  desc "Versioned external build toolchains for brew-bottle-farm (rust/go/python/ruby/node)"
  homepage "https://github.com/<user>/homebrew-intel"
  # Repo archive of the farm at the matching tag (pins + provision script travel together).
  # Replace <user> with the farm owner's GitHub name when forking this tap.
  url "https://github.com/<user>/brew-bottle-farm/archive/refs/tags/farm-toolchain-0.1.0.tar.gz"
  version "0.1.0"
  # Filled at first release (see procedure above). Install refuses a bad checksum.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  # No depends_on: this formula must never pull brewed interpreters (it replaces them).

  def install
    libexec.install "scripts/toolchain.sh"
    libexec.install "build-deps.conf"
    libexec.install ".tool-versions"

    # Stable Cellar shims -> pinned user-space interpreters.
    # A shim resolves at RUN time (uv first, asdf fallback); the pin is baked
    # at install time from the staged build-deps.conf, so shims always agree
    # with the lock. Missing provision fails loud with a hint, never silently.
    pins = {}
    File.foreach("build-deps.conf") do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")
      parts = line.split
      next unless parts.size >= 3 && %w[external bottled].include?(parts[1])
      pins[parts[0]] = parts[2]
    end
    {
      "python3.13" => %w[python@3.13 python],
      "python3.14" => %w[python@3.14 python],
      "python3.15" => %w[python@3.15 python],
      "ruby" => %w[ruby ruby],
      "node" => %w[node nodejs],
    }.each do |shim, (slot, plugin)|
      pin = pins.fetch(slot)
      (bin/shim).write <<~EOS
        #!/usr/bin/env bash
        # farm-toolchain resolver shim: #{shim} == #{slot} #{pin}.
        # Stable Cellar path; resolves to the pinned user-space interpreter.
        if [ "#{plugin}" = "python" ] && command -v uv >/dev/null 2>&1; then
          if target=$(uv python find "#{pin}" 2>/dev/null); then
            exec "$target" "$@"
          fi
        fi
        home_bin="$HOME/.asdf/installs/#{plugin}/#{pin}/bin/#{shim}"
        if [ -x "$home_bin" ]; then
          exec "$home_bin" "$@"
        fi
        echo "farm-toolchain: #{shim} #{pin} not provisioned — run: farm-toolchain provision" >&2
        exit 1
      EOS
    end

    # Dispatcher: provision/check wrap the vendored provision script with the
    # vendored pins (BUILD_DEPS_CONF/TOOL_VERSIONS overrides supported by toolchain.sh).
    # No args == provision (toolchain.sh default); --check verifies only.
    (bin/"farm-toolchain").write <<~EOS
      #!/usr/bin/env bash
      set -euo pipefail
      _root="$(cd "$(dirname "$0")/.." && pwd)"
      export BUILD_DEPS_CONF="$_root/libexec/build-deps.conf"
      export TOOL_VERSIONS="$_root/libexec/.tool-versions"
      exec bash "$_root/libexec/toolchain.sh" "$@"
    EOS
  end

  def caveats
    <<~EOS
      farm-toolchain provides build interpreters only (never bottled runtimes).
      Provision once per machine/VM (user space, kept across snapshots):
        farm-toolchain provision   # rustup + go + uv/asdf python slots + ruby/node
        farm-toolchain --check     # verify pins
      Bottled formulae link /usr/local/opt/farm-toolchain — keep this formula
      installed wherever you install farm bottles.
    EOS
  end

  test do
    assert_predicate bin/"farm-toolchain", :executable?
    assert_predicate bin/"python3.15", :executable?
    assert_match "Usage", shell_output("#{bin}/farm-toolchain --help")
  end
end
