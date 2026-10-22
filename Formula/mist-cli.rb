class MistCli < Formula
  desc "Mac command-line tool that automatically downloads macOS Firmwares / Installers"
  homepage "https://github.com/ninxsoft/mist-cli"
  url "https://github.com/ninxsoft/mist-cli/archive/refs/tags/v2.3.tar.gz"
  sha256 "734bf8305a0005af2032a948689ca66352bcbe99e3779464db3607c17f3d9348"
  license "MIT"
  head "https://github.com/ninxsoft/mist-cli.git", branch: "main"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/mist-cli-2.3"
    sha256 cellar: :any_skip_relocation, sequoia: "0d873d84cee0337ea067ec1c2b817f850787a8df2395a44905d444d15471241d"
  end

  depends_on :macos

  # brew-bottle-farm: system swift is too old on sequoia (needs 6.3.1+);
  # brewing the swift formula is an LLVM-scale build. Use the farm external.
  # uses_from_macos "swift" => :build, since: :tahoe # disabled — see patches/README.md
  depends_on "lurepheonix/intel/swift" => :build
  env :std # passthrough env so the toolchain swift is visible (superenv would scrub it)

  on_sonoma :or_older do
    depends_on xcode: ["16.0", :build] # need 15.0+ SDK for __swift_nonisolated_unsafe on __stdoutp
  end

  deny_network_access!

  def fetch
    # SwiftPM tries to apply its own sandbox, which cannot nest inside the
    # build sandbox; Homebrew's sandbox still confines the whole process.
    system "swift", "package", "resolve", "--disable-sandbox"
  end

  def install
    # brew pins SDKROOT/CPATH at the stale CLT SDK even under env :std;
    # the swift driver then mixes CLT headers into Xcode SDK modules and dies.
    ENV.delete("SDKROOT")
    ENV.delete("CPATH")
    system "swift", "build", *std_swift_args
    bin.install ".build/release/mist"
    generate_completions_from_executable(bin/"mist", "--generate-completion-script")
  end

  test do
    # basic usage output
    assert_match "-h, --help", shell_output("#{bin}/mist").strip

    # check we can export the output list
    out = testpath/"out.json"
    system bin/"mist", "list", "firmware", "--quiet", "--export=#{out}", "--output-type=json"
    assert_path_exists out

    # check that it's parseable JSON in the format we expect
    parsed = JSON.parse(File.read(out))
    assert_kind_of Array, parsed
  end
end
