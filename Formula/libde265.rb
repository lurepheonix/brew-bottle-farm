class Libde265 < Formula
  desc "Open h.265 video codec implementation"
  homepage "https://github.com/strukturag/libde265"
  url "https://github.com/strukturag/libde265/releases/download/v1.1.3/libde265-1.1.3.tar.gz"
  sha256 "554228bd17788c99a7e63b37ab5634722190e6e2bf60c1dcb01cef328e133905"
  license "LGPL-3.0-or-later"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/libde265-1.1.3"
    sha256 cellar: :any, sequoia: "7d65cbaf0a5a809b9b146e179be7006c40be695be0c92ec32f463d29abd75e44"
  end

  depends_on "cmake" => :build

  deny_network_access!

  def install
    system "cmake", "-S", ".", "-B", "build",
                    "-DCMAKE_INSTALL_RPATH=#{rpath};#{rpath(source: libexec/"bin")}",
                    "-DENABLE_DECODER=OFF",
                    *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  test do
    (testpath/"test.c").write <<~'C'
      #include <libde265/de265.h>
      #include <stdio.h>
      #include <string.h>

      int main(void) {
        de265_decoder_context *ctx;
        const char *version = de265_get_version();

        if (strcmp(version, LIBDE265_VERSION) != 0) {
          return 1;
        }

        if (de265_init() != DE265_OK) {
          return 2;
        }

        ctx = de265_new_decoder();
        if (ctx == NULL) {
          de265_free();
          return 3;
        }

        printf("%s\n", version);

        de265_free_decoder(ctx);
        de265_free();

        return 0;
      }
    C

    system ENV.cc, "test.c", "-I#{include}", "-L#{lib}", "-lde265", "-o", "test"
    assert_equal version.to_s, shell_output("./test").strip
  end
end
