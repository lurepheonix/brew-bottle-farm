class Shfmt < Formula
  desc "Autoformat shell script source code"
  homepage "https://github.com/mvdan/sh"
  url "https://github.com/mvdan/sh/archive/refs/tags/v3.14.1.tar.gz"
  sha256 "ec4bdb88ab6c95686be3a4eeb4ad77d2b49d33d2ed7b0a65035cd52d2d87c443"
  license "BSD-3-Clause"
  head "https://github.com/mvdan/sh.git", branch: "master"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/shfmt-3.14.1"
    sha256 cellar: :any_skip_relocation, sequoia: "7841ff0f225837c9dd78b3014a11977fc77b43b18950efece98bd453ba82be77"
  end

  # brew-bottle-farm: external go 1.27.3 (build-deps.conf). Requires toolchain go on PATH.
  # depends_on "go" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain go is visible (superenv would scrub PATH)
  depends_on "lurepheonix/intel/scdoc" => :build

  deny_network_access!

  def fetch
    system "go", "mod", "download"
  end

  def install
    ENV["CGO_ENABLED"] = "0"
    inreplace "cmd/shfmt/main.go", "version = mod.Version", "version = \"#{version}\""
    system "go", "build", *std_go_args(ldflags: "-extldflags=-static"), "./cmd/shfmt"
    man1.mkpath
    system "scdoc < ./cmd/shfmt/shfmt.1.scd > #{man1}/shfmt.1"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/shfmt --version")

    (testpath/"test").write "\t\techo foo"
    system bin/"shfmt", testpath/"test"
  end
end
