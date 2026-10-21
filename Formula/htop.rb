class Htop < Formula
  desc "Improved top (interactive process viewer)"
  homepage "https://htop.dev/"
  url "https://github.com/htop-dev/htop/releases/download/3.5.3/htop-3.5.3.tar.xz"
  sha256 "a8b164386494cb85bb255a415a3f5f80afe7a0c4491da5d113b3a0f951087e65"
  license "GPL-2.0-or-later"

  livecheck do
    url :stable
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/htop-3.5.3"
    sha256 cellar: :any, sequoia: "750c5682428773d45886a4cafaeaba707ce013fa996b9d5c45898063d4b03315"
  end

  head do
    url "https://github.com/htop-dev/htop.git", branch: "main"

    depends_on "autoconf" => :build
    depends_on "automake" => :build
    depends_on "libtool" => :build
  end

  depends_on "pkgconf" => :build
  depends_on "ncurses" # enables mouse scroll

  on_linux do
    depends_on "lm-sensors"
  end

  deny_network_access!

  def install
    system "./autogen.sh" if build.head?
    args = ["--prefix=#{prefix}"]
    args << "--enable-sensors" if OS.linux?
    system "./configure", *args
    system "make", "install"
  end

  def caveats
    <<~EOS
      htop requires root privileges to correctly display all running processes,
      so you will need to run `sudo htop`.
      You should be certain that you trust any software you grant root privileges.
    EOS
  end

  test do
    pipe_output(bin/"htop", "q", 0)
  end
end
