class Pango < Formula
  desc "Framework for layout and rendering of i18n text"
  homepage "https://www.gtk.org/docs/architecture/pango"
  url "https://download.gnome.org/sources/pango/1.58/pango-1.58.2.tar.xz"
  sha256 "342385b6ca3b7c73455d7c80a13b7dbe4489e00bc3bd4c5bd6ed4dce421e374a"
  license "LGPL-2.0-or-later"
  compatibility_version 1
  head "https://gitlab.gnome.org/GNOME/pango.git", branch: "main"

  # Pango doesn't follow GNOME's "even-numbered minor is stable" version
  # scheme but they do appear to use 90+ minor/patch versions, which may
  # indicate unstable versions (e.g., 1.90, etc.).
  livecheck do
    url "https://download.gnome.org/sources/pango/cache.json"
    regex(/pango[._-]v?(\d+(?:(?!\.9\d)\.\d+)+)\.t/i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/pango-1.58.2"
    sha256 cellar: :any, sequoia: "cd6d6fff934d8d7d5adacf70328b477480c4712a9ab9343ba05ff77bdfd0c921"
  end

  # brew-bottle-farm: qualify intra-queue deps to the farm-bottled copies
  # (single-sourced per install; see patches/README.md).
  # depends_on "gobject-introspection" => :build  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/gobject-introspection" => :build
  # depends_on "meson" => :build  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/meson" => :build
  env :std  # passthrough env so farm bottled tools resolve their toolchain interpreter (superenv would scrub uv from PATH)
  depends_on "lurepheonix/intel/ninja" => :build
  depends_on "lurepheonix/intel/pkgconf" => [:build, :test]
  # brew-bottle-farm: core python unpourable on Tier-3 guests; use the farm
  # shim-keg (pinned uv/asdf interpreter via farm-toolchain shims).
  # depends_on "python@3.15" => [:build, :test]  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/python@3.15" => [:build, :test]
  depends_on "lurepheonix/intel/cairo"
  depends_on "lurepheonix/intel/fontconfig"
  depends_on "lurepheonix/intel/freetype"
  depends_on "lurepheonix/intel/fribidi"
  depends_on "lurepheonix/intel/glib"
  depends_on "lurepheonix/intel/harfbuzz"
  depends_on "lurepheonix/intel/libthai"

  deny_network_access!

  def install
    args = %w[
      -Ddefault_library=both
      -Dintrospection=enabled
      -Dfontconfig=enabled
      -Dcairo=enabled
      -Dfreetype=enabled
      -Dlibthai=enabled
    ]

    system "meson", "setup", "build", *args, *std_meson_args
    system "meson", "compile", "-j2", "-C", "build", "--verbose"  # brew-bottle-farm: cap jobs (8c16GB guest fork-EAGAIN at full parallelism; cf. glib/watchman)
    system "meson", "install", "-C", "build"
  end

  test do
    system bin/"pango-view", "--version"
    (testpath/"test.c").write <<~C
      #include <pango/pangocairo.h>

      int main(int argc, char *argv[]) {
        PangoFontMap *fontmap;
        int n_families;
        PangoFontFamily **families;
        fontmap = pango_cairo_font_map_get_default();
        pango_font_map_list_families (fontmap, &families, &n_families);
        g_free(families);
        return 0;
      }
    C

    flags = shell_output("pkgconf --cflags --libs pangocairo").chomp.split
    system ENV.cc, "test.c", "-o", "test", *flags
    system "./test"
  end
end
