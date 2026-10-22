class Libsodium < Formula
  desc "NaCl networking and cryptography library"
  homepage "https://libsodium.org/"
  url "https://download.libsodium.org/libsodium/releases/libsodium-1.0.22.tar.gz"
  sha256 "adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349"
  license "ISC"
  compatibility_version 1

  livecheck do
    url "https://download.libsodium.org/libsodium/releases/"
    regex(/href=.*?libsodium[._-]v?(\d+(?:\.\d+)+)\.t/i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/libsodium-1.0.22"
    sha256 cellar: :any, sequoia: "d1cf7b1d57cbdb0d9ebe86d97e466c88db93684f89b156dfbe3410c2bdfe3fad"
  end

  head do
    url "https://github.com/jedisct1/libsodium.git", branch: "master"

    depends_on "lurepheonix/intel/autoconf" => :build
    depends_on "lurepheonix/intel/automake" => :build
    depends_on "lurepheonix/intel/libtool" => :build
  end

  def install
    # Allow type conversion between vectors on Arm Linux
    ENV.append_to_cflags "-flax-vector-conversions" if OS.linux? && Hardware::CPU.arm?

    system "./autogen.sh", "-sb" if build.head?
    system "./configure", "--disable-debug", "--disable-dependency-tracking",
                          "--prefix=#{prefix}"
    system "make", "check"
    system "make", "install"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <assert.h>
      #include <sodium.h>

      int main()
      {
        assert(sodium_init() != -1);
        return 0;
      }
    C
    system ENV.cc, "test.c", "-I#{include}", "-L#{lib}",
                   "-lsodium", "-o", "test"
    system "./test"
  end
end
