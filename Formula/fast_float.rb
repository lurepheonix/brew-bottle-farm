class FastFloat < Formula
  desc "Fast and exact implementation of the C++ from_chars functions for number types"
  homepage "https://fastfloat.github.io/fast_float/"
  url "https://github.com/fastfloat/fast_float/archive/refs/tags/v8.3.2.tar.gz"
  sha256 "71bb9e865b888df01351558db5a39586d13ea97ada162156b3a07784d8c1b26b"
  license "Apache-2.0"
  head "https://github.com/fastfloat/fast_float.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/fast_float-8.3.2"
    sha256 cellar: :any_skip_relocation, sequoia: "341814e78bd76f21afdd4dfefd40ad5268136f1f56d249ea2df4f83406977a17"
  end

  depends_on "lurepheonix/intel/cmake" => :build

  deny_network_access!

  def install
    system "cmake", "-S", ".", "-B", "build", *std_cmake_args
    system "cmake", "--install", "build"
  end

  test do
    (testpath/"test-fast-float.cc").write <<~CPP
      #include "fast_float/fast_float.h"
      #include <iostream>

      int main() {
          const std::string input =  "3.1416 xyz ";
          double result;
          auto answer = fast_float::from_chars(input.data(), input.data()+input.size(), result);
          if(answer.ec != std::errc()) { std::cerr << "parsing failure\\n"; return EXIT_FAILURE; }
          std::cout << "parsed the number " << result << std::endl;
          return EXIT_SUCCESS;
      }
    CPP

    ENV.append_to_cflags "-I#{include}"
    ENV.append "CXXFLAGS", "-std=c++11"

    system "make", "test-fast-float"
    output = shell_output("./test-fast-float")

    assert_match "parsed the number", output
    refute_match "parsing failure", output
  end
end
