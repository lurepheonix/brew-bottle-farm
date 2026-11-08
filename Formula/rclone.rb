class Rclone < Formula
  desc "Rsync for cloud storage"
  homepage "https://rclone.org/"
  url "https://github.com/rclone/rclone/archive/refs/tags/v1.76.0.tar.gz"
  sha256 "8cb7e5d576fe9a3aef8b1a0785e2ffc6c1953f8ed109f42000b0b86718f6628b"
  license "MIT"
  compatibility_version 1
  head "https://github.com/rclone/rclone.git", branch: "master"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/rclone-1.76.0"
    sha256 cellar: :any_skip_relocation, sequoia: "49148da0be4cdc2560fe7d9620ab1ca83dba29f5b8951b96a1527a429c207b10"
  end

  # brew-bottle-farm: external go 1.27.3 (build-deps.conf). Requires toolchain go on PATH.
  # depends_on "go" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain go is visible (superenv would scrub PATH)

  deny_network_access!

  def fetch
    system "go", "mod", "download"
  end

  def install
    ldflags = %W[-X github.com/rclone/rclone/fs.Version=v#{version}]
    tags = "brew" if OS.mac?
    system "go", "build", *std_go_args(ldflags:, tags:)
    man1.install "rclone.1"
    system bin/"rclone", "genautocomplete", "bash", "rclone.bash"
    system bin/"rclone", "genautocomplete", "zsh", "_rclone"
    system bin/"rclone", "genautocomplete", "fish", "rclone.fish"
    bash_completion.install "rclone.bash" => "rclone"
    zsh_completion.install "_rclone"
    fish_completion.install "rclone.fish"
  end

  def caveats
    <<~EOS
      Homebrew's installation does not include the `mount` subcommand on macOS which depends on FUSE, use `nfsmount` instead.
    EOS
  end

  test do
    (testpath/"file1.txt").write "Test!"
    system bin/"rclone", "copy", testpath/"file1.txt", testpath/"dist"
    assert_match File.read(testpath/"file1.txt"), File.read(testpath/"dist/file1.txt")
  end
end
