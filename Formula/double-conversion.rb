class DoubleConversion < Formula
  desc "Binary-decimal and decimal-binary routines for IEEE doubles"
  homepage "https://github.com/google/double-conversion"
  url "https://github.com/google/double-conversion/archive/refs/tags/v3.4.0.tar.gz"
  sha256 "42fd4d980ea86426e457b24bdfa835a6f5ad9517ddb01cdb42b99ab9c8dd5dc9"
  license "BSD-3-Clause"
  compatibility_version 1
  head "https://github.com/google/double-conversion.git", branch: "master"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/double-conversion-3.4.0"
    sha256 cellar: :any, sequoia: "5f1047af589b70545ba7f546986d7560e17d1a8ceb14b619c36bcc02f75b4b95"
  end

  depends_on "lurepheonix/intel/cmake" => :build

  deny_network_access!

  def install
    system "cmake", "-S", ".", "-B", "shared", "-DBUILD_SHARED_LIBS=ON", *std_cmake_args
    system "cmake", "--build", "shared"
    system "cmake", "--install", "shared"

    system "cmake", "-S", ".", "-B", "static", "-DBUILD_SHARED_LIBS=OFF", *std_cmake_args
    system "cmake", "--build", "static"
    lib.install "static/libdouble-conversion.a"
  end

  test do
    (testpath/"test.cc").write <<~CPP
      #include <double-conversion/bignum.h>
      #include <stdio.h>
      int main() {
          char buf[20] = {0};
          double_conversion::Bignum bn;
          bn.AssignUInt64(0x1234567890abcdef);
          bn.ToHexString(buf, sizeof buf);
          printf("%s", buf);
          return 0;
      }
    CPP
    system ENV.cc, "test.cc", "-L#{lib}", "-ldouble-conversion", "-o", "test"
    assert_equal "1234567890ABCDEF", `./test`
  end
end
