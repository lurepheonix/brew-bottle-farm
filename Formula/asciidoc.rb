class Asciidoc < Formula
  include Language::Python::Virtualenv

  desc "Formatter/translator for text files to numerous formats"
  homepage "https://asciidoc-py.github.io/"
  url "https://files.pythonhosted.org/packages/1d/e7/315a82f2d256e9270977aa3c15e8fe281fd7c40b8e2a0b97e0cb61ca8fa0/asciidoc-10.2.1.tar.gz"
  sha256 "d9f13c285981b3c7eb660d02ca0a2779981e88d48105de81bb40445e60dddb83"
  license "GPL-2.0-or-later"
  revision 1
  head "https://github.com/asciidoc-py/asciidoc-py.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/asciidoc-10.2.1"
    sha256 cellar: :any_skip_relocation, sequoia: "42f6b0582116fc716daa93b145e2de7aaa1a0f1d08322029cf5bbdc2b5fb1b05"
  end

  depends_on "lurepheonix/intel/docbook"
  # brew-bottle-farm: core python unpourable on Tier-3 guests; use the farm
  # shim-keg (pinned uv/asdf interpreter via farm-toolchain shims).
  # depends_on "python@3.15"  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/python@3.15"
  env :std  # passthrough env so the toolchain python/pip are visible (superenv would scrub PATH)
  depends_on "lurepheonix/intel/source-highlight"

  uses_from_macos "libxml2"

  def install
    virtualenv_install_with_resources
  end

  def caveats
    <<~EOS
      If you intend to process AsciiDoc files through an XML stage
      (such as a2x for manpage generation) you need to add something
      like:

        export XML_CATALOG_FILES=#{etc}/xml/catalog

      to your shell rc file so that xmllint can find AsciiDoc's
      catalog files.

      See `man 1 xmllint' for more.
    EOS
  end

  test do
    (testpath/"test.txt").write("== Hello World!")
    system bin/"asciidoc", "-b", "html5", "-o", testpath/"test.html", testpath/"test.txt"
    assert_match %r{<h2 id="_hello_world">Hello World!</h2>}, File.read(testpath/"test.html")
  end
end
