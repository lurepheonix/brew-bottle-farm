# swift (farm shim-keg) — NOT mirrored from homebrew/core. Authored here.
#
# Placeholder keg so formulae with `depends_on "farm/local/swift"` resolve
# without brewing the swift formula (an LLVM-scale source build). The keg only
# links the provisioned external toolchain (official swift.org macOS xctoolchain,
# extracted user-local) into its own opt prefix, so brew's dep machinery works
# unchanged.
#
# Version policy: version MUST equal the swift pin in build-deps.conf
# (bump together; consumers auto-queue on slot changes via patch headers).
# Requires the toolchain payload root provisioned BEFORE `brew install` here at
# ${TOOLCHAIN_PREFIX:-~/.local}/swift-<version> (orchestrate pre-installs after
# toolchain provision). The upstream .pkg
# is fetched+verified (brew caches it, so the ~1GB download happens once per
# snapshot) but its content is unused (install only symlinks); pinning a real
# artifact keeps `brew install`/`brew fetch` honest.
#
# Consumers: mist-cli (via B1 dep-qualify patch) — build-time only; nothing
# runtime-links this.
class Swift < Formula
  desc "Farm shim-keg: stable cellar path for the external swift slot"
  homepage "https://github.com/<user>/brew-bottle-farm"
  url "https://download.swift.org/swift-6.4.1-release/xcode/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE-osx.pkg"
  sha256 "c34e7e5fb0be4bcd61decfd40db1766434d8952d68e37aed90bcff4e8547951c"
  version "6.4.1"
  # Never link into HOMEBREW_PREFIX and never shadow anything: this keg exists
  # only so `depends_on "farm/local/swift"` resolves; the toolchain does the work.
  keg_only "farm shim-keg for the external swift slot (see build-deps.conf)"

  # No depends_on: this formula must never pull brewed toolchains (it replaces one).

  def install
    # Pure path math (no Formula[] lookup): the toolchain payload root is
    # provisioned before this installs (orchestrate ordering); a missing
    # toolchain fails loud in `test` below, never silently.
    swift_bin = Pathname(ENV["TOOLCHAIN_PREFIX"] || Pathname(Etc.getpwuid.dir)/".local")/"swift-#{version}"/"usr"/"bin"
    Pathname.glob(swift_bin/"*").each do |f|
      next unless f.file? && f.executable?
      bin.install_symlink f
    end
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/swift --version")
  end
end
