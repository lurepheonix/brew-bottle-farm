class Unibilium < Formula
  desc "Very basic terminfo library"
  homepage "https://github.com/neovim/unibilium"
  url "https://github.com/neovim/unibilium/archive/refs/tags/v2.1.4.tar.gz"
  sha256 "7360907bcf79ba49f6fc4a504767ff86e93ab9018477026fcc70d5ab77e1f2c1"
  license "LGPL-3.0-or-later"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/unibilium-2.1.4"
    sha256 sequoia: "4a1b9feffde7f566156c47476a7933a41e781e6db94eb4b33b45df2a9e045885"
  end

  depends_on "lurepheonix/intel/autoconf" => :build
  depends_on "lurepheonix/intel/automake" => :build
  depends_on "lurepheonix/intel/libtool" => :build

  def install
    system "autoreconf", "--force", "--install", "--verbose"
    system "./configure", *std_configure_args

    # Check Homebrew ncurses terminfo if available.
    terminfo_dirs = [Formula["lurepheonix/intel/ncurses"].opt_share/"terminfo"]

    terminfo_dirs += if OS.mac?
      [Utils.safe_popen_read("ncurses5.4-config", "--terminfo-dirs").strip]
    else
      # Unibilium's default terminfo path
      %w[
        /etc/terminfo
        /lib/terminfo
        /usr/share/terminfo
        /usr/lib/terminfo
        /usr/local/share/terminfo
        /usr/local/lib/terminfo
      ]
    end

    system "make", "TERMINFO_DIRS=\"#{terminfo_dirs.join(":")}\""
    system "make", "install", "PREFIX=#{prefix}"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <unibilium.h>
      #include <stdio.h>

      int main()
      {
        setvbuf(stdout, NULL, _IOLBF, 0);
        unibi_term *ut = unibi_dummy();
        unibi_destroy(ut);
        printf("%s", unibi_terminfo_dirs);
        return 0;
      }
    C
    system ENV.cc, "-I#{include}", "test.c", "-L#{lib}", "-lunibilium", "-o", "test"
    assert_match %r{\A#{Formula["lurepheonix/intel/ncurses"].opt_share}/terminfo:}o, shell_output("./test")
  end
end
