class Fmt < Formula
  desc "Open-source formatting library for C++"
  homepage "https://fmt.dev/"
  url "https://github.com/fmtlib/fmt/releases/download/12.2.0/fmt-12.2.0.zip"
  sha256 "a2f4a8d51178f954e4c339007f77edd76ba0cb2e36f87a48e5a5403d9be5878f"
  license "MIT"
  compatibility_version 2
  head "https://github.com/fmtlib/fmt.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/fmt-12.2.0"
    sha256 cellar: :any, sequoia: "570597bb59def28c31da06203d4a9160e1238c2b379555aa30f683077a8c57f4"
  end

  depends_on "lurepheonix/intel/cmake" => :build

  deny_network_access!

  def install
    system "cmake", "-S", ".", "-B", "build", "-DBUILD_SHARED_LIBS=TRUE", *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"

    system "cmake", "-S", ".", "-B", "build-static", "-DBUILD_SHARED_LIBS=FALSE", *std_cmake_args
    system "cmake", "--build", "build-static"
    lib.install "build-static/libfmt.a"
  end

  test do
    (testpath/"test.cpp").write <<~CPP
      #include <iostream>
      #include <string>
      #include <fmt/format.h>
      int main()
      {
        std::string str = fmt::format("The answer is {}", 42);
        std::cout << str;
        return 0;
      }
    CPP

    system ENV.cxx, "test.cpp", "-std=c++11", "-o", "test",
                  "-I#{include}",
                  "-L#{lib}",
                  "-lfmt"
    assert_equal "The answer is 42", shell_output("./test")
  end
end
