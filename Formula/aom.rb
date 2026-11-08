class Aom < Formula
  desc "Codec library for encoding and decoding AV1 video streams"
  homepage "https://aomedia.googlesource.com/aom"
  url "https://aomedia.googlesource.com/aom.git",
      tag:      "v3.15.3",
      revision: "b141d9c45db236335351c8a4b2a14b3ade27c937"
  license "BSD-2-Clause"
  compatibility_version 1
  head "https://aomedia.googlesource.com/aom.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/aom-3.15.3"
    sha256 cellar: :any, sequoia: "5abcedb388788117c87170be28486d94cf9c2beefa1edbc2d28ba8ddea0b26e3"
  end

  depends_on "lurepheonix/intel/cmake" => :build
  depends_on "lurepheonix/intel/pkgconf" => :build
  # brew-bottle-farm: qualify intra-queue dep to the farm-bottled copy
  # (single-sourced per install; see patches/README.md).
  # depends_on "libvmaf"  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/libvmaf"

  on_intel do
    depends_on "lurepheonix/intel/nasm" => :build
  end

  resource "homebrew-bus_qcif_15fps.y4m", :test do
    url "https://media.xiph.org/video/derf/y4m/bus_qcif_15fps.y4m"
    sha256 "868fc3446d37d0c6959a48b68906486bd64788b2e795f0e29613cbb1fa73480e"
  end

  allow_network_access! :test

  def install
    ENV.runtime_cpu_detection

    # TODO: report upstream
    # `snprintf` gets the whole buffer size as `cur` advances, aborting under `_FORTIFY_SOURCE`
    inreplace "common/webmenc.cc",
              "snprintf(cur, total_size,",
              "snprintf(cur, total_size - (cur - result),"

    args = %W[
      -DCMAKE_INSTALL_RPATH=#{rpath}
      -DENABLE_DOCS=OFF
      -DENABLE_EXAMPLES=ON
      -DENABLE_TESTDATA=OFF
      -DENABLE_TESTS=OFF
      -DENABLE_TOOLS=OFF
      -DBUILD_SHARED_LIBS=ON
      -DCONFIG_TUNE_VMAF=1
    ]

    system "cmake", "-S", ".", "-B", "brewbuild", *args, *std_cmake_args
    system "cmake", "--build", "brewbuild"
    system "cmake", "--install", "brewbuild"
  end

  test do
    testpath.install resource("homebrew-bus_qcif_15fps.y4m")

    system bin/"aomenc", "--webm",
                         "--tile-columns=2",
                         "--tile-rows=2",
                         "--cpu-used=8",
                         "--output=bus_qcif_15fps.webm",
                         "bus_qcif_15fps.y4m"

    system bin/"aomdec", "--output=bus_qcif_15fps_decode.y4m",
                         "bus_qcif_15fps.webm"
  end
end
