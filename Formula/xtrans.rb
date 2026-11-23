class Xtrans < Formula
  desc "X.Org: X Network Transport layer shared code"
  homepage "https://www.x.org/"
  url "https://xorg.freedesktop.org/archive/individual/lib/xtrans-1.6.0.tar.xz"
  sha256 "faafea166bf2451a173d9d593352940ec6404145c5d1da5c213423ce4d359e92"
  license "MIT"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/xtrans-1.6.0"
    sha256 cellar: :any_skip_relocation, sequoia: "a026561e188bf5d6a50230efc21dfce305a15d2bae568b3f86f187f5928f1a98"
  end

  depends_on "lurepheonix/intel/pkgconf" => :build
  depends_on "lurepheonix/intel/util-macros" => :build
  depends_on "lurepheonix/intel/xorgproto" => :test

  deny_network_access!

  def install
    args = %W[
      --sysconfdir=#{etc}
      --localstatedir=#{var}
      --disable-silent-rules
      --enable-docs=no
    ]

    system "./configure", *args, *std_configure_args
    system "make", "install"
  end

  test do
    (testpath/"test.c").write <<~C
      #include "X11/Xtrans/Xtrans.h"

      int main(int argc, char* argv[]) {
        Xtransaddr addr;
        return 0;
      }
    C
    system ENV.cc, "test.c"
    assert_equal 0, $CHILD_STATUS.exitstatus
  end
end
