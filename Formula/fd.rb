class Fd < Formula
  desc "Simple, fast and user-friendly alternative to find"
  homepage "https://github.com/sharkdp/fd"
  url "https://github.com/sharkdp/fd/archive/refs/tags/v10.5.2.tar.gz"
  sha256 "8991b6504cac33c00528050622dfe3f2a0db1be1a6faf99f69b46d1a8f737dc5"
  license any_of: ["Apache-2.0", "MIT"]
  head "https://github.com/sharkdp/fd.git", branch: "master"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/fd-10.5.2"
    sha256 cellar: :any_skip_relocation, sequoia: "bb72e821b349bae6dc024c18686d4825ddebd35f3edaa271870c943255db6af1"
  end

  # brew-bottle-farm: external rustup 1.99.1 (build-deps.conf). Requires $CARGO_HOME on PATH.
  # depends_on "rust" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain cargo is visible (superenv would scrub PATH)

  conflicts_with "fdclone", because: "both install `fd` binaries"

  deny_network_access!

  def fetch
    system "cargo", "fetch", *std_cargo_fetch_args
  end

  def install
    ENV["JEMALLOC_SYS_WITH_LG_PAGE"] = "16" if Hardware::CPU.arm? && OS.linux?
    system "cargo", "install", *std_cargo_args

    generate_completions_from_executable(bin/"fd", "--gen-completions", shells: [:bash, :fish, :pwsh])
    zsh_completion.install "contrib/completion/_fd"
    man1.install "doc/fd.1"
  end

  test do
    touch "foo_file"
    touch "test_file"
    assert_equal "test_file", shell_output("#{bin}/fd test").chomp
  end
end
