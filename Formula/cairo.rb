class Cairo < Formula
  desc "Vector graphics library with cross-device output support"
  homepage "https://cairographics.org/"
  url "https://cairographics.org/releases/cairo-1.18.6.tar.xz"
  sha256 "1c767308174337a74694da0f3ec069c271452163a1ef4540964c50c301f157d4"
  license any_of: ["LGPL-2.1-only", "MPL-1.1"]
  compatibility_version 1
  head "https://gitlab.freedesktop.org/cairo/cairo.git", branch: "master"

  livecheck do
    url "https://cairographics.org/releases/?C=M&O=D"
    regex(%r{href=(?:["']?|.*?/)cairo[._-]v?(\d+\.\d*[02468](?:\.\d+)*)\.t}i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/cairo-1.18.6"
    sha256 cellar: :any, sequoia: "b92e6010b078e9eafbc6268413ef13e47f5b294d005c8554dd0f142db6e0c9a6"
  end

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

  depends_on "lurepheonix/intel/fontconfig"
  depends_on "lurepheonix/intel/freetype"
  depends_on "lurepheonix/intel/glib"
  depends_on "lurepheonix/intel/libpng"
  depends_on "lurepheonix/intel/libx11"
  depends_on "lurepheonix/intel/libxcb"
  depends_on "lurepheonix/intel/libxext"
  depends_on "lurepheonix/intel/libxrender"
  depends_on "lurepheonix/intel/lzo"
  depends_on "lurepheonix/intel/pixman"

  on_macos do
    depends_on "lurepheonix/intel/gettext"
  end

  on_linux do
    depends_on "zlib-ng-compat"
  end

  def install
    args = %w[
      --default-library=both
      -Dfontconfig=enabled
      -Dfreetype=enabled
      -Dpng=enabled
      -Dglib=enabled
      -Dxcb=enabled
      -Dxlib=enabled
      -Dzlib=enabled
      -Dglib=enabled
    ]
    args << "-Dquartz=enabled" if OS.mac?

    system "meson", "setup", "build", *args, *std_meson_args
    system "meson", "compile", "-C", "build", "--verbose"
    system "meson", "install", "-C", "build"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <cairo.h>

      int main(int argc, char *argv[]) {

        cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 600, 400);
        cairo_t *context = cairo_create(surface);

        return 0;
      }
    C

    flags = shell_output("pkgconf --cflags --libs cairo").chomp.split
    system ENV.cc, "test.c", "-o", "test", *flags
    system "./test"
  end
end
