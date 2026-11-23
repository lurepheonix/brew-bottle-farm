class Libx11 < Formula
  desc "X.Org: Core X11 protocol client library"
  homepage "https://www.x.org/"
  url "https://xorg.freedesktop.org/archive/individual/lib/libX11-1.8.14.tar.gz"
  sha256 "ebb8a58549ddde50aa2e742b3b256557f451053d173be8dbfc2e8ac078eee1d6"
  license "MIT"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/libx11-1.8.14"
    sha256 sequoia: "4a112db03bf6d301cebe425d735b59b6e2d82940941253204d36e30b7b507368"
  end

  depends_on "lurepheonix/intel/pkgconf" => :build
  depends_on "lurepheonix/intel/util-macros" => :build
  depends_on "lurepheonix/intel/xtrans" => :build
  depends_on "lurepheonix/intel/libxcb"
  depends_on "lurepheonix/intel/xorgproto"

  deny_network_access!

  def install
    ENV.delete "LC_ALL"
    ENV["LC_CTYPE"] = "C"
    args = %W[
      --sysconfdir=#{etc}
      --localstatedir=#{var}
      --disable-silent-rules
      --enable-unix-transport
      --enable-tcp-transport
      --enable-ipv6
      --enable-xthreads
      --enable-specs=no
    ]

    system "./configure", *args, *std_configure_args
    system "make"
    system "make", "install"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <X11/Xlib.h>
      #include <locale.h>
      #include <stdio.h>

      int main() {
        setlocale(LC_ALL, "");
        printf("XSupportsLocale=%d", XSupportsLocale());

        Display* disp = XOpenDisplay(NULL);
        if (disp == NULL)
        {
          fprintf(stderr, "Unable to connect to display\\n");
          return 0;
        }

        int screen_num = DefaultScreen(disp);
        unsigned long background = BlackPixel(disp, screen_num);
        unsigned long border = WhitePixel(disp, screen_num);
        int width = 60, height = 40;
        Window win = XCreateSimpleWindow(disp, DefaultRootWindow(disp), 0, 0, width, height, 2, border, background);
        XSelectInput(disp, win, ButtonPressMask|StructureNotifyMask);
        XMapWindow(disp, win); // display blank window

        XGCValues values;
        values.foreground = WhitePixel(disp, screen_num);
        values.line_width = 1;
        values.line_style = LineSolid;
        GC pen = XCreateGC(disp, win, GCForeground|GCLineWidth|GCLineStyle, &values);
        // draw two diagonal lines
        XDrawLine(disp, win, pen, 0, 0, width, height);
        XDrawLine(disp, win, pen, width, 0, 0, height);

        return 0;
      }
    C
    system ENV.cc, "test.c", "-L#{lib}", "-lX11", "-o", "test", "-I#{include}"
    assert_match "XSupportsLocale=1", shell_output("./test")
  end
end
