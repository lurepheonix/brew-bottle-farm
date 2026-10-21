class Xmlto < Formula
  desc "Convert XML to another format (based on XSL or other tools)"
  homepage "https://codeberg.org/xmlto/xmlto"
  url "https://codeberg.org/xmlto/xmlto/archive/0.0.29.tar.gz"
  sha256 "ccf0657f71f874d01a28729e7c08ea468ae705e087a4e12d1dcacb6b54a5d25d"
  license "GPL-2.0-or-later"

  livecheck do
    url "https://codeberg.org/xmlto/xmlto.git"
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/xmlto-0.0.29"
    sha256 cellar: :any_skip_relocation, sequoia: "30d1d4cc2cd9541b47545a622c2ffb2c5ab79c383896111a54c1a9e3986752bf"
  end

  depends_on "lurepheonix/intel/autoconf" => :build
  depends_on "lurepheonix/intel/automake" => :build

  depends_on "lurepheonix/intel/docbook"
  depends_on "lurepheonix/intel/docbook-xsl"

  uses_from_macos "libxslt"

  on_macos do
    # Doesn't strictly depend on GNU getopt, but macOS system getopt(1)
    # does not support longopts in the optstring, so use GNU getopt.
    depends_on "lurepheonix/intel/gnu-getopt"
  end

  def install
    # GNU getopt is keg-only, so point configure to it
    ENV["GETOPT"] = formula_opt_bin("gnu-getopt")/"getopt" if OS.mac?
    # Find our docbook catalog
    ENV["XML_CATALOG_FILES"] = "#{etc}/xml/catalog"

    ENV.deparallelize
    system "autoreconf", "--force", "--install", "--verbose"
    system "./configure", "--disable-silent-rules", *std_configure_args
    system "make", "install"
  end

  test do
    (testpath/"test").write <<~EOS
      <?xmlif if foo='bar'?>
      Passing test.
      <?xmlif fi?>
    EOS
    assert_equal "Passing test.", pipe_output("#{bin}/xmlif foo=bar", (testpath/"test").read).strip
  end
end
