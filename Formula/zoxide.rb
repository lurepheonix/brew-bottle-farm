class Zoxide < Formula
  desc "Shell extension to navigate your filesystem faster"
  homepage "https://github.com/ajeetdsouza/zoxide"
  url "https://github.com/ajeetdsouza/zoxide/archive/refs/tags/v0.10.0.tar.gz"
  sha256 "4fcd4272b013a10b637dbcc299c58a9924b94470a9042677ca1a204cc2e9150e"
  license "MIT"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/zoxide-0.10.0"
    sha256 cellar: :any_skip_relocation, sequoia: "da5a40c23b2ee6c8a42b5a0c1250ee4ea8ff42d5db6f1a126c561b6c3877f381"
  end

  # brew-bottle-farm: external rustup 1.99.1 (build-deps.conf). Requires $CARGO_HOME on PATH.
  # depends_on "rust" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain cargo is visible (superenv would scrub PATH)

  deny_network_access!

  def fetch
    system "cargo", "fetch", *std_cargo_fetch_args
  end

  def install
    system "cargo", "install", *std_cargo_args
    bash_completion.install "contrib/completions/zoxide.bash" => "zoxide"
    zsh_completion.install "contrib/completions/_zoxide"
    fish_completion.install "contrib/completions/zoxide.fish"
    share.install "man"
  end

  test do
    assert_empty shell_output("#{bin}/zoxide add /").strip
    assert_equal "/", shell_output("#{bin}/zoxide query").strip
  end
end
