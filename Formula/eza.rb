class Eza < Formula
  desc "Modern, maintained replacement for ls"
  homepage "https://eza.rocks"
  url "https://github.com/eza-community/eza/archive/refs/tags/v0.23.5.tar.gz"
  sha256 "bbf179f2611c904014431740b559e8055276c12fcf978a7e31c271663548337f"
  license "EUPL-1.2"
  head "https://github.com/eza-community/eza.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/eza-0.23.5"
    sha256 cellar: :any, sequoia: "62b22d789c35bd64a177af28464eb36cd33743f9353a12c8e918ea6bb8bca401"
  end

  depends_on "lurepheonix/intel/pandoc" => :build
  depends_on "lurepheonix/intel/pkgconf" => :build
  # brew-bottle-farm: external rustup 1.99.1 (build-deps.conf). Requires $CARGO_HOME on PATH.
  # depends_on "rust" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain cargo is visible (superenv would scrub PATH)
  depends_on "lurepheonix/intel/libgit2"

  deny_network_access!

  def fetch
    system "cargo", "fetch", *std_cargo_fetch_args
  end

  def install
    ENV["LIBGIT2_NO_VENDOR"] = "1"

    system "cargo", "install", *std_cargo_args

    bash_completion.install "completions/bash/eza"
    fish_completion.install "completions/fish/eza.fish"
    zsh_completion.install  "completions/zsh/_eza"

    args = %w[
      --standalone
      --from=markdown
      --to=man
    ]
    system "pandoc", *args, "man/eza.1.md", "-o", "eza.1"
    system "pandoc", *args, "man/eza_colors.5.md", "-o", "eza_colors.5"
    system "pandoc", *args, "man/eza_colors-explanation.5.md", "-o", "eza_colors-explanation.5"

    man1.install buildpath.glob("*.1")
    man5.install buildpath.glob("*.5")
  end

  test do
    testfile = "test.txt"
    touch testfile
    # `eza` is broken when not passed a file or directory name.
    # https://github.com/eza-community/eza/issues/1568
    assert_match testfile, shell_output("#{bin}/eza #{testpath}")

    # Test git integration
    flags = "--long --git --no-permissions --no-filesize --no-user --no-time --color=never"
    eza_output = proc { shell_output("#{bin}/eza #{flags} #{testpath}").lines.grep(/#{testfile}/).first.split.first }
    system "git", "init"
    assert_equal "-N", eza_output.call
    system "git", "add", testfile
    assert_equal "N-", eza_output.call
    system "git", "commit", "-m", "Initial commit"
    assert_equal "--", eza_output.call

    require "utils/linkage"
    library = formula_opt_lib("libgit2")/shared_library("libgit2")
    assert Utils.binary_linked_to_library?(bin/"eza", library),
           "No linkage with #{library.basename}! Cargo is likely using a vendored version."
  end
end
