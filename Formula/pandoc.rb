class Pandoc < Formula
  desc "Swiss-army knife of markup format conversion"
  homepage "https://pandoc.org/"
  url "https://github.com/jgm/pandoc/archive/refs/tags/3.13.tar.gz"
  sha256 "fbf6044766b0c9be5ccbf18ffe657124449e8563a177d85662ecb6f031f9c308"
  license "GPL-2.0-or-later"
  compatibility_version 10
  head "https://github.com/jgm/pandoc.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/pandoc-3.13"
    sha256 cellar: :any_skip_relocation, sequoia: "d9b01bc3cc614aa247ea27ad6f85250d7a5f2f5cbc7fd134ed28aaf524543e99"
  end

  # brew-bottle-farm: external cabal-install 3.18.2.0 (build-deps.conf). Requires toolchain cabal on PATH.
  # depends_on "cabal-install" => :build  # disabled — see patches/README.md
  # brew-bottle-farm: external ghc 9.14.1 (build-deps.conf). Requires toolchain ghc on PATH.
  # depends_on "ghc" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain ghc/cabal are visible (superenv would scrub PATH)
  depends_on "lurepheonix/intel/gmp"

  uses_from_macos "unzip" => :build # for cabal install
  uses_from_macos "libffi"

  on_linux do
    depends_on "zlib-ng-compat"
  end

  allow_network_access! :build

  def install
    # Workaround to build aeson with GHC 9.14, https://github.com/haskell/aeson/issues/1155
    args = ["--allow-newer=base,containers,template-haskell", "--constraint=pandoc +http"]

    system "cabal", "v2-update"
    system "cabal", "v2-install", *args, *std_cabal_v2_args, "pandoc-cli"
    generate_completions_from_executable(bin/"pandoc", "--bash-completion",
                                         shells: [:bash], shell_parameter_format: :none)
    man1.install "pandoc-cli/man/pandoc.1"
  end

  test do
    input_markdown = <<~MARKDOWN
      # Homebrew

      A package manager for humans. Cats should take a look at Tigerbrew.
    MARKDOWN
    expected_html = <<~HTML
      <h1 id="homebrew">Homebrew</h1>
      <p>A package manager for humans. Cats should take a look at
      Tigerbrew.</p>
    HTML
    assert_equal expected_html, pipe_output("#{bin}/pandoc -f markdown -t html5", input_markdown, 0)
  end
end
