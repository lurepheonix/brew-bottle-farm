class Certifi < Formula
  desc "Mozilla CA bundle for Python"
  homepage "https://github.com/certifi/python-certifi"
  url "https://files.pythonhosted.org/packages/51/33/4cd27639502f010084bcef7a2036391dd637439901341ce1a530f36f6e51/certifi-2026.11.20.tar.gz"
  sha256 "af1cb240a8133f105aa52684a3a3258339d7f2fd0bd4e2812698ff5cf5588c4e"
  license "MPL-2.0"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/certifi-2026.11.20"
    sha256 cellar: :any_skip_relocation, sequoia: "1c129f87fdf29ad9cb32691fea4a13e36b330dbc68e905e05a75afe01ec1ae6c"
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

    # Use brewed ca-certificates PEM file instead of the bundled copy
    site_packages = prefix/Language::Python.site_packages(python3)
    rm site_packages/"certifi/cacert.pem"
    (site_packages/"certifi").install_symlink Formula["lurepheonix/intel/ca-certificates"].pkgetc/"cert.pem" => "cacert.pem"

    # brew-bottle-farm: multi-python symlinks dropped (single 3.15 slot on the farm).
  end

  test do
    output = shell_output("#{python3} -m certifi").chomp
    assert_equal Formula["lurepheonix/intel/ca-certificates"].pkgetc/"cert.pem", Pathname(output).realpath

    # Check that the wheel is safe to use on all pythons
    wheel = prefix/Language::Python.site_packages(python3)/"certifi-#{version}.dist-info/WHEEL"
    assert_match(/^Tag: py3-none-any$/, wheel.read)
  end
end
