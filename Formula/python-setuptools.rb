class PythonSetuptools < Formula
  desc "Easily download, build, install, upgrade, and uninstall Python packages"
  homepage "https://setuptools.pypa.io/"
  url "https://files.pythonhosted.org/packages/63/40/e2c41d00a4bfea5548c31420a74c6cf149cc0e7c36b45c4c82202ce867aa/setuptools-84.2.0.tar.gz"
  sha256 "6f445ca2ce864605f81e223f262b4c94ffcb9a4a63473bae0ed7be5aab0291da"
  license "MIT"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/python-setuptools-84.2.0"
    sha256 cellar: :any_skip_relocation, sequoia: "b0e0f8ff79d105a5e642e9e1c2fb006db2cd8bab32c21ed3106d3269654b2028"
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
