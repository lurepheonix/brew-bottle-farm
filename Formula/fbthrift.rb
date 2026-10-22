class Fbthrift < Formula
  desc "Facebook's branch of Apache Thrift, including a new C++ server"
  homepage "https://github.com/facebook/fbthrift"
  url "https://github.com/facebook/fbthrift/archive/refs/tags/v2026.10.19.00.tar.gz"
  sha256 "51fe01005b3c82294310a398086425262707b410cd8d2b0238de38cd426dc105"
  license "Apache-2.0"
  compatibility_version 1
  head "https://github.com/facebook/fbthrift.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/fbthrift-2026.10.19.00"
    sha256 cellar: :any, sequoia: "7c9031405c552c080b90727762edb998838b44d5c01d196fa10f57c48ad265ea"
  end

  depends_on "lurepheonix/intel/bison" => :build # Needs Bison 3.1+
  depends_on "lurepheonix/intel/cmake" => [:build, :test]
  depends_on "lurepheonix/intel/mvfst" => [:build, :test]
  depends_on "lurepheonix/intel/zstd" => :build
  depends_on "lurepheonix/intel/double-conversion"
  depends_on "lurepheonix/intel/fizz"
  depends_on "lurepheonix/intel/fmt"
  depends_on "lurepheonix/intel/folly"
  depends_on "lurepheonix/intel/gflags"
  depends_on "lurepheonix/intel/glog"
  depends_on "lurepheonix/intel/openssl@4"
  depends_on "lurepheonix/intel/wangle"
  depends_on "lurepheonix/intel/xxhash"

  uses_from_macos "flex" => :build
  uses_from_macos "python" => :build

  on_linux do
    depends_on "lurepheonix/intel/boost"
    depends_on "zlib-ng-compat"
  end

  conflicts_with "thrift", because: "both install `thrift` binaries"

  def install
    # Work around build failure with Xcode 16
    # Issue ref: https://github.com/facebook/fbthrift/issues/618
    # Issue ref: https://github.com/facebook/fbthrift/issues/607
    ENV.append "CXXFLAGS", "-fno-assume-unique-vtables" if DevelopmentTools.clang_build_version >= 1600
    # Restore `<fmt/core.h>` pulling in `<fmt/format.h>` (dropped in fmt 12.2); #702 doesn't apply to this tag.
    # PR ref: https://github.com/facebook/fbthrift/pull/702
    ENV.append "CXXFLAGS", "-DFMT_DEPRECATED_HEAVY_CORE"

    ENV["OPENSSL_ROOT_DIR"] = formula_opt_prefix("openssl@4")

    # The static libraries are a bit annoying to build. If modifying this formula
    # to include them, make sure `bin/thrift1` links with the dynamic libraries
    # instead of the static ones (e.g. `libcompiler_base`, `libcompiler_lib`, etc.)
    shared_args = ["-DBUILD_SHARED_LIBS=ON", "-DCMAKE_INSTALL_RPATH=#{rpath}", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"]
    if OS.mac?
      shared_args << "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-undefined,dynamic_lookup -Wl,-dead_strip_dylibs"
      shared_args << "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip_dylibs"
    end

    # We build in-source to avoid an error from thrift/lib/cpp2/test:
    # Output path .../build/shared/thrift/lib/cpp2/test/../../../conformance/if is unusable or not a directory
    system "cmake", "-S", ".", "-B", ".", *shared_args, *std_cmake_args
    system "cmake", "--build", "."
    system "cmake", "--install", "."

    elisp.install "thrift/contrib/thrift.el"
    (share/"vim/vimfiles/syntax").install "thrift/contrib/thrift.vim"

    # Save a copy of FindxxHash.cmake to test with as it is used in FBThriftConfig.cmake
    (libexec/"cmake").install "build/fbcode_builder/CMake/FindXxhash.cmake"
  end

  test do
    (testpath/"example.thrift").write <<~THRIFT
      namespace cpp tamvm

      service ExampleService {
        i32 get_number(1:i32 number);
      }
    THRIFT

    system bin/"thrift1", "--gen", "mstch_cpp2", "example.thrift"
    assert_path_exists testpath/"gen-cpp2"
    assert_predicate testpath/"gen-cpp2", :directory?

    # TODO: consider adding an actual test
    (testpath/"test.cpp").write "int main() { return 0; }\n"

    # Test CMake package to make sure required dependencies without linkage are kept,
    # Link to `FBThrift::transport` as it uses path to `zstd` shared library
    (testpath/"CMakeLists.txt").write <<~CMAKE
      cmake_minimum_required(VERSION 4.0)
      project(test LANGUAGES CXX)

      list(APPEND CMAKE_MODULE_PATH "#{formula_opt_libexec("fizz")}/cmake")
      list(APPEND CMAKE_MODULE_PATH "#{opt_libexec}/cmake")
      find_package(gflags REQUIRED)
      find_package(FBThrift CONFIG REQUIRED)

      add_executable(test test.cpp)
      target_link_libraries(test FBThrift::transport)
    CMAKE

    ENV.append_path "CMAKE_PREFIX_PATH", formula_opt_prefix("openssl@4")
    system "cmake", "-S", ".", "-B", "build", *std_cmake_args
    system "cmake", "--build", "build"
  end
end
