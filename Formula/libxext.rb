class Libxext < Formula
  desc "X.Org: Library for common extensions to the X11 protocol"
  homepage "https://www.x.org/"
  url "https://xorg.freedesktop.org/archive/individual/lib/libXext-1.3.7.tar.gz"
  sha256 "6564608dc3b816b0cfddf0c7ddc62bc579055dd70b2f28113a618df2acb64189"
  license "MIT"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/libxext-1.3.7"
    sha256 cellar: :any, sequoia: "1643a3bcba79808273069ac05513c168105e6728d69c3b74f583757032eb907a"
  end

  depends_on "lurepheonix/intel/pkgconf" => :build
  depends_on "lurepheonix/intel/libx11"
  depends_on "lurepheonix/intel/xorgproto"

  deny_network_access!

  def install
    args = %W[
      --sysconfdir=#{etc}
      --localstatedir=#{var}
      --disable-silent-rules
      --enable-specs=no
    ]

    system "./configure", *args, *std_configure_args
    system "make"
    system "make", "install"
  end

  test do
    (testpath/"test.c").write <<~C
      #include "X11/extensions/shape.h"

      int main(int argc, char* argv[]) {
        XShapeEvent event;
        return 0;
      }
    C
    system ENV.cc, "test.c"
    assert_equal 0, $CHILD_STATUS.exitstatus
  end
end
