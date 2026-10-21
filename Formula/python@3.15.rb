# python@3.15 (farm shim-keg) — NOT mirrored from homebrew/core. Authored here.
#
# Placeholder keg so formulae with `depends_on "farm/local/python@3.15"` resolve
# without core python (unpourable on Tier-3 guests). The keg only links the
# farm-toolchain shims into its own opt prefix, so brew's dep machinery
# (`python3` helper, `Keg.for`, `site_packages`, virtualenv) works unchanged
# against the provisioned external interpreter (uv first, asdf fallback).
#
# Version policy: version MUST equal the python@3.15 pin in build-deps.conf
# (bump together; consumers auto-queue on slot changes via patch headers).
# Requires farm-toolchain installed + provisioned BEFORE `brew install` here
# (orchestrate pre-installs after toolchain provision). The upstream tarball
# is fetched+verified but its content is unused (install only symlinks);
# pinning a real artifact keeps `brew install`/`brew fetch` honest.
#
# Consumers: meson, sphinx-doc, python-setuptools, certifi (via B1
# dep-qualify patches) — all build-time only; nothing runtime-links this.
class PythonAT315 < Formula
  desc "Farm shim-keg: stable cellar path for the external python@3.15 slot"
  homepage "https://github.com/<user>/brew-bottle-farm"
  url "https://www.python.org/ftp/python/3.15.0/Python-3.15.0.tar.xz"
  sha256 "ba4bed1ba346b916890b76d9e320451420aa69f6408997d33c66482eeae3d575"
  version "3.15.0"
  # Never link into HOMEBREW_PREFIX and never shadow anything: this keg exists
  # only so `depends_on "farm/local/python@3.15"` resolves; the shims do the work.
  keg_only "farm shim-keg for the external python@3.15 slot (see build-deps.conf)"

  # No depends_on: this formula must never pull brewed interpreters (it replaces one).

  def install
    # Pure path math (no Formula[] lookup): farm-toolchain is provisioned
    # before this installs (orchestrate ordering); a missing target fails
    # loud in `test` below, never silently.
    ft_bin = HOMEBREW_PREFIX/"opt"/"farm-toolchain"/"bin"
    bin.install_symlink ft_bin/"python3.15" => "python3.15"
    bin.install_symlink ft_bin/"python3.15" => "python3"
  end

  test do
    assert_match "3.15", shell_output("#{bin}/python3.15 --version")
  end
end
