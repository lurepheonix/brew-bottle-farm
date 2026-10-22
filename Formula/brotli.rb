class Brotli < Formula
  desc "Generic-purpose lossless compression algorithm by Google"
  homepage "https://github.com/google/brotli"
  url "https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz"
  mirror "http://fresh-center.net/linux/misc/brotli-1.2.0.tar.gz"
  mirror "http://fresh-center.net/linux/misc/legacy/brotli-1.2.0.tar.gz"
  sha256 "816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec"
  license "MIT"
  revision 1
  compatibility_version 1
  head "https://github.com/google/brotli.git", branch: "master"

  livecheck do
    url :stable
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/brotli-1.2.0"
    sha256 cellar: :any, sequoia: "f101a7cb7483d6944f912d29a9bc54b790c9d295b7a006a89dedfff4a316871d"
  end

  depends_on "lurepheonix/intel/cmake" => :build

  # Backport earlier invalid stream detection for CVE-2026-111497
  patch do
    url "https://github.com/google/brotli/commit/0ed4268a4401abcb4472096340477cf4af7d1a2b.patch?full_index=1"
    sha256 "d6f962509000223def7062958229bd08457e5e032e7ed0d1d94fb790b054b1fc"
    type :backport
    resolves "CVE-2026-111497"
  end

  deny_network_access!

  def install
    system "cmake", "-S", ".", "-B", "build", "-DCMAKE_INSTALL_RPATH=#{rpath}", *std_cmake_args
    system "cmake", "--build", "build", "--verbose"
    system "ctest", "--test-dir", "build", "--verbose"
    system "cmake", "--install", "build"
    system "cmake", "-S", ".", "-B", "build-static", "-DBUILD_SHARED_LIBS=OFF", *std_cmake_args
    system "cmake", "--build", "build-static"
    lib.install buildpath.glob("build-static/*.a")
  end

  test do
    (testpath/"file.txt").write("Hello, World!")
    system bin/"brotli", "file.txt", "file.txt.br"
    system bin/"brotli", "file.txt.br", "--output=out.txt", "--decompress"
    assert_equal (testpath/"file.txt").read, (testpath/"out.txt").read
  end
end
