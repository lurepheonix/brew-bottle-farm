class Automake < Formula
  desc "Tool for generating GNU Standards-compliant Makefiles"
  homepage "https://www.gnu.org/software/automake/"
  url "https://ftpmirror.gnu.org/automake/automake-1.19.tar.xz"
  mirror "https://ftp.gnu.org/gnu/automake/automake-1.19.tar.xz"
  sha256 "e3e2c2e3abf37898138db5b6c1d1dc35c9160c5978be7947d2c741705251d445"
  license "GPL-2.0-or-later"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/automake-1.19"
    sha256 cellar: :any_skip_relocation, sequoia: "f7f02393d75b1a0a17fca7675d9de36a440f266b0ca378d5b8affa8a399274d5"
  end

  depends_on "autoconf"

  deny_network_access!

  def install
    ENV["PERL"] = "/usr/bin/perl" if OS.mac?

    # We specify `HOMEBREW_PREFIX` so that aclocal is compiled with the
    # correct system value for acdir (`HOMEBREW_PREFIX/share/aclocal`)
    # We also patch `configure` so that the normal installation prefix
    # is used when we call `make install`
    inreplace "configure", "${datadir}", "${datarootdir}"
    system "./configure", "--sysconfdir=#{etc}",
                          "--localstatedir=#{var}",
                          "--datarootdir=#{share}",
                          "--datadir=#{HOMEBREW_PREFIX}/share",
                          *std_configure_args
    system "make", "install"

    # Use dirlist to add common search dirs for aclocal
    (share/"aclocal/dirlist").write <<~EOS
      /usr/share/aclocal
    EOS
  end

  test do
    # Check that the compiled system value for acdir does not use automake's versioned path
    assert_equal "#{HOMEBREW_PREFIX}/share/aclocal", shell_output("#{bin}/aclocal --print-ac-dir").chomp

    (testpath/"test.c").write <<~C
      int main() { return 0; }
    C
    (testpath/"configure.ac").write <<~M4
      AC_INIT(test, 1.0)
      AM_INIT_AUTOMAKE
      AC_PROG_CC
      AC_CONFIG_FILES(Makefile)
      AC_OUTPUT
    M4
    (testpath/"Makefile.am").write <<~MAKE
      bin_PROGRAMS = test
      test_SOURCES = test.c
    MAKE
    system bin/"aclocal"
    system bin/"automake", "--add-missing", "--foreign"
    system "autoconf"
    system "./configure"
    system "make"
    system "./test"
  end
end
