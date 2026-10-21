class Giflib < Formula
  desc "Library and utilities for processing GIFs"
  homepage "https://giflib.sourceforge.net/"
  url "https://downloads.sourceforge.net/project/giflib/giflib-6.x/giflib-6.1.3.tar.gz"
  sha256 "b65b66b99f0424b93525f987386f22fc5efb9da2bfc92ad4a532249aaffbab0e"
  license "MIT"
  compatibility_version 1

  livecheck do
    url :stable
    regex(%r{url=.*?/giflib[._-]v?(\d+(?:\.\d+)+)\.t}i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/giflib-6.1.3"
    sha256 cellar: :any, sequoia: "66173cb225b2edfcc1ff7c93b59c8290878130f666d4fd4ef9b27c91032e4731"
  end

  deny_network_access!

  def install
    args = ["PREFIX=#{prefix}"]
    # Manually skipping shared libutil due to https://sourceforge.net/p/giflib/bugs/189/.
    # It is currently unused (binaries link to libutil.a) and not installed.
    args << "LIBUTILSO=" if OS.mac?

    system "make", "all", *args
    ENV.deparallelize # avoid parallel mkdir
    system "make", "install", *args
  end

  test do
    output = shell_output("#{bin}/giftext #{test_fixtures("test.gif")}")
    assert_match "Screen Size - Width = 1, Height = 1", output
  end
end
