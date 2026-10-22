class Xxhash < Formula
  desc "Extremely fast non-cryptographic hash algorithm"
  homepage "https://xxhash.com"
  url "https://github.com/Cyan4973/xxHash/archive/refs/tags/v0.8.4.tar.gz"
  sha256 "5738270935e7c3d38a79b3adf7c9692566ce7895a25f67de43ad52ab504acd32"
  license all_of: [
    "BSD-2-Clause", # library
    "GPL-2.0-or-later", # `xxhsum` command line utility
  ]

  livecheck do
    url :stable
    strategy :github_latest
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/xxhash-0.8.4"
    sha256 cellar: :any, sequoia: "880a072b512532075d52147ce77edda30793ce28fdf9d3eac65260b1877766fa"
  end

  depends_on "lurepheonix/intel/cmake" => [:build, :test]

  deny_network_access!

  def install
    ENV.O3

    args = ["PREFIX=#{prefix}"]
    if Hardware::CPU.intel?
      args << "DISPATCH=1"
      ENV.runtime_cpu_detection
    end

    system "make", "install", *args
    prefix.install "cli/COPYING"

    # We use CMake for package configuration files which are needed by `manticoresearch`.
    # The Makefile is used for everything else as it is the only officially supported way.
    ENV["DESTDIR"] = buildpath
    system "cmake", "-S", "build/cmake", "-B", "_build", *std_cmake_args
    system "cmake", "--build", "_build" # needed to run `--install` which rewrites build path in .cmake file
    system "cmake", "--install", "_build"
    lib.install File.join(buildpath, lib, "cmake")
  end

  test do
    (testpath/"leaflet.txt").write "No computer should be without one!"
    assert_match(/^67bc7cc242ebc50a/, shell_output("#{bin}/xxhsum leaflet.txt"))

    # Simplified snippet of https://github.com/Cyan4973/xxHash/blob/dev/cli/xsum_sanity_check.c
    (testpath/"test.c").write <<~C
      #include <assert.h>
      #include <stdint.h>
      #include <xxhash.h>

      int main() {
        size_t len = 0;
        uint64_t seed = 2654435761U;
        uint64_t Nresult = 0xAC75FDA2929B17EFULL;

        XXH64_state_t *state = XXH64_createState();
        assert(state != NULL);
        assert(XXH64(NULL, len, seed) == Nresult);
        XXH64_freeState(state);
        return 0;
      }
    C

    (testpath/"CMakeLists.txt").write <<~CMAKE
      cmake_minimum_required(VERSION 3.5)
      project(test LANGUAGES C)
      find_package(xxHash CONFIG REQUIRED)
      add_executable(test test.c)
      target_link_libraries(test PRIVATE xxHash::xxhash)
    CMAKE

    system "cmake", "-S", ".", "-B", "build"
    system "cmake", "--build", "build"
    system "./build/test"
  end
end
