class GdkPixbuf < Formula
  desc "Toolkit for image loading and pixel buffer manipulation"
  homepage "https://gtk.org"
  url "https://download.gnome.org/sources/gdk-pixbuf/2.44/gdk-pixbuf-2.44.8.tar.xz"
  sha256 "919f529512961a12e81cd4b4b466a48c3933469e7f9a310c6513cd4fb252ba3c"
  license "LGPL-2.1-or-later"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/gdk-pixbuf-2.44.8"
    sha256 cellar: :any, sequoia: "5d002fcc5501c71b9aeb1d38d341dd13a8af0ae3cabe77ba78da768232fa9d44"
  end

  depends_on "lurepheonix/intel/docutils" => :build # for rst2man
  depends_on "lurepheonix/intel/gettext" => :build
  # brew-bottle-farm: qualify intra-queue deps to the farm-bottled copies
  # (single-sourced per install; see patches/README.md).
  # depends_on "gobject-introspection" => :build  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/gobject-introspection" => :build
  # brew-bottle-farm: qualify intra-queue dep to the farm-bottled copy
  # (single-sourced per install; see patches/README.md).
  # depends_on "meson" => :build  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/meson" => :build
  env :std  # passthrough env so farm bottled tools resolve their toolchain interpreter (superenv would scrub uv from PATH)
  depends_on "lurepheonix/intel/ninja" => :build
  depends_on "lurepheonix/intel/pkgconf" => [:build, :test]
  # brew-bottle-farm: meson build scripts shell out to bare python3
  # (asdf shim refuses without a slot version); use the farm shim-keg.
  depends_on "lurepheonix/intel/python@3.15" => :build
  depends_on "lurepheonix/intel/glib"
  depends_on "lurepheonix/intel/jpeg-turbo"
  depends_on "lurepheonix/intel/libpng"
  depends_on "lurepheonix/intel/libtiff"

  on_macos do
    depends_on "lurepheonix/intel/gettext"
  end

  on_linux do
    depends_on "shared-mime-info"
  end

  deny_network_access!

  def install
    # Use HOMEBREW_PREFIX to find modules installed by dependents without
    # needing environment variables or inreplaces. In order to support this,
    # we need install into a staging directory.
    ENV["DESTDIR"] = buildpath/"stage"

    system "meson", "setup", "build", "-Drelocatable=false",
                                      "-Dnative_windows_loaders=false",
                                      "-Dtests=false",
                                      "-Dinstalled_tests=false",
                                      "-Dman=true",
                                      "-Dgtk_doc=false",
                                      "-Dpng=enabled",
                                      "-Dtiff=enabled",
                                      "-Djpeg=enabled",
                                      "-Dothers=enabled",
                                      "-Dintrospection=enabled",
                                      "-Dglycin=disabled",
                                      *std_meson_args(prefix: HOMEBREW_PREFIX)
    system "meson", "compile", "-C", "build", "--verbose"
    system "meson", "install", "-C", "build"
    prefix.install Pathname(File.join("stage", HOMEBREW_PREFIX)).children
  end

  post_install_steps do
    update_gdk_pixbuf_loaders_cache
  end

  test do
    (testpath/"test.c").write <<~C
      #include <gdk-pixbuf/gdk-pixbuf.h>

      int main(int argc, char *argv[]) {
        GType type = gdk_pixbuf_get_type();
        return 0;
      }
    C

    gdk_pixbuf_pc = lib.glob("pkgconfig/gdk-pixbuf-*.pc").first.basename(".pc")
    flags = shell_output("pkgconf --cflags --libs #{gdk_pixbuf_pc}").chomp.split
    system ENV.cc, "test.c", "-o", "test", *flags
    system "./test"

    # Check that HOMEBREW_PREFIX paths are used
    gdk_pixbuf_cache_file = shell_output("pkgconf --variable=gdk_pixbuf_cache_file #{gdk_pixbuf_pc}").chomp
    loaders = shell_output(bin/"gdk-pixbuf-query-loaders")
    assert_match "#{HOMEBREW_PREFIX}/lib/", gdk_pixbuf_cache_file
    assert_match "LoaderDir = #{HOMEBREW_PREFIX}/lib/gdk-pixbuf-", loaders
    refute_match prefix.realpath.to_s, loaders
  end
end
