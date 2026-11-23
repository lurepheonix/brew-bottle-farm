class Libthai < Formula
  desc "Thai language support library"
  homepage "https://linux.thai.net/projects/libthai"
  url "https://linux.thai.net/pub/thailinux/software/libthai/libthai-0.1.30.tar.xz"
  sha256 "ddba8b53dfe584c3253766030218a88825488a51a7deef041d096e715af64bdd"
  license "LGPL-2.1-or-later"
  compatibility_version 1

  livecheck do
    url "https://linux.thai.net/pub/thailinux/software/libthai/"
    regex(/href=["']?libthai[._-]v?(\d+(?:\.\d+)+)\.t/i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/libthai-0.1.30"
    sha256 sequoia: "d1252cc1cccb301f55d14c4337401e82dd6fe964af4e283beccebac179c4cf9a"
  end

  depends_on "lurepheonix/intel/pkgconf" => [:build, :test]
  depends_on "lurepheonix/intel/libdatrie"

  deny_network_access!

  def install
    system "./configure", "--disable-silent-rules",
                          "--disable-doxygen-doc",
                          *std_configure_args
    system "make"
    system "make", "install"
  end

  test do
    # Basic linkage test to ensure the library is installed and usable
    (testpath/"test.c").write <<~C
      #include <thai/thctype.h>
      #include <stdio.h>

      int main() {
          // 0xa1 is KO KAI in TIS-620 encoding
          if (th_isthai(0xa1)) {
              return 0;
          }
          return 1;
      }
    C
    flags = shell_output("pkgconf --cflags --libs libthai").chomp.split
    system ENV.cc, "test.c", *flags, "-o", "test"
    system "./test"
  end
end
