class Harfbuzz < Formula
  desc "OpenType text shaping engine"
  homepage "https://github.com/harfbuzz/harfbuzz"
  url "https://github.com/harfbuzz/harfbuzz/releases/download/15.2.0/harfbuzz-15.2.0.tar.xz"
  sha256 "e2ec49090744383cdbe7df808c1cedaafba06a97be8dc4211fe546ba585f12cb"
  license "MIT"
  compatibility_version 1
  head "https://github.com/harfbuzz/harfbuzz.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/harfbuzz-15.2.0"
    sha256 cellar: :any, sequoia: "250af75c0fd749f49595ca955cb55ec6211bce977dd998dd769f0d7ec57a1aea"
  end

  # brew-bottle-farm: qualify intra-queue deps to the farm-bottled copies
  # (single-sourced per install; see patches/README.md).
  # depends_on "gobject-introspection" => :build  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/gobject-introspection" => :build
  # depends_on "meson" => :build  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/meson" => :build
  env :std  # passthrough env so farm bottled tools resolve their toolchain interpreter (superenv would scrub uv from PATH)
  depends_on "lurepheonix/intel/ninja" => :build
  depends_on "lurepheonix/intel/pkgconf" => :build
  # brew-bottle-farm: core python unpourable on Tier-3 guests; use the farm
  # shim-keg (pinned uv/asdf interpreter via farm-toolchain shims).
  # depends_on "python@3.15" => [:build, :test]  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/python@3.15" => [:build, :test]
  # brew-bottle-farm: un-bottled :test dep drags a core subtree into the
  # keg-lock set, double-locking every shared rack ("already locked"
  # fail-closed); no brew test step runs in the farm, so drop it.
  # depends_on "pygobject3" => :test  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/cairo"
  depends_on "lurepheonix/intel/freetype"
  depends_on "lurepheonix/intel/glib"
  depends_on "lurepheonix/intel/graphite2"
  depends_on "lurepheonix/intel/icu4c@79"
  depends_on "lurepheonix/intel/libpng"

  on_linux do
    depends_on "zlib-ng-compat"
  end

  resource "homebrew-test-ttf", :test do
    url "https://github.com/harfbuzz/harfbuzz/raw/fc0daafab0336b847ac14682e581a8838f36a0bf/test/shaping/fonts/sha1sum/270b89df543a7e48e206a2d830c0e10e5265c630.ttf"
    sha256 "9535d35dab9e002963eef56757c46881f6b3d3b27db24eefcc80929781856c77"
  end

  # downloads test resources
  allow_network_access! :test

  def install
    args = %w[
      --default-library=both
      -Dcairo=enabled
      -Dcoretext=enabled
      -Dfreetype=enabled
      -Dglib=enabled
      -Dgobject=enabled
      -Dgraphite=enabled
      -Dicu=enabled
      -Dintrospection=enabled
      -Dtests=disabled
    ]

    system "meson", "setup", "build", *args, *std_meson_args
    system "meson", "compile", "-j1", "-C", "build", "--verbose"  # brew-bottle-farm: cap jobs (8c16GB guest fork-EAGAIN at full parallelism; cf. glib/watchman)
    system "meson", "install", "-C", "build"
  end

  test do
    resource("homebrew-test-ttf").stage do
      shape = pipe_output("#{bin}/hb-shape 270b89df543a7e48e206a2d830c0e10e5265c630.ttf", "സ്റ്റ്").chomp
      assert_equal "[glyph201=0+1183|U0D4D=0+0]", shape
    end
    system python3, "-c", "from gi.repository import HarfBuzz"
  end
end
