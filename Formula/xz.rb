class Xz < Formula
  desc "General-purpose data compression with high compression ratio"
  homepage "https://tukaani.org/xz/"
  url "https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz"
  mirror "https://downloads.sourceforge.net/project/lzmautils/xz-5.8.4.tar.gz"
  mirror "http://downloads.sourceforge.net/project/lzmautils/xz-5.8.4.tar.gz"
  sha256 "0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9"
  license all_of: [
    "0BSD",
    "GPL-2.0-or-later",
  ]
  version_scheme 1
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/xz-5.8.4"
    sha256 cellar: :any, sequoia: "2300f0e98f2091b74de75c1b159c5f9fbaad144e513af43b440d9efb5f13dc5f"
  end

  deny_network_access!

  def install
    system "./configure", "--disable-silent-rules", "--disable-nls", *std_configure_args
    system "make", "check"
    system "make", "install"
  end

  test do
    path = testpath/"data.txt"
    original_contents = "." * 1000
    path.write original_contents

    # compress: data.txt -> data.txt.xz
    system bin/"xz", path
    refute_path_exists path

    # decompress: data.txt.xz -> data.txt
    system bin/"xz", "-d", "#{path}.xz"
    assert_equal original_contents, path.read
  end
end
