class Fb303 < Formula
  desc "Thrift functions for querying information from a service"
  homepage "https://github.com/facebook/fb303"
  url "https://github.com/facebook/fb303/archive/refs/tags/v2026.10.19.00.tar.gz"
  sha256 "18577844e7d185b5330e88a484889e1fcd97b5527788a6afcda1d788759ee5d9"
  license "Apache-2.0"
  compatibility_version 1
  head "https://github.com/facebook/fb303.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/fb303-2026.10.19.00"
    sha256 cellar: :any, sequoia: "c1591a0133e9a20d0b33fba84b1cb1f244e7b6d4ec2b5e719a588147dc46d080"
  end

  depends_on "lurepheonix/intel/cmake" => [:build, :test]
  depends_on "lurepheonix/intel/fizz" => [:build, :test]
  depends_on "lurepheonix/intel/mvfst" => [:build, :test]
  depends_on "lurepheonix/intel/fbthrift"
  depends_on "lurepheonix/intel/fmt"
  depends_on "lurepheonix/intel/folly"
  depends_on "lurepheonix/intel/gflags"
  depends_on "lurepheonix/intel/glog"

  def install
    shared_args = ["-DBUILD_SHARED_LIBS=ON", "-DCMAKE_INSTALL_RPATH=#{rpath}"]
    shared_args << "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-dead_strip_dylibs" if OS.mac?

    system "cmake", "-S", ".", "-B", "build", "-DPYTHON_EXTENSIONS=OFF", *shared_args, *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  test do
    (testpath/"test.cpp").write <<~CPP
      #include "fb303/thrift/gen-cpp2/BaseService.h"
      #include <iostream>
      int main() {
        auto service = facebook::fb303::cpp2::BaseServiceSvIf();
        std::cout << service.getGeneratedName() << std::endl;
        return 0;
      }
    CPP

    (testpath/"CMakeLists.txt").write <<~CMAKE
      cmake_minimum_required(VERSION 4.0)
      project(test LANGUAGES CXX)
      set(CMAKE_CXX_STANDARD 20)

      list(APPEND CMAKE_MODULE_PATH "#{formula_opt_libexec("fizz")}/cmake")
      list(APPEND CMAKE_MODULE_PATH "#{formula_opt_libexec("fbthrift")}/cmake")
      find_package(FBThrift CONFIG REQUIRED)
      find_package(wangle CONFIG REQUIRED)
      find_package(fb303 CONFIG REQUIRED)

      add_executable(test test.cpp)
      target_link_libraries(test fb303::fb303_thrift_cpp)
    CMAKE

    ENV.delete "CPATH" if OS.mac?
    folly = Formula["lurepheonix/intel/folly"]
    if Tab.for_formula(folly).built_as_bottle
      ENV.remove_from_cflags "-march=native"
      ENV.append_to_cflags "-march=#{Hardware.oldest_cpu}" if Hardware::CPU.intel?
    end

    openssl = folly.deps.find { |dep| dep.name.start_with?("openssl@") }
    ENV.append_path "CMAKE_PREFIX_PATH", formula_opt_prefix(openssl.name)

    args = OS.mac? ? [] : ["-DCMAKE_BUILD_RPATH=#{lib};#{HOMEBREW_PREFIX}/lib"]
    system "cmake", "-S", ".", "-B", ".", *args, *std_cmake_args
    system "cmake", "--build", "."
    assert_equal "BaseService", shell_output("./test").strip
  end
end
