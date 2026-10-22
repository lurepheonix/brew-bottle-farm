class PythonSetuptools < Formula
  desc "Easily download, build, install, upgrade, and uninstall Python packages"
  homepage "https://setuptools.pypa.io/"
  url "https://files.pythonhosted.org/packages/70/b3/c19426f783614d625699a4b247faf628ea9ab1db228674491767b417f9e1/setuptools-84.2.1.tar.gz"
  sha256 "3ff8b3b5492a0aa66960f4419365a86b84e013070d4313e4d4a6894f5d64d6bc"
  license "MIT"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/python-setuptools-84.2.1"
    sha256 cellar: :any_skip_relocation, sequoia: "485410d820a2f85489ab40d2b6e4a5e18ed3fdc519dfca89591ea11bad400edb"
  end

  # brew-bottle-farm: core python unpourable on Tier-3 guests; use the farm
  # shim-keg (pinned uv/asdf interpreter via farm-toolchain shims).
  # depends_on "python@3.15" => [:build, :test]  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/python@3.15" => [:build, :test]
  env :std  # passthrough env so the toolchain python/pip are visible (superenv would scrub PATH)

  deny_network_access!

  def install
    system python3, "-m", "pip", "install", *std_pip_args, "."

    # brew-bottle-farm: multi-python symlinks dropped (single 3.15 slot on the farm).
    site_packages = prefix/Language::Python.site_packages(python3)

    # Ensure uniform bottles
    setuptools_site_packages = site_packages/"setuptools"
    inreplace_files = %W[
      #{setuptools_site_packages}/_distutils/compilers/C/unix.py
      #{setuptools_site_packages}/_vendor/platformdirs/unix.py
    ] + setuptools_site_packages.glob("_vendor/platformdirs-*dist-info/METADATA")
    inreplace inreplace_files, "/usr/local", HOMEBREW_PREFIX
  end

  test do
    system python3, "-c", "import setuptools"

    # Check that the wheel is safe to use on all pythons
    wheel = prefix/Language::Python.site_packages(python3)/"setuptools-#{version}.dist-info/WHEEL"
    assert_match(/^Tag: py3-none-any$/, wheel.read)
  end
end
