class Mvfst < Formula
  desc "QUIC transport protocol implementation"
  homepage "https://github.com/facebook/mvfst"
  url "https://github.com/facebook/mvfst/archive/refs/tags/v2026.10.19.00.tar.gz"
  sha256 "e3862b6680bd49d013b701d62d1f30b7dc83a3b8c9b7712613ef2208e0c399e2"
  license "MIT"
  compatibility_version 1
  head "https://github.com/facebook/mvfst.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/mvfst-2026.10.19.00"
    sha256 cellar: :any, sequoia: "1aaa44c26777afb140a523ebb93f41946534a1ae71692c0d3a8cc5375687e7d3"
  end

  depends_on "lurepheonix/intel/cmake" => [:build, :test]
  depends_on "lurepheonix/intel/googletest" => :test
  depends_on "lurepheonix/intel/double-conversion"
  depends_on "lurepheonix/intel/fizz"
  depends_on "lurepheonix/intel/fmt"
  depends_on "lurepheonix/intel/folly"
  depends_on "lurepheonix/intel/gflags"
  depends_on "lurepheonix/intel/glog"
  depends_on "lurepheonix/intel/openssl@4"

  allow_network_access! :test

  def install
    shared_args = ["-DBUILD_SHARED_LIBS=ON", "-DCMAKE_INSTALL_RPATH=#{rpath}"]
    shared_args << "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-undefined,dynamic_lookup -Wl,-dead_strip_dylibs" if OS.mac?

    system "cmake", "-S", ".", "-B", "_build", "-DBUILD_TESTS=OFF", *shared_args, *std_cmake_args
    system "cmake", "--build", "_build"
    system "cmake", "--install", "_build"
  end

  test do
    ENV.delete "CPATH"
    stable.stage testpath

    (testpath/"CMakeLists.txt").atomic_write <<~CMAKE
      cmake_minimum_required(VERSION 4.0)
      project(echo CXX)
      set(CMAKE_CXX_STANDARD 20)

      list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
      find_package(fizz REQUIRED)
      find_package(gflags REQUIRED)
      find_package(GTest REQUIRED)
      find_package(mvfst REQUIRED)

      add_executable(echo
        quic/samples/echo/main.cpp
        quic/common/test/TestUtils.cpp
        quic/common/test/TestPacketBuilders.cpp
        quic/common/test/TestTransportUtils.cpp
      )
      target_link_libraries(echo mvfst::mvfst fizz::fizz_test_support GTest::gmock)
      target_include_directories(echo PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${OPENSSL_INCLUDE_DIR})
      set_target_properties(echo PROPERTIES BUILD_RPATH "#{lib};#{HOMEBREW_PREFIX}/lib")
    CMAKE

    ENV.append_path "CMAKE_PREFIX_PATH", formula_opt_prefix("openssl@4")
    system "cmake", "-S", ".", "-B", "build", *std_cmake_args
    system "cmake", "--build", "build"

    server_port = free_port
    server_pid = spawn "./build/echo", "--mode", "server",
                                       "--host", "127.0.0.1", "--port", server_port.to_s
    sleep 5

    Open3.popen3(
      "./build/echo", "--mode", "client",
                "--host", "127.0.0.1", "--port", server_port.to_s
    ) do |stdin, _, stderr, w|
      stdin.write "Hello world!\n"
      Timeout.timeout(60) do
        stderr.each do |line|
          break if line.include? "Client received data=echo Hello world!"
        end
      end
      stdin.close
    ensure
      Process.kill "TERM", w.pid
    end
  ensure
    Process.kill "TERM", server_pid
  end
end
