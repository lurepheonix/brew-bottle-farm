class GnuGetopt < Formula
  desc "Command-line option parsing utility"
  homepage "https://github.com/util-linux/util-linux"
  url "https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.4.tar.gz"
  sha256 "af3241e7776964dcb6bb9a811ca7b0d93000b563e2ae2a8df8f80a7cd6e04d56"
  license "GPL-2.0-or-later"
  compatibility_version 1

  livecheck do
    url "https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/"
    regex(/href=.*?util-linux[._-]v?(\d+(?:\.\d+)+)\.t/i)
    strategy :page_match do |page, regex|
      # Match versions from directories
      versions = page.scan(%r{href=["']?v?(\d+(?:\.\d+)+)/?["' >]}i)
                     .flatten
                     .uniq
                     .sort_by { |v| Version.new(v) }
      next versions if versions.blank?

      # Check the highest version, falling back to the second-highest version
      # if no matching versions are found in the version directory (e.g.,
      # upstream has created a version directory using a stable version format
      # but the version directory only contained unstable versions).
      dir_versions = []
      versions[-2..].reverse_each do |version|
        # Fetch the page for the version directory
        dir_page = Homebrew::Livecheck::Strategy.page_content(
          URI.join(@url, "v#{version}/").to_s,
        )
        next versions if dir_page[:content].blank?

        # Identify versions from files in the version directory
        dir_versions = dir_page[:content].scan(regex).flatten
        break unless dir_versions.empty?
      end

      dir_versions.presence || versions
    end
  end

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/gnu-getopt-2.42.4"
    sha256 cellar: :any, sequoia: "870f06572ec8dfaa12af8c7980a804c03bd55fa7c6e6f9e9aa30341e7f0ad4b4"
  end

  keg_only :shadowed_by_macos, "macOS provides BSD getopt"

  on_linux do
    keg_only "it conflicts with util-linux"
  end

  # Fix macOS builds
  patch do
    url "https://github.com/util-linux/util-linux/commit/d22edc2f100eb8dd83d3515758565cb73b0d2eed.patch?full_index=1"
    sha256 "2fb01154faa3fd8b0fce27eb88049ed9c8f839e706e412399c19c087f7f3b5e1"
    type :unofficial
    resolves "https://github.com/util-linux/util-linux/pull/4173"
  end

  deny_network_access!

  def install
    system "./configure", "--disable-silent-rules",
                          "--disable-liblastlog2",
                          *std_configure_args

    system "make", "getopt", "misc-utils/getopt.1"

    bin.install "getopt"
    man1.install "misc-utils/getopt.1"
    bash_completion.install "bash-completion/getopt"
    doc.install "misc-utils/getopt-example.bash", "misc-utils/getopt-example.tcsh"
  end

  test do
    output = shell_output("#{bin}/getopt --longoptions foo --options ab:c test -b bar --foo baz")
    assert_equal " -b 'bar' --foo -- 'test' 'baz'\n", output
    # Check that getopt is enhanced
    assert_empty shell_output("#{bin}/getopt --test", 4)
  end
end
