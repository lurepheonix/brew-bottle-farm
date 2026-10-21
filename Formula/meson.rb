class Meson < Formula
  desc "Fast and user friendly build system"
  homepage "https://mesonbuild.com/"
  url "https://github.com/mesonbuild/meson/releases/download/1.12.1/meson-1.12.1.tar.gz"
  sha256 "ab0a6ca09f8ef70c564c8241fb5a23957886a0b53fb58412b5e07eaf07dba743"
  license "Apache-2.0"
  head "https://github.com/mesonbuild/meson.git", branch: "master"

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/meson-1.12.1"
    sha256 cellar: :any_skip_relocation, sequoia: "b0ed057636c1ac88712719df76721e037f4f3136803d65f5c43fd8f6e0450b65"
  end

  depends_on "ninja"
  # brew-bottle-farm: core python unpourable on Tier-3 guests; use the farm
  # shim-keg (pinned uv/asdf interpreter via farm-toolchain shims).
  # depends_on "python@3.15"  # disabled — see patches/README.md
  depends_on "lurepheonix/intel/python@3.15"
  env :std  # passthrough env so the toolchain python/pip are visible (superenv would scrub PATH)

  def install
    system python3, "-m", "pip", "install", *std_pip_args(build_isolation: true), "."

    # brew-bottle-farm: wrap bin/meson with PYTHONPATH so the keg's
    # site-packages resolves under the external interpreter (pip --prefix
    # layout ships no .pth into the toolchain python). Slot-coupled (3.15):
    # refresh with the slot.
    libexec.install bin/"meson"
    (bin/"meson").write <<~EOS
      #!/bin/sh
      export PYTHONPATH="#{prefix}/lib/python3.15/site-packages${PYTHONPATH:+:$PYTHONPATH}"
      exec "#{Formula["lurepheonix/intel/python@3.15"].opt_bin}/python3.15" "#{libexec}/meson" "$@"
    EOS
    chmod 0755, bin/"meson"

    bash_completion.install "data/shell-completions/bash/meson"
    zsh_completion.install "data/shell-completions/zsh/_meson"
    vim_plugin_dir = buildpath/"data/syntax-highlighting/vim"
    (share/"vim/vimfiles").install %w[ftdetect ftplugin indent syntax].map { |dir| vim_plugin_dir/dir }

    # Make the bottles uniform. This also ensures meson checks `HOMEBREW_PREFIX`
    # for fulfilling dependencies rather than just `/usr/local`.
    mesonbuild = prefix/Language::Python.site_packages(python3)/"mesonbuild"
    usr_local_files = %w[
      compilers/mixins/apple.py
      coredata.py
      dependencies/boost.py
      dependencies/cuda.py
      dependencies/misc.py
      dependencies/qt.py
      mdevenv.py
      options.py
      scripts/python_info.py
      utils/universal.py
    ].map { |f| mesonbuild/f }
    usr_local_files << (bash_completion/"meson")

    # Passing `build.stable?` ensures a failed `inreplace` won't fail HEAD installs.
    inreplace usr_local_files, "/usr/local", HOMEBREW_PREFIX, audit_result: build.stable?

    opt_homebrew_files = %w[
      dependencies/boost.py
      dependencies/misc.py
      compilers/mixins/apple.py
    ].map { |f| mesonbuild/f }
    inreplace opt_homebrew_files, "/opt/homebrew", HOMEBREW_PREFIX, audit_result: build.stable?

    # Ensure meson uses our `var` directory.
    inreplace mesonbuild/"options.py", "'/var/local", "'#{var}", audit_result: build.stable?
  end

  test do
    (testpath/"helloworld.c").write <<~C
      #include <stdio.h>
      int main(void) {
        puts("hi");
        return 0;
      }
    C
    (testpath/"meson.build").write <<~MESON
      project('hello', 'c')
      executable('hello', 'helloworld.c')
    MESON

    system bin/"meson", "setup", "build"
    assert_path_exists testpath/"build/build.ninja"

    system bin/"meson", "compile", "-C", "build", "--verbose"
    assert_equal "hi", shell_output("build/hello").chomp
  end
end
