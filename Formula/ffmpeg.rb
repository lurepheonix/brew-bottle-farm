class Ffmpeg < Formula
  desc "Play, record, convert, and stream select audio and video codecs"
  homepage "https://ffmpeg.org/"
  url "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz"
  sha256 "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
  # None of these parts are used by default, you have to explicitly pass `--enable-gpl`
  # to configure to activate them. In this case, FFmpeg's license changes to GPL v2+.
  # Passing `--enable-version3` changes the license to GPL v3+.
  license "GPL-3.0-or-later"
  revision 1
  compatibility_version 3
  head "https://github.com/FFmpeg/FFmpeg.git", branch: "master"

  livecheck do
    url "https://ffmpeg.org/download.html"
    regex(/href=.*?ffmpeg[._-]v?(\d+(?:\.\d+)+)\.t/i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/ffmpeg-9.0.2"
    sha256 sequoia: "3ac9914b56eb1523f8a3978cf89b4b8a71e2c775206b5d64ff391d1025a3fde1"
  end

  depends_on "lurepheonix/intel/pkgconf" => :build

  # Only add dependencies required for dependents in homebrew-core
  # or INCREDIBLY widely used and light codecs in the current year (2026).
  # Add other dependencies to ffmpeg-full formula.
  # We should expect to remove e.g. x264 eventually (>=2027) when usage of it is
  # negligible and has all moved to e.g. x265 instead.
  # brew-bottle-farm: qualify intra-queue deps to the farm-bottled copies
  # (single-sourced per install; see patches/README.md).
  # depends_on "dav1d"  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/dav1d"
  depends_on "lurepheonix/intel/lame"
  # brew-bottle-farm: qualify intra-queue deps to the farm-bottled copies
  # (single-sourced per install; see patches/README.md).
  # depends_on "libvmaf" # dependent: ab-av1  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/libvmaf" # dependent: ab-av1
  depends_on "lurepheonix/intel/libvpx"
  depends_on "lurepheonix/intel/openssl@4"
  depends_on "lurepheonix/intel/opus"
  depends_on "lurepheonix/intel/sdl2-compat"
  depends_on "lurepheonix/intel/svt-av1"
  depends_on "lurepheonix/intel/x264"
  depends_on "lurepheonix/intel/x265"
  depends_on "lurepheonix/intel/xz"

  uses_from_macos "bzip2"
  uses_from_macos "libxml2"

  on_linux do
    depends_on "alsa-lib"
    depends_on "libxcb"
    depends_on "zlib-ng-compat"
  end

  on_intel do
    depends_on "lurepheonix/intel/nasm" => :build
  end

  deny_network_access!

  def install
    # The new linker leads to duplicate symbol issue https://github.com/homebrew-ffmpeg/homebrew-ffmpeg/issues/140
    ENV.append "LDFLAGS", "-Wl,-ld_classic" if DevelopmentTools.ld64_version.between?("1015.7", "1022.1")

    # Fine adding any new options that don't add dependencies to the formula.
    args = %W[
      --prefix=#{prefix}
      --enable-shared
      --enable-pthreads
      --enable-version3
      --cc=#{ENV.cc}
      --host-cflags=#{ENV.cflags}
      --host-ldflags=#{ENV.ldflags}
      --enable-ffplay
      --enable-gpl
      --enable-libsvtav1
      --enable-libopus
      --enable-libx264
      --enable-libmp3lame
      --enable-libdav1d
      --enable-libvmaf
      --enable-libvpx
      --enable-libx265
      --enable-openssl
    ]

    # Needs corefoundation, coremedia, corevideo
    args += %w[--enable-videotoolbox --enable-audiotoolbox] if OS.mac?
    args << "--enable-neon" if Hardware::CPU.arm?

    system "./configure", *args
    system "make", "install"

    # Build and install additional FFmpeg tools
    system "make", "alltools"
    bin.install (buildpath/"tools").children.select { |f| f.file? && f.executable? }
    pkgshare.install buildpath/"tools/python"
  end

  def caveats
    <<~EOS
      ffmpeg-full includes additional tools and libraries that are not included in the regular ffmpeg formula.
    EOS
  end

  test do
    # Create a 5 second test MP4
    mp4out = testpath/"video.mp4"
    system bin/"ffmpeg", "-filter_complex", "testsrc=rate=1:duration=5", mp4out
    assert_path_exists mp4out, "Failed to create video.mp4!"
  end
end
