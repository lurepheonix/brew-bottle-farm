class M4 < Formula
  desc "Macro processing language"
  homepage "https://www.gnu.org/software/m4/"
  url "https://ftpmirror.gnu.org/m4/m4-1.4.21.tar.xz"
  mirror "https://ftp.gnu.org/gnu/m4/m4-1.4.21.tar.xz"
  mirror "http://ftp.gnu.org/gnu/m4/m4-1.4.21.tar.xz"
  sha256 "f25c6ab51548a73a75558742fb031e0625d6485fe5f9155949d6486a2408ab66"
  license "GPL-3.0-or-later"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/m4-1.4.21"
    sha256 cellar: :any_skip_relocation, sequoia: "6a269deaa888d938535c253ec9fbcf872e848185cbcdd9be0bb93aeb2a14e8f3"
  end

  keg_only :provided_by_macos

  def install
    system "./configure", "--disable-dependency-tracking", "--prefix=#{prefix}"
    system "make"
    system "make", "install"
  end

  test do
    assert_match "Homebrew",
      pipe_output(bin/"m4", "define(TEST, Homebrew)\nTEST\n")
  end
end
