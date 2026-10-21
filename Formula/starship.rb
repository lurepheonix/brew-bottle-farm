class Starship < Formula
  desc "Cross-shell prompt for astronauts"
  homepage "https://starship.rs/"
  url "https://github.com/starship/starship/archive/refs/tags/v1.27.0.tar.gz"
  sha256 "f1887ffa88a7ba437d2932501794047e28d03387996f7d1c364631c053cffc44"
  license "ISC"
  head "https://github.com/starship/starship.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/starship-1.27.0"
    sha256 cellar: :any_skip_relocation, sequoia: "403ac416b629401ab5cb34a895325b497e4b493093b9bd2b339c4703e1a5b773"
  end

  depends_on "cmake" => :build
  depends_on "pkgconf" => :build
  # brew-bottle-farm: external rustup 1.99.1 (build-deps.conf). Requires $CARGO_HOME on PATH.
  # depends_on "rust" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain cargo is visible (superenv would scrub PATH)

  on_linux do
    depends_on "dbus"
    depends_on "zlib-ng-compat"
  end

  deny_network_access!

  def fetch
    system "cargo", "fetch", *std_cargo_fetch_args
  end

  def install
    system "cargo", "install", *std_cargo_args

    generate_completions_from_executable(bin/"starship", "completions")
  end

  test do
    ENV["STARSHIP_CONFIG"] = ""
    assert_equal "[1;32m❯[0m ", shell_output("#{bin}/starship module character")
  end
end
