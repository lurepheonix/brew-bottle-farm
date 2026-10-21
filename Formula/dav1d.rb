class Dav1d < Formula
  desc "AV1 decoder targeted to be small and fast"
  homepage "https://code.videolan.org/videolan/dav1d"
  url "https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2"
  sha256 "2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011"
  license "BSD-2-Clause"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/dav1d-1.5.4"
    sha256 cellar: :any, sequoia: "0c1af692a5f8fad0e2ee6962b96dea0815033f2191001220e9a374978194f311"
  end

  # brew-bottle-farm: qualify intra-queue dep to the farm-bottled copy
  # (single-sourced per install; see patches/README.md).
  # depends_on "meson" => :build  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/meson" => :build
  env :std  # passthrough env so farm bottled tools resolve their toolchain interpreter (superenv would scrub uv from PATH)
  depends_on "ninja" => :build

  on_intel do
    depends_on "nasm" => :build
  end

  resource "homebrew-00000000.ivf", :test do
    url "https://code.videolan.org/videolan/dav1d-test-data/raw/1.1.0/8-bit/data/00000000.ivf"
    sha256 "52b4351f9bc8a876c8f3c9afc403d9e90f319c1882bfe44667d41c8c6f5486f3"
  end

  def install
    system "meson", "setup", "build", *std_meson_args
    system "meson", "compile", "-C", "build", "--verbose"
    system "meson", "install", "-C", "build"
  end

  test do
    testpath.install resource("homebrew-00000000.ivf")
    system bin/"dav1d", "-i", testpath/"00000000.ivf", "-o", testpath/"00000000.md5"

    assert_path_exists (testpath/"00000000.md5")
    assert_match "0b31f7ae90dfa22cefe0f2a1ad97c620", (testpath/"00000000.md5").read
  end
end
