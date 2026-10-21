class Stgit < Formula
  desc "Manage Git commits as a stack of patches"
  homepage "https://stacked-git.github.io"
  url "https://github.com/stacked-git/stgit/releases/download/v2.7.0/stgit-2.7.0.tar.gz"
  sha256 "180a60734935e66bab10d524a367e602bfb3b73c8ab720c4bcdd4b2dcb64004d"
  license "GPL-2.0-only"
  head "https://github.com/stacked-git/stgit.git", branch: "master"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/stgit-2.7.0"
    sha256 cellar: :any_skip_relocation, sequoia: "21935429de8fef68ac70f18cd69a09a38659200bc6323f259a838053a38cec8e"
  end

  depends_on "lurepheonix/intel/asciidoc" => :build
  depends_on "lurepheonix/intel/pkgconf" => :build
  # brew-bottle-farm: external rustup 1.99.1 (build-deps.conf). Requires $CARGO_HOME on PATH.
  # depends_on "rust" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain cargo is visible (superenv would scrub PATH)
  depends_on "lurepheonix/intel/xmlto" => :build

  uses_from_macos "curl"
  uses_from_macos "git" # needs git >= 2.2.0. Consider using system git on Linux once RHEL 7 ELS ends

  def install
    ENV["XML_CATALOG_FILES"] = etc/"xml/catalog"
    system "make", "prefix=#{prefix}", "install-bin", "install-man"
    system "make", "prefix=#{prefix}", "-C", "contrib/vim", "install"
    generate_completions_from_executable(bin/"stg", "completion")
  end

  test do
    system "git", "init"
    system "git", "config", "user.name", "BrewTestBot"
    system "git", "config", "user.email", "brew@test.bot"
    (testpath/"test").write "test"
    system "git", "add", "test"
    system "git", "commit", "--message", "Initial commit", "test"
    system bin/"stg", "--version"
    system bin/"stg", "init"
    system bin/"stg", "new", "-m", "patch0"
    (testpath/"test").append_lines "a change"
    system bin/"stg", "refresh"
    system bin/"stg", "log"
    system "man", man/"man1/stg.1"
  end
end
