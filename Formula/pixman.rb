class Pixman < Formula
  desc "Low-level library for pixel manipulation"
  homepage "https://cairographics.org/"
  url "https://cairographics.org/releases/pixman-0.46.4.tar.gz"
  sha256 "d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c"
  license "MIT"
  compatibility_version 1

  livecheck do
    url "https://cairographics.org/releases/?C=M&O=D"
    regex(/href=.*?pixman[._-]v?(\d+\.\d*[02468](?:\.\d+)*)\.t/i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/pixman-0.46.4"
    sha256 cellar: :any, sequoia: "e28a64aee7bf91f290784d777e9f8b5367f0daf39dd1586bcc9854b0b1a9d505"
  end

  # brew-bottle-farm: qualify intra-queue dep to the farm-bottled copy
  # (single-sourced per install; see patches/README.md).
  # depends_on "meson" => :build  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/meson" => :build
  env :std  # passthrough env so farm bottled tools resolve their toolchain interpreter (superenv would scrub uv from PATH)
  depends_on "lurepheonix/intel/ninja" => :build
  depends_on "lurepheonix/intel/pkgconf" => :test

  def install
    system "meson", "setup", "build", "--default-library=both", *std_meson_args
    system "meson", "compile", "-C", "build", "--verbose"
    system "meson", "install", "-C", "build"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <pixman.h>

      int main(int argc, char *argv[])
      {
        pixman_color_t white = { 0xffff, 0xffff, 0xffff, 0xffff };
        pixman_image_t *image = pixman_image_create_solid_fill(&white);
        pixman_image_unref(image);
        return 0;
      }
    C

    pkgconf_flags = shell_output("pkgconf --cflags --libs pixman-1").chomp.split
    system ENV.cc, "test.c", "-o", "test", *pkgconf_flags
    system "./test"
  end
end
