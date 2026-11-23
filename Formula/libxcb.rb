class Libxcb < Formula
  desc "X.Org: Interface to the X Window System protocol"
  homepage "https://www.x.org/"
  url "https://xorg.freedesktop.org/archive/individual/lib/libxcb-1.17.0.tar.xz"
  sha256 "599ebf9996710fea71622e6e184f3a8ad5b43d0e5fa8c4e407123c88a59a6d55"
  license "MIT"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/libxcb-1.17.0"
    sha256 cellar: :any, sequoia: "dc418e8c173f907bd9430220e4908bde2880640351ebdf9aa000639e5f097dc2"
  end

  depends_on "lurepheonix/intel/pkgconf" => :build
  # brew-bottle-farm: core python unpourable on Tier-3 guests (bare names
  # resolve to core and would build from source); use the farm shim-keg.
  # depends_on "python@3.15" => :build # match version in `xcb-proto`  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/python@3.15" => :build # match version in `xcb-proto`
  env :std  # passthrough env so the toolchain python is visible (superenv would scrub PATH)
  depends_on "lurepheonix/intel/xcb-proto" => :build
  depends_on "lurepheonix/intel/libxau"
  depends_on "lurepheonix/intel/libxdmcp"

  def install
    args = %W[
      --sysconfdir=#{etc}
      --localstatedir=#{var}
      --enable-dri3
      --enable-ge
      --enable-xevie
      --enable-xprint
      --enable-selinux
      --disable-silent-rules
      --enable-devel-docs=no
      --with-doxygen=no
      PYTHON=#{python3}
    ]

    system "./configure", *args, *std_configure_args
    # brew-bottle-farm: cap parallel jobs — the build shells out to the
    # farm python shim per TU, and concurrent `uv python find` probes fail
    # under load (cf. glib -j2; watchman --parallel 2).
    system "make", "-j2"
    system "make", "-j2", "install"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include "xcb/xcb.h"

      int main() {
        xcb_connection_t *connection;
        xcb_atom_t *atoms;
        xcb_intern_atom_cookie_t *cookies;
        int count, i;
        char **names;
        char buf[100];

        count = 200;

        connection = xcb_connect(NULL, NULL);
        atoms = (xcb_atom_t *) malloc(count * sizeof(atoms));
        names = (char **) malloc(count * sizeof(char *));

        for (i = 0; i < count; ++i) {
          sprintf(buf, "NAME%d", i);
          names[i] = strdup(buf);
          memset(buf, 0, sizeof(buf));
        }

        cookies = (xcb_intern_atom_cookie_t *) malloc(count * sizeof(xcb_intern_atom_cookie_t));

        for(i = 0; i < count; ++i) {
          cookies[i] = xcb_intern_atom(connection, 0, strlen(names[i]), names[i]);
        }

        for(i = 0; i < count; ++i) {
          xcb_intern_atom_reply_t *r;
          r = xcb_intern_atom_reply(connection, cookies[i], 0);
          if(r)
            atoms[i] = r->atom;
          free(r);
        }

        free(atoms);
        free(cookies);
        xcb_disconnect(connection);
        return 0;
      }
    C
    system ENV.cc, "test.c", "-o", "test", "-I#{include}", "-L#{lib}", "-lxcb"
    system "./test"
    assert_equal 0, $CHILD_STATUS.exitstatus
  end
end
