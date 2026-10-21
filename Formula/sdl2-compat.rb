class Sdl2Compat < Formula
  desc "SDL2 compatibility layer that uses SDL3 behind the scenes"
  homepage "https://github.com/libsdl-org/sdl2-compat"
  url "https://github.com/libsdl-org/sdl2-compat/releases/download/release-2.32.74/sdl2-compat-2.32.74.tar.gz"
  sha256 "ec68abde77e2e459c8abc4f9587b8976b5d2a657b2bfda2fb3a079b0f8924588"
  license "Zlib"
  head "https://github.com/libsdl-org/sdl2-compat.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/sdl2-compat-2.32.74"
    sha256 cellar: :any, sequoia: "64131fbe71496163869dbfb931f04ff6e9e17b7032ac4c3018f8e99d27e94cad"
  end

  depends_on "lurepheonix/intel/cmake" => :build
  depends_on "lurepheonix/intel/sdl3" => :no_linkage

  deny_network_access!

  def install
    args = ["-DCMAKE_INSTALL_RPATH=#{rpath(target: formula_opt_lib("sdl3"))}"] if OS.mac?

    # We override install_prefix to make sure substituted CMAKE_INSTALL_FULL_* use
    # HOMEBREW_PREFIX path because most build scripts assume that all SDL modules
    # are installed to the same prefix. Consequently SDL stuff cannot be keg-only
    system "cmake", "-S", ".", "-B", "build", *args, *std_cmake_args(install_prefix: HOMEBREW_PREFIX)
    system "cmake", "--build", "build"
    system "cmake", "--install", "build", "--prefix", prefix
    (lib/"pkgconfig").install_symlink "sdl2-compat.pc" => "sdl2.pc"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <SDL.h>

      int main(void) {
        if (SDL_Init(SDL_INIT_VIDEO) < 0) {
          SDL_Log("SDL_Init failed: %s", SDL_GetError());
          return 1;
        }
        SDL_Quit();
        return 0;
      }
    C

    flags = shell_output("#{bin}/sdl2-config --cflags --libs").chomp
    refute_match prefix.realpath.to_s, flags
    refute_match opt_prefix.to_s, flags

    system ENV.cc, "test.c", "-o", "test", *flags.split
    ENV["SDL_VIDEODRIVER"] = "dummy"
    system "./test"
  end
end
