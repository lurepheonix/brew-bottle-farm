class Duf < Formula
  desc "Disk Usage/Free Utility - a better 'df' alternative"
  homepage "https://github.com/muesli/duf"
  url "https://github.com/muesli/duf/archive/refs/tags/v0.9.1.tar.gz"
  sha256 "1334d8c1a7957d0aceebe651e3af9e1c1e0c6f298f1feb39643dd0bd8ad1e955"
  license "MIT"
  head "https://github.com/muesli/duf.git", branch: "master"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/duf-0.9.1"
    sha256 cellar: :any_skip_relocation, sequoia: "394005ff5f63381b6e5c3e44b2a687f22f6b158f34a0d4a9d405327a459753b9"
  end

  # brew-bottle-farm: external go 1.27.3 (build-deps.conf). Requires toolchain go on PATH.
  # depends_on "go" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain go is visible (superenv would scrub PATH)

  deny_network_access!

  def fetch
    system "go", "mod", "download"
  end

  def install
    system "go", "build", *std_go_args
  end

  test do
    devices = JSON.parse shell_output("#{bin}/duf --json")
    assert root = devices.find { |d| d["mount_point"] == "/" }
    assert_equal "local", root["device_type"]
  end
end
