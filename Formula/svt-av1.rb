class SvtAv1 < Formula
  desc "AV1 encoder"
  homepage "https://gitlab.com/AOMediaCodec/SVT-AV1"
  url "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.3.0/SVT-AV1-v4.3.0.tar.bz2"
  sha256 "9223ce06e6172ad41357ed23b3b00f036e03794b86b0e20ea9ccb3f648b8955d"
  license "BSD-3-Clause"
  compatibility_version 1
  head "https://gitlab.com/AOMediaCodec/SVT-AV1.git", branch: "master"

  livecheck do
    url :stable
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/svt-av1-4.3.0"
    sha256 cellar: :any, sequoia: "9df865f09a5dd3cccca86caea03741689dc1661a731de64692a3d7cf7a9d3416"
  end

  depends_on "lurepheonix/intel/cmake" => :build

  on_intel do
    depends_on "lurepheonix/intel/nasm" => :build
  end

  resource "homebrew-testvideo", :test do
    url "https://github.com/grusell/svt-av1-homebrew-testdata/raw/main/video_64x64_yuv420p_25frames.yuv"
    sha256 "0c5cc90b079d0d9c1ded1376357d23a9782a704a83e01731f50ccd162e246492"
  end

  allow_network_access! :test

  def install
    # Features are enabled based on compiler support, and then the appropriate
    # implementations are chosen at runtime.
    # See https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Source/Lib/Codec/common_dsp_rtcd.c
    ENV.runtime_cpu_detection

    system "cmake", "-S", ".", "-B", "build", "-DCMAKE_INSTALL_RPATH=#{rpath}", *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  test do
    testpath.install resource("homebrew-testvideo")
    system bin/"SvtAv1EncApp", "-w", "64", "-h", "64", "-i", "video_64x64_yuv420p_25frames.yuv", "-b", "output.ivf"
    assert_path_exists testpath/"output.ivf"
  end
end
