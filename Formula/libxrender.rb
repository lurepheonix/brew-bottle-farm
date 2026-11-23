class Libxrender < Formula
  desc "X.Org: Library for the Render Extension to the X11 protocol"
  homepage "https://www.x.org/"
  url "https://xorg.freedesktop.org/archive/individual/lib/libXrender-0.9.13.tar.gz"
  sha256 "bf264b683d1e49ff9a6bc03af13baa430a556d943731a2b1ac2439dae4fea205"
  license "MIT"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/libxrender-0.9.13"
    sha256 cellar: :any, sequoia: "03fccf9074877b401e9f7930a9c1e45d4e8ff348e793edbf099d22a93d0fbbe3"
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
    ]

    system "./configure", *args, *std_configure_args
    system "make"
    system "make", "install"
  end

  test do
    (testpath/"test.c").write <<~C
      #include "X11/Xlib.h"
      #include "X11/extensions/Xrender.h"

      int main(int argc, char* argv[]) {
        XRenderColor color;
        return 0;
      }
    C
    system ENV.cc, "test.c"
  end
end
