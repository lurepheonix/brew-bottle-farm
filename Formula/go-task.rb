class GoTask < Formula
  desc "Task is a task runner/build tool that aims to be simpler and easier to use"
  homepage "https://taskfile.dev/"
  url "https://github.com/go-task/task/archive/refs/tags/v3.54.0.tar.gz"
  sha256 "d9e92770c2c18f135701431d04bb24fb77b5f13464699683892bdfc0b26f2eb8"
  license "MIT"
  head "https://github.com/go-task/task.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/go-task-3.54.0"
    sha256 cellar: :any_skip_relocation, sequoia: "084ecdb89a374bdef4a50c8e96ddf6f55a41181277e99f3ce166a7f1cada9edd"
  end

  # brew-bottle-farm: external go 1.27.3 (build-deps.conf). Requires toolchain go on PATH.
  # depends_on "go" => :build  # disabled — see patches/README.md
  env :std  # passthrough env so toolchain go is visible (superenv would scrub PATH)

  conflicts_with "task", because: "both install `task` binaries"

  deny_network_access!

  def fetch
    system "go", "mod", "download"
  end

  def install
    ldflags = %W[
      -X github.com/go-task/task/v3/internal/version.version=#{version}
      -X github.com/go-task/task/v3/internal/version.sum=#{tap.user}
    ]
    system "go", "build", *std_go_args(ldflags:, output: bin/"task"), "./cmd/task"
    bash_completion.install "completion/bash/task.bash" => "task"
    zsh_completion.install "completion/zsh/_task"
    fish_completion.install "completion/fish/task.fish"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/task --version")

    (testpath/"Taskfile.yml").write <<~YAML
      version: '3'

      tasks:
        test:
          cmds:
            - echo 'Testing Taskfile'
    YAML

    output = shell_output("#{bin}/task --silent test")
    assert_match "Testing Taskfile", output
  end
end
