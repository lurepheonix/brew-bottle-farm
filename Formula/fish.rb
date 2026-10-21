class Fish < Formula
  desc "User-friendly command-line shell for UNIX-like operating systems"
  homepage "https://fishshell.com"
  url "https://github.com/fish-shell/fish-shell/releases/download/4.9.3/fish-4.9.3.tar.xz"
  sha256 "20998a25f73217ddcc19f499055fd587e9912d1ad6e7109120fbcf2871f0b98c"
  license "GPL-2.0-only"
  compatibility_version 1
  head "https://github.com/fish-shell/fish-shell.git", branch: "master"

  livecheck do
    url :stable
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/fish-4.9.3"
    sha256 cellar: :any, sequoia: "4d2689338fefc54f479215b76cc62a68e1be965252f20fc478759693739943df"
  end

  depends_on "cmake" => :build
  # brew-bottle-farm: external rustup 1.99.1 (build-deps.conf). Requires $CARGO_HOME on PATH.
  # depends_on "rust" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain cargo is visible (superenv would scrub PATH)
  # brew-bottle-farm: qualify intra-queue dep to the farm-bottled copy
  # (single-sourced per install; see patches/README.md).
  # depends_on "sphinx-doc" => :build  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/sphinx-doc" => :build
  depends_on "pcre2"

  def install
    system "cmake", "-S", ".", "-B", "build", *std_cmake_args,
                    "-DCMAKE_INSTALL_SYSCONFDIR=#{etc}",
                    "-DWITH_DOCS=ON",
                    "-Dextra_functionsdir=#{HOMEBREW_PREFIX}/share/fish/vendor_functions.d",
                    "-Dextra_completionsdir=#{HOMEBREW_PREFIX}/share/fish/vendor_completions.d",
                    "-Dextra_confdir=#{HOMEBREW_PREFIX}/share/fish/vendor_conf.d"
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  test do
    system bin/"fish", "-c", "echo"
    output = shell_output("#{bin}/fish -c 'set --show fish_function_path'")
    assert_match "#{HOMEBREW_PREFIX}/share/fish/vendor_functions.d", output
  end
end
