class Luv < Formula
  desc "Bare libuv bindings for lua"
  homepage "https://github.com/luvit/luv"
  url "https://github.com/luvit/luv/archive/refs/tags/1.53.0-0.tar.gz"
  sha256 "bd393b5918f320c79a2c6405e3abebe01c024557c32b9fb9006bee20ce71e19e"
  license "Apache-2.0"
  compatibility_version 1
  head "https://github.com/luvit/luv.git", branch: "master"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/luv-1.53.0-0"
    sha256 cellar: :any, sequoia: "fd0f56a0af9ef96ba2ddb3ef5257ab75a547d64daa6cb1f3efb898621f989a76"
  end

  depends_on "cmake" => :build
  depends_on "lua" => [:build, :test]
  depends_on "luajit" => [:build, :test]
  # brew-bottle-farm: qualify intra-queue dep to the farm-bottled copy
  # (single-sourced per install; see patches/README.md).
  # depends_on "libuv"  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/libuv"

  resource "lua-compat-5.3" do
    url "https://github.com/lunarmodules/lua-compat-5.3/archive/refs/tags/v0.15.1.tar.gz"
    sha256 "16c4bd7b72a156e3b575ce2b5ebe2ec00611a14c485dd15dc3814647a589c7f8"
  end

  deny_network_access!

  def lua
    Formula["lua"]
  end

  def install
    resource("lua-compat-5.3").stage buildpath/"deps/lua-compat-5.3" if build.stable?

    args = %W[
      -DWITH_SHARED_LIBUV=ON
      -DLUA_BUILD_TYPE=System
      -DLUA_COMPAT53_DIR=#{buildpath}/deps/lua-compat-5.3
      -DBUILD_MODULE=ON
    ]

    system "cmake", "-S", ".", "-B", "buildjit",
                    "-DWITH_LUA_ENGINE=LuaJIT",
                    "-DBUILD_STATIC_LIBS=ON",
                    "-DBUILD_SHARED_LIBS=ON",
                    *args, *std_cmake_args
    system "cmake", "--build", "buildjit"
    system "cmake", "--install", "buildjit"

    system "cmake", "-S", ".", "-B", "buildlua",
                    "-DWITH_LUA_ENGINE=Lua",
                    "-DBUILD_STATIC_LIBS=OFF",
                    "-DBUILD_SHARED_LIBS=OFF",
                    # https://github.com/luvit/luv/issues/787#issuecomment-4041758224
                    "-DMODULE_INSTALL_LIB_DIR=#{lib}/lua/#{lua.version.major_minor}",
                    *args, *std_cmake_args
    system "cmake", "--build", "buildlua"
    system "cmake", "--install", "buildlua"
  end

  test do
    (testpath/"test.lua").write <<~LUA
      local uv = require('luv')
      local timer = uv.new_timer()
      timer:start(1000, 0, function()
        print("Awake!")
        timer:close()
      end)
      print("Sleeping");
      uv.run()
    LUA

    expected = <<~EOS
      Sleeping
      Awake!
    EOS

    assert_equal expected, shell_output("luajit test.lua")
    assert_equal expected, shell_output("#{lua.bin}/lua test.lua")
  end
end
