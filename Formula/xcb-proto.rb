class XcbProto < Formula
  desc "X.Org: XML-XCB protocol descriptions for libxcb code generation"
  homepage "https://www.x.org/"
  url "https://xorg.freedesktop.org/archive/individual/proto/xcb-proto-1.17.0.tar.xz"
  sha256 "2c1bacd2110f4799f74de6ebb714b94cf6f80fb112316b1219480fd22562148c"
  license "MIT"
  revision 1
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/xcb-proto-1.17.0"
    sha256 cellar: :any_skip_relocation, sequoia: "32d46640b74e763f32b2566940f8b3b19f07942a1d2f53cf899fbc207bf65394"
  end

  depends_on "lurepheonix/intel/pkgconf" => [:build, :test]
  # brew-bottle-farm: core python unpourable on Tier-3 guests; use the farm
  # shim-keg (pinned uv/asdf interpreter via farm-toolchain shims).
  # depends_on "python@3.15" => [:build, :test]  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/python@3.15" => [:build, :test]
  env :std  # passthrough env so the toolchain python/pip are visible (superenv would scrub PATH)

  deny_network_access!

  def install
    args = %W[
      --prefix=#{prefix}
      --sysconfdir=#{etc}
      --localstatedir=#{var}
      --disable-silent-rules
      PYTHON=#{python3}
    ]

    system "./configure", *args
    system "make"
    system "make", "install"
  end

  test do
    assert_match "#{share}/xcb", shell_output("pkg-config --variable=xcbincludedir xcb-proto").chomp
    system python3, "-c", <<~PYTHON
      import collections
      output = collections.defaultdict(int)
      from xcbgen import xtypes
    PYTHON
  end
end
