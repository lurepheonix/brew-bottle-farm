class Libidn2 < Formula
  desc "International domain name library (IDNA2008, Punycode and TR46)"
  homepage "https://www.gnu.org/software/libidn/#libidn2"
  url "https://ftpmirror.gnu.org/libidn/libidn2-2.3.8.tar.gz"
  mirror "https://ftp.gnu.org/gnu/libidn/libidn2-2.3.8.tar.gz"
  mirror "http://ftp.gnu.org/gnu/libidn/libidn2-2.3.8.tar.gz"
  sha256 "f557911bf6171621e1f72ff35f5b1825bb35b52ed45325dcdee931e5d3c0787a"
  license all_of: [
    { any_of: ["GPL-2.0-or-later", "LGPL-3.0-or-later"] }, # lib
    { all_of: ["Unicode-TOU", "Unicode-DFS-2016"] }, # matching COPYING.unicode
    "GPL-3.0-or-later", # bin
    "LGPL-2.1-or-later", # parts of gnulib
    "FSFAP-no-warranty-disclaimer", # man3
  ]
  compatibility_version 1

  livecheck do
    url :stable
    regex(/href=.*?libidn2[._-]v?(\d+(?:\.\d+)+)\.t/i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/libidn2-2.3.8"
    sha256 sequoia: "81b2fc1edb2330acc3d17e7b55575f178342cd9388d66782d8a938424a4c105a"
  end

  head do
    url "https://gitlab.com/libidn/libidn2.git", branch: "master"

    depends_on "lurepheonix/intel/autoconf" => :build
    depends_on "lurepheonix/intel/automake" => :build
    depends_on "gengetopt" => :build
    depends_on "lurepheonix/intel/gettext" => :build
    depends_on "help2man" => :build
    depends_on "lurepheonix/intel/libtool" => :build

    uses_from_macos "gperf" => :build

    on_macos do
      depends_on "coreutils" => :build
    end

    on_system :linux, macos: :ventura_or_newer do
      depends_on "texinfo" => :build
    end
  end

  depends_on "lurepheonix/intel/pkgconf" => :build
  depends_on "lurepheonix/intel/libunistring"

  on_macos do
    depends_on "lurepheonix/intel/gettext"
  end

  def install
    args = ["--disable-silent-rules", "--with-packager=Homebrew"]
    args << "--with-libintl-prefix=#{formula_opt_prefix("gettext")}" if OS.mac?

    if build.head?
      ENV.prepend_path "PATH", formula_opt_libexec("coreutils")/"gnubin" if OS.mac?
      system "./bootstrap", "--skip-po"
    end
    system "./configure", *args, *std_configure_args
    system "make", "install"
  end

  test do
    ENV.delete("LC_CTYPE")
    ENV["CHARSET"] = "UTF-8"
    output = shell_output("#{bin}/idn2 räksmörgås.se")
    assert_equal "xn--rksmrgs-5wao1o.se", output.chomp
    output = shell_output("#{bin}/idn2 blåbærgrød.no")
    assert_equal "xn--blbrgrd-fxak7p.no", output.chomp
  end
end
