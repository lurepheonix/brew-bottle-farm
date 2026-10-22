class Fizz < Formula
  desc "C++14 implementation of the TLS-1.3 standard"
  homepage "https://github.com/facebookincubator/fizz"
  url "https://github.com/facebookincubator/fizz/archive/refs/tags/v2026.10.19.00.tar.gz"
  sha256 "88fcc4d518b41b727399423c680f17bdb1b26e7f8fcb256ac7319a698e40b94b"
  license "BSD-3-Clause"
  compatibility_version 1
  head "https://github.com/facebookincubator/fizz.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/fizz-2026.10.19.00"
    sha256 cellar: :any, sequoia: "88ccaae4288302ba9d95055fdb87b2ffd689c46c50142251a07a44b14187bfcf"
  end

  depends_on "lurepheonix/intel/cmake" => [:build, :test]
  depends_on "lurepheonix/intel/gflags" => :build
  depends_on "lurepheonix/intel/libevent" => :build
  depends_on "lurepheonix/intel/fmt"
  depends_on "lurepheonix/intel/folly"
  depends_on "lurepheonix/intel/glog"
  depends_on "lurepheonix/intel/libsodium"
  depends_on "lurepheonix/intel/openssl@4"
  depends_on "lurepheonix/intel/zstd"

  on_linux do
    depends_on "zlib-ng-compat"
  end

  def install
    args = %W[
      -DBUILD_EXAMPLES=OFF
      -DBUILD_TESTS=OFF
      -DBUILD_SHARED_LIBS=ON
      -DCMAKE_INSTALL_RPATH=#{rpath}
    ]
    if OS.mac?
      # Prevent indirect linkage with boost and snappy.
      args += %w[
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip_dylibs
        -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-dead_strip_dylibs
      ]
    end
    system "cmake", "-S", "fizz", "-B", "build", *args, *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"

    # `libsodium` does not install a CMake package configuration file. There
    # is a find module (at least in 1.0.20 tarball), but upstream has deleted
    # it in HEAD. Also, find modules are usually not shipped by upstream[^1].
    #
    # Since fizz-config.cmake requires FindSodium.cmake[^2], we save a copy in
    # libexec that can be used internally for testing `fizz` and dependents.
    #
    # [^1]: https://cmake.org/cmake/help/latest/manual/cmake-packages.7.html#find-module-packages
    # [^2]: https://github.com/facebookincubator/fizz/issues/141
    (libexec/"cmake").install "build/fbcode_builder/CMake/FindSodium.cmake"
  end

  test do
    (testpath/"test.cpp").write <<~CPP
      #include <fizz/client/AsyncFizzClient.h>
      #include <iostream>

      int main() {
        auto context = fizz::client::FizzClientContext();
        std::cout << toString(context.getSupportedVersions()[0]) << std::endl;
      }
    CPP

    (testpath/"CMakeLists.txt").write <<~CMAKE
      cmake_minimum_required(VERSION 4.0)
      project(test LANGUAGES CXX)
      set(CMAKE_CXX_STANDARD 20)

      list(APPEND CMAKE_MODULE_PATH "#{libexec}/cmake")
      find_package(gflags REQUIRED)
      find_package(fizz CONFIG REQUIRED)

      add_executable(test test.cpp)
      target_link_libraries(test fizz::fizz)
    CMAKE

    ENV.delete "CPATH"

    args = ["-DCMAKE_PREFIX_PATH=#{formula_opt_prefix("openssl@4")}"]
    args << "-DCMAKE_BUILD_RPATH=#{lib};#{HOMEBREW_PREFIX}/lib" if OS.linux?
    system "cmake", "-S", ".", "-B", "build", *args, *std_cmake_args
    system "cmake", "--build", "build"
    assert_match "TLS", shell_output("./build/test")
  end
end
