class Imagemagick < Formula
  desc "Tools and libraries to manipulate images in select formats"
  homepage "https://imagemagick.org"
  url "https://github.com/ImageMagick/ImageMagick/releases/download/7.1.2-35/ImageMagick-7.1.2-35.7z"
  sha256 "1d95f7d0ed11e91a3ee9e3042a8e248cb88c666dd9256ab14cc871b1f73138fd"
  license "ImageMagick"
  compatibility_version 3
  head "https://github.com/ImageMagick/ImageMagick.git", branch: "main"

  livecheck do
    url :stable
    regex(/^v?(\d+(?:\.\d+)+-\d+)$/i)
    strategy :github_releases
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/imagemagick-7.1.2-35"
    sha256 sequoia: "56a8d6ae78944d3139ca046140f74b48d6b315972a23de5cbb009d73c712ae6c"
  end

  depends_on "lurepheonix/intel/pkgconf" => :build

  # Only add dependencies required for dependents in homebrew-core,
  # recursive dependencies or INCREDIBLY widely used and light formats in the
  # current year (2026).
  # Add other dependencies to imagemagick-full formula.
  depends_on "lurepheonix/intel/freetype"
  depends_on "lurepheonix/intel/jpeg-turbo"
  # brew-bottle-farm: qualify intra-queue dep to the farm-bottled copy
  # (single-sourced per install; see patches/README.md).
  # depends_on "libheif"  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/libheif"
  depends_on "lurepheonix/intel/libpng"
  depends_on "lurepheonix/intel/libtiff"
  depends_on "lurepheonix/intel/libtool"
  depends_on "lurepheonix/intel/little-cms2"
  depends_on "lurepheonix/intel/webp"
  depends_on "lurepheonix/intel/xz"

  uses_from_macos "bzip2"
  uses_from_macos "libxml2"

  on_linux do
    depends_on "zlib-ng-compat"
  end

  skip_clean :la

  deny_network_access!

  def install
    # Avoid references to shim
    inreplace Dir["**/*-config.in"], "@PKG_CONFIG@", formula_opt_bin("pkg-config")/"pkg-config"
    # versioned stuff in main tree is pointless for us
    inreplace "configure", "${PACKAGE_NAME}-${PACKAGE_BASE_VERSION}", "${PACKAGE_NAME}"

    args = [
      "--enable-osx-universal-binary=no",
      "--disable-silent-rules",
      "--disable-opencl",
      "--enable-shared",
      "--enable-static",
      "--with-gvc=no",
      "--with-modules",
      "--with-webp=yes",
      "--with-heic=yes",
      "--with-raw=no",
      "--without-gslib",
      "--with-lqr",
      "--without-djvu",
      "--without-fftw",
      "--without-pango",
      "--without-wmf",
      "--without-jxl",
      "--without-openexr",
    ]
    args << "--without-x" if OS.mac?

    system "./configure", *args, *std_configure_args
    system "make", "install"
  end

  def caveats
    <<~EOS
      imagemagick-full includes additional tools and libraries that are not included in the regular imagemagick formula.
    EOS
  end

  test do
    assert_match "PNG", shell_output("#{bin}/identify #{test_fixtures("test.png")}")

    # Check support for recommended features and delegates.
    features = shell_output("#{bin}/magick -version")
    %w[Modules heic jpeg png tiff].each do |feature|
      assert_match feature, features
    end
  end
end
