# ruby (farm shim-keg) — NOT mirrored from homebrew/core. Authored here.
#
# Placeholder keg so formulae with `depends_on "farm/local/ruby"` resolve
# without core ruby (unpourable on Tier-3 guests). The keg links the
# asdf-installed ruby directly (resolved at install time, so no user name is
# baked into the repo): this avoids the asdf shim chain inside brew builds
# (version-file walks + helper env that die silently under superenv/sandbox).
#
# Version policy: version MUST equal the ruby pin in build-deps.conf
# (bump together; consumers auto-queue on slot changes via patch headers).
# Requires the asdf ruby installed BEFORE `brew install` here (toolchain
# provision; orchestrate pre-installs after provision). The upstream tarball
# is fetched+verified but its content is unused (install only symlinks).
#
# Consumers: asciidoctor (via B1 dep-qualify patch) — build-time only.
class Ruby < Formula
  desc "Farm shim-keg: stable cellar path for the external ruby slot"
  homepage "https://github.com/<user>/brew-bottle-farm"
  url "https://cache.ruby-lang.org/pub/ruby/4.0/ruby-4.0.7.tar.gz"
  sha256 "911ace20f90d068ca0e4dda6d0e4f0f81e52e52f2dd4f4004c721e253412e82d"
  version "4.0.7"
  # Never link into HOMEBREW_PREFIX and never shadow core ruby: this keg exists
  # only so `depends_on "farm/local/ruby"` resolves; the shim does the work.
  keg_only "farm shim-keg for the external ruby slot (see build-deps.conf)"

  # No depends_on: this formula must never pull brewed interpreters (it replaces one).

  def install
    # Direct symlinks (see header): Etc.getpwuid bypasses brew's sandbox
    # $HOME redirection (Dir.home points at a deleted build temp); a missing
    # asdf ruby fails loud in `test` below, never silently.
    require "etc"
    asdf_ruby = Pathname(Etc.getpwuid.dir)/".asdf/installs/ruby/#{version}/bin"
    bin.install_symlink asdf_ruby/"ruby" => "ruby"
    bin.install_symlink asdf_ruby/"gem" => "gem"
  end

  test do
    assert_match "4.0.7", shell_output("#{bin}/ruby --version")
  end
end
