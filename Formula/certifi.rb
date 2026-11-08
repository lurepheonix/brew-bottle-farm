class Certifi < Formula
  desc "Mozilla CA bundle for Python"
  homepage "https://github.com/certifi/python-certifi"
  url "https://files.pythonhosted.org/packages/fd/11/b524cbd9bbdaca58608e4cf4053fd463417549e1959fa8d3aa18319f9555/certifi-2026.10.23.tar.gz"
  sha256 "a9895e6e2758b371e0545e321a3a8fd1fcfd9829ada8824a936dfb16aaaf36cd"
  license "MPL-2.0"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/certifi-2026.10.23"
    sha256 cellar: :any_skip_relocation, sequoia: "808e0911e0cd63a286ef7df2ee2db6f45aa5b245b9d17d16650106ca9d2a0d32"
  end

  # brew-bottle-farm: qualify intra-queue dep to the farm-bottled copy.
  # Unqualified names can resolve to core, yielding two objects for one rack
  # (core + farm) — brew locks per rack and deadlocks itself (flock NB fails
  # on its own held lock). Single-sourcing per install avoids it.
  # depends_on "python-setuptools" => :build  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/python-setuptools" => :build
  # brew-bottle-farm: core python unpourable on Tier-3 guests; use the farm
  # shim-keg (pinned uv/asdf interpreter via farm-toolchain shims).
  # depends_on "python@3.15" => [:build, :test]  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/python@3.15" => [:build, :test]
  env :std  # passthrough env so the toolchain python/pip are visible (superenv would scrub PATH)
  depends_on "lurepheonix/intel/ca-certificates" => :no_linkage

  deny_network_access!

  def install
    system python3, "-m", "pip", "install", *std_pip_args, "."

    # brew-bottle-farm: multi-python symlinks dropped (single 3.15 slot on the farm).
    site_packages = prefix/Language::Python.site_packages(python3)
    rm site_packages/"certifi/cacert.pem"
    (site_packages/"certifi").install_symlink Formula["lurepheonix/intel/ca-certificates"].pkgetc/"cert.pem" => "cacert.pem"
  end

  test do
    output = shell_output("#{python3} -m certifi").chomp
    assert_equal Formula["lurepheonix/intel/ca-certificates"].pkgetc/"cert.pem", Pathname(output).realpath

    # Check that the wheel is safe to use on all pythons
    wheel = prefix/Language::Python.site_packages(python3)/"certifi-#{version}.dist-info/WHEEL"
    assert_match(/^Tag: py3-none-any$/, wheel.read)
  end
end
