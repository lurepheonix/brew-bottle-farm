class Certifi < Formula
  desc "Mozilla CA bundle for Python"
  homepage "https://github.com/certifi/python-certifi"
  url "https://files.pythonhosted.org/packages/a6/bd/1436c50cc46699de0230fbaacc1d1de7bfec413176099949e9d5112e88f2/certifi-2026.10.19.tar.gz"
  sha256 "035c1e85572b141bf1c3a3eff0e33a8eb74917522f2559075ff8d2fea780a1ae"
  license "MPL-2.0"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/certifi-2026.10.19"
    sha256 cellar: :any_skip_relocation, sequoia: "eae9ab0372491612bcbf7ebb5f724eb1b5b6bd2bbb68ee1179aff84cbbc0aed5"
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
