class Folly < Formula
  desc "Collection of reusable C++ library artifacts developed at Facebook"
  homepage "https://github.com/facebook/folly"
  url "https://github.com/facebook/folly/archive/refs/tags/v2026.10.19.00.tar.gz"
  sha256 "b9e52ab77d48b9cf2ba7a64771f14d64873fb800ad0e6ef04022cd2a1ee6b8c6"
  license "Apache-2.0"
  compatibility_version 1
  head "https://github.com/facebook/folly.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/folly-2026.10.19.00"
    sha256 cellar: :any, sequoia: "062bd504531084ca866b3ad0bcd15367e0575923f9ccb9b0f89c1a4bebe79b24"
  end

  depends_on "lurepheonix/intel/cmake" => :build
  depends_on "lurepheonix/intel/fast_float" => :build
  depends_on "lurepheonix/intel/pkgconf" => :build
  depends_on "lurepheonix/intel/boost"
  depends_on "lurepheonix/intel/double-conversion"
  depends_on "lurepheonix/intel/fmt"
  depends_on "lurepheonix/intel/gflags"
  depends_on "lurepheonix/intel/glog"
  depends_on "lurepheonix/intel/libevent"
  depends_on "lurepheonix/intel/libsodium"
  depends_on "lurepheonix/intel/lz4"
  depends_on "lurepheonix/intel/openssl@4"
  depends_on "lurepheonix/intel/snappy"
  depends_on "lurepheonix/intel/xz"
  depends_on "lurepheonix/intel/zstd"

  uses_from_macos "bzip2"

  on_linux do
    depends_on "zlib-ng-compat"
  end

  def install
    # brew-bottle-farm: AppleClang cannot lower _Float16 below the x86-64
    # baseline; folly's scalar fallback passes -mno-sse2 (21 header errors
    # via <cmath>). Keep baseline SSE2 (still no AVX) — verified 0 errors.
    inreplace "folly/crypto/detail/CMakeLists.txt", "-mno-sse2", ""

    args = %w[
      -DFOLLY_USE_JEMALLOC=OFF
    ]

    system "cmake", "-S", ".", "-B", "build/shared",
                    "-DBUILD_SHARED_LIBS=ON",
                    "-DCMAKE_INSTALL_RPATH=#{rpath}",
                    *args, *std_cmake_args
    system "cmake", "--build", "build/shared"
    system "cmake", "--install", "build/shared"

    system "cmake", "-S", ".", "-B", "build/static",
                    "-DBUILD_SHARED_LIBS=OFF",
                    *args, *std_cmake_args
    system "cmake", "--build", "build/static"
    lib.install "build/static/libfolly.a", "build/static/folly/libfollybenchmark.a"
  end

  test do
    (testpath/"test.cc").write <<~CPP
      #include <folly/FBVector.h>
      int main() {
        folly::fbvector<int> numbers({0, 1, 2, 3});
        numbers.reserve(10);
        for (int i = 4; i < 10; i++) {
          numbers.push_back(i * 2);
        }
        assert(numbers[6] == 12);
        return 0;
      }
    CPP
    system ENV.cxx, "-std=c++20", "test.cc", "-I#{include}", "-L#{lib}", "-lfolly", "-o", "test"
    system "./test"
  end
end
