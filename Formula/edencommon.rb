class Edencommon < Formula
  desc "Shared library for Watchman and Eden projects"
  homepage "https://github.com/facebookexperimental/edencommon"
  url "https://github.com/facebookexperimental/edencommon/archive/refs/tags/v2026.10.19.00.tar.gz"
  sha256 "8f998ab2f535a9736e073dae16b55f76fcc65d142dab551f3919e96a019a5f3b"
  license "MIT"
  compatibility_version 1
  head "https://github.com/facebookexperimental/edencommon.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/edencommon-2026.10.19.00"
    sha256 cellar: :any, sequoia: "49d64989dad6a52782568fd7ed397af67c1e02e178c143cbeaffbc487f012168"
  end

  depends_on "lurepheonix/intel/cmake" => :build
  depends_on "lurepheonix/intel/fbthrift" => :build
  depends_on "lurepheonix/intel/gflags" => :build
  depends_on "lurepheonix/intel/glog" => :build
  depends_on "lurepheonix/intel/googletest" => :build
  depends_on "lurepheonix/intel/mvfst" => :build
  depends_on "lurepheonix/intel/wangle" => :build
  depends_on "lurepheonix/intel/boost"
  depends_on "lurepheonix/intel/fb303"
  depends_on "lurepheonix/intel/fmt"
  depends_on "lurepheonix/intel/folly"

  def install
    # Fix "Process terminated due to timeout" by allowing a longer timeout.
    # Related: https://gitlab.kitware.com/cmake/cmake/-/issues/26773
    test_cmakelists = %w[
      eden/common/os/test/CMakeLists.txt
      eden/common/utils/test/CMakeLists.txt
    ]
    inreplace test_cmakelists, /(gtest_discover_tests\(.*)\)/, "\\1 DISCOVERY_TIMEOUT 60)"

    # Avoid having to build FBThrift py library
    inreplace "CMakeLists.txt", "COMPONENTS cpp2 py)", "COMPONENTS cpp2)"

    shared_args = %W[
      -DCMAKE_CXX_STANDARD=20
      -DBUILD_SHARED_LIBS=ON
      -DCMAKE_INSTALL_RPATH=#{rpath}
    ]
    shared_args << "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-undefined,dynamic_lookup -Wl,-dead_strip_dylibs" if OS.mac?

    system "cmake", "-S", ".", "-B", "_build", *shared_args, *std_cmake_args
    system "cmake", "--build", "_build"
    system "cmake", "--install", "_build"
  end

  test do
    (testpath/"test.cc").write <<~CPP
      #include <eden/common/utils/ProcessInfo.h>
      #include <cstdlib>
      #include <iostream>

      using namespace facebook::eden;

      int main(int argc, char **argv) {
        if (argc <= 1) return 1;
        int pid = std::atoi(argv[1]);
        std::cout << readProcessName(pid) << std::endl;
        return 0;
      }
    CPP

    system ENV.cxx, "-std=c++20", "-I#{include}", "test.cc",
                    "-L#{lib}", "-L#{formula_opt_lib("folly")}",
                    "-L#{formula_opt_lib("boost")}", "-L#{formula_opt_lib("glog")}", "-L#{formula_opt_lib("fmt")}",
                    "-ledencommon_utils", "-lfolly", "-lfmt", "-lboost_context", "-lglog", "-o", "test"
    assert_match "ruby", shell_output("./test #{Process.pid}")
  end
end
