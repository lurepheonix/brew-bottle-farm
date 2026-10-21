class Libvmaf < Formula
  desc "Perceptual video quality assessment based on multi-method fusion"
  homepage "https://github.com/Netflix/vmaf"
  url "https://github.com/Netflix/vmaf/archive/refs/tags/v3.2.1.tar.gz"
  sha256 "5df7386911bc15fd1ca783132528748d219768ae4fc5f8e0b61184f041648092"
  license "BSD-2-Clause-Patent"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/libvmaf-3.2.1"
    sha256 cellar: :any, sequoia: "696e2a7c05a8bd833c8207bb89fcee902a710bbaee698c963875ccccde5ab61b"
  end

  # brew-bottle-farm: qualify intra-queue dep to the farm-bottled copy
  # (single-sourced per install; see patches/README.md).
  # depends_on "meson" => :build  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/meson" => :build
  env :std  # passthrough env so farm bottled tools resolve their toolchain interpreter (superenv would scrub uv from PATH)
  depends_on "ninja" => :build
  uses_from_macos "vim" => :build # needed for xxd

  on_intel do
    depends_on "nasm" => :build
  end

  def install
    system "meson", "setup", "build", "libvmaf", *std_meson_args
    system "meson", "compile", "-C", "build", "--verbose"
    system "meson", "install", "-C", "build"
    pkgshare.install "model"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <libvmaf/libvmaf.h>
      int main() {
        return 0;
      }
    C

    flags = [
      "-I#{HOMEBREW_PREFIX}/include/libvmaf",
      "-L#{lib}",
    ]

    system ENV.cc, "test.c", "-o", "test", *flags
    system "./test"
  end
end
