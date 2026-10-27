class Rsync < Formula
  desc "Utility that provides fast incremental file transfer"
  homepage "https://rsync.samba.org/"
  url "https://github.com/RsyncProject/rsync/releases/download/v3.5.1/rsync-3.5.1.tar.gz"
  mirror "https://rsync.samba.org/ftp/rsync/rsync-3.5.1.tar.gz"
  sha256 "c55f9c9dc10fb8bec397b399a0fdded53cc9a2d8e30891bb0d63724d25c37bef"
  license "GPL-3.0-or-later"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/rsync-3.5.1"
    sha256 cellar: :any, sequoia: "b0dfc5e7a7cb60ab4f32ed95576d7b992aa4b98f252a2a561ca88f5df7388e73"
  end

  depends_on "lurepheonix/intel/libidn2"
  depends_on "lurepheonix/intel/lz4"
  depends_on "lurepheonix/intel/openssl@4"
  depends_on "lurepheonix/intel/popt"
  depends_on "lurepheonix/intel/xxhash"
  depends_on "lurepheonix/intel/zstd"

  on_linux do
    depends_on "zlib-ng-compat"
  end

  deny_network_access!

  def install
    args = %W[
      --with-rsyncd-conf=#{etc}/rsyncd.conf
      --with-included-popt=no
      --with-included-zlib=no
      --with-rrsync=yes
      --enable-ipv6
    ]

    system "./configure", *args, *std_configure_args
    system "make"
    system "make", "install"
  end

  test do
    mkdir "a"
    mkdir "b"

    ["foo\n", "bar\n", "baz\n"].map.with_index do |s, i|
      (testpath/"a/#{i + 1}.txt").write s
    end

    system bin/"rsync", "-artv", testpath/"a/", testpath/"b/"

    (1..3).each do |i|
      assert_equal (testpath/"a/#{i}.txt").read, (testpath/"b/#{i}.txt").read
    end
  end
end
