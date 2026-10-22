class Watchman < Formula
  include Language::Python::Shebang

  desc "Watch files and take action when they change"
  homepage "https://facebook.github.io/watchman/"
  url "https://github.com/facebook/watchman/archive/refs/tags/v2026.10.19.00.tar.gz"
  sha256 "1d19db2e72b6ebcb0bd6ddd0e10ef55e877c3c4d16009faad20c54ab8eecdae8"
  license "MIT"
  head "https://github.com/facebook/watchman.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/watchman-2026.10.19.00"
    sha256 cellar: :any, sequoia: "1bde318aa5c5468d00fa99f0938e7d9a2f1a4136475033987bb40717d12c38c8"
  end

  depends_on "lurepheonix/intel/cmake" => :build
  depends_on "lurepheonix/intel/cpptoml" => :build
  depends_on "lurepheonix/intel/gflags" => :build
  depends_on "lurepheonix/intel/googletest" => :build
  depends_on "lurepheonix/intel/libevent" => :build
  depends_on "lurepheonix/intel/mvfst" => :build
  depends_on "lurepheonix/intel/openssl@4" => :build
  depends_on "lurepheonix/intel/pkgconf" => :build
  depends_on "lurepheonix/intel/python-setuptools" => :build
  # brew-bottle-farm: external rustup 1.99.1 (build-deps.conf). Requires $CARGO_HOME on PATH.
  # depends_on "rust" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain cargo is visible (superenv would scrub PATH)
  depends_on "lurepheonix/intel/edencommon"
  depends_on "lurepheonix/intel/fb303"
  depends_on "lurepheonix/intel/fbthrift"
  depends_on "lurepheonix/intel/fmt"
  depends_on "lurepheonix/intel/folly"
  depends_on "lurepheonix/intel/glog"
  depends_on "lurepheonix/intel/pcre2"
  # brew-bottle-farm: core python unpourable on Tier-3 guests; use the farm
  # shim-keg (pinned uv/asdf interpreter via farm-toolchain shims).
  # depends_on "python@3.15"  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/python@3.15"

  on_linux do
    depends_on "lurepheonix/intel/boost"
    depends_on "libunwind"
    depends_on "lurepheonix/intel/openssl@4"
  end

  # fmt 12.2 dropped fmt::format from <fmt/core.h>; include <fmt/format.h> where used.
  patch do
    url "https://github.com/facebook/watchman/commit/21e10ae9596a81ac95795ee0915f4308a9c34603.patch?full_index=1"
    sha256 "be595623d5a520de9e1820f1388ebbdf3ef9ff5d665a33c0231fdba36b5d0dbb"
    type :unofficial
    resolves "https://github.com/facebook/watchman/pull/1348"
  end

  def install
    # brew-bottle-farm: cap nested parallelism — cmake -j8 drives cargo,
    # which defaults to -j8 itself (64-way oversubscription OOMs the 16GB
    # guest: posix_spawn EAGAIN). C++ level keeps -j8.
    ENV["CARGO_BUILD_JOBS"] = "1"
    # brew-bottle-farm: keep :std for toolchain cargo PATH, but drop brew's
    # stale CLT CPATH — it injects CLT C headers ahead of libc++ and breaks
    # header search order (same class as the mist-cli SDKROOT/CPATH scrub).
    ENV.delete "CPATH"
    # Drop the `GlobPath` C++ type as its GPL-2.0 header is not mirrored to this repository
    # https://github.com/facebook/watchman/issues/1355
    inreplace "eden/fs/service/eden.thrift" do |s|
      s.gsub! 'cpp_include "eden/fs/utils/GlobPath.h"', ""
      s.gsub! '@cpp.Adapter{name = "::facebook::eden::GlobPathAdapter"}', ""
    end
    inreplace "watchman/watcher/eden.cpp", "std::move(name).intoFbString()", "std::move(name)"

    # NOTE: Setting `BUILD_SHARED_LIBS=ON` will generate DSOs for Eden libraries.
    #       These libraries are not part of any install targets and have the wrong
    #       RPATHs configured, so will need to be installed and relocated manually
    #       if they are built as shared libraries. They're not used by any other
    #       formulae, so let's link them statically instead. This is done by default.
    args = %W[
      -DENABLE_EDEN_SUPPORT=ON
      # brew-bottle-farm: pin the build-time interpreter to the farm shim
      # (bare `python3` resolves via builder PATH — nondeterministic).
      -DPython3_EXECUTABLE=#{Formula["lurepheonix/intel/python@3.15"].opt_bin}/python3.15
      -DWATCHMAN_VERSION_OVERRIDE=#{version}
      -DWATCHMAN_BUILDINFO_OVERRIDE=#{tap&.user || "Homebrew"}
      -DWATCHMAN_USE_XDG_STATE_HOME=ON
      -DCMAKE_CXX_STANDARD=20
      -DOPENSSL_ROOT_DIR=#{formula_opt_prefix("openssl@4")}
    ]
    # Avoid overlinking with libsodium and mvfst
    args << "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip_dylibs" if OS.mac?

    system "cmake", "-S", ".", "-B", "build", *args, *std_cmake_args
    # brew-bottle-farm: cap make-level parallelism (see CARGO_BUILD_JOBS
    # above — full -j8 plus nested cargo exhausts the 16GB guest and spawns
    # fail with EAGAIN even at -j4/-j2).
    system "cmake", "--build", "build", "--parallel", "2"
    system "cmake", "--install", "build"

    # brew-bottle-farm: cmake installs straight into prefix
    # (std_cmake_args sets CMAKE_INSTALL_PREFIX=#{prefix}); only relocate
    # when the nested prefix/usr/local layout is actually present.
    nested = Pathname.new(File.join(prefix, HOMEBREW_PREFIX))
    if (nested/"bin").directory?
      bin.install (nested/"bin").children
    end
    if (nested/"lib").directory?
      lib.install (nested/"lib").children
    end
    rm_r(nested) if nested.directory?

    # brew-bottle-farm: Tier-3 consumers have no core python; helpers run
    # under any PATH python3 (see caveats — e.g. `uv python install 3.15`).
    # brew-bottle-farm: cmake bakes the build-time interpreter path (a
    # builder-local location no consumer has); helpers must resolve python3
    # via PATH instead. rewrite_shebang can't match absolute non-/usr/bin
    # paths, so rewrite first lines directly.
    bin.children.each do |f|
      next unless f.file?
      lines = f.readlines
      next unless lines.first&.start_with?("#!")
      lines[0] = "#!/usr/bin/env python3\n"
      f.atomic_write(lines.join)
    end
  end

  def caveats
    <<~EOS
      The watchman daemon and `watchman` CLI need no Python. Helper scripts
      installed alongside them run under any `python3` on your PATH, e.g.:
        uv python install 3.15
    EOS
  end

  test do
    assert_equal(version.to_s, shell_output("#{bin}/watchman -v").chomp)
  end
end
