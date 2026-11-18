class LittleCms2 < Formula
  desc "Color management engine supporting ICC profiles"
  homepage "https://www.littlecms.com/"
  # Ensure release is announced at https://sourceforge.net/p/lcms/mailman/lcms-user/
  # Ref: https://github.com/mm2/Little-CMS/issues/569#issuecomment-4414911319
  url "https://downloads.sourceforge.net/project/lcms/lcms/2.20/lcms2-2.20.tar.gz"
  sha256 "18ff5504fa9cc8a2b1f3591180d90ead16c8a2ea78e530523b46eab70e1ca6b9"
  license "MIT"
  version_scheme 1
  compatibility_version 1

  # The Little CMS website has been redesigned and there's no longer a
  # "Download" page we can check for releases. As of writing this, checking the
  # "Releases" blog posts seems to be our best option and we just have to hope
  # that the post URLs, headings, etc. maintain a consistent format.
  livecheck do
    url "https://www.littlecms.com/categories/releases/"
    regex(/Little\s*CMS\s+v?(\d+(?:\.\d+)+)\s+released/im)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/little-cms2-2.20"
    sha256 cellar: :any, sequoia: "7da750fec6ab0b08431e0fc2dc27fcd23cb1df9f9cdd0363f102b5a730b2d04a"
  end

  depends_on "lurepheonix/intel/jpeg-turbo"
  depends_on "lurepheonix/intel/libtiff"

  deny_network_access!

  def install
    system "./configure", *std_configure_args
    system "make", "install"

    # Avoid rebuilding dependents that hard-code the prefix.
    inreplace lib/"pkgconfig/lcms2.pc", prefix, opt_prefix
  end

  test do
    system bin/"jpgicc", test_fixtures("test.jpg"), "out.jpg"
    assert_path_exists testpath/"out.jpg"
  end
end
