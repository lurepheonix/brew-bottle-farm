class Libdatrie < Formula
  desc "Double-Array Trie Library"
  homepage "https://github.com/tlwg/libdatrie"
  url "https://github.com/tlwg/libdatrie/releases/download/v0.2.14/libdatrie-0.2.14.tar.xz"
  sha256 "f04095010518635b51c2313efa4f290b7db828d6273e39b2b8858f859dfe81d5"
  license "LGPL-2.1-or-later"
  compatibility_version 1

  bottle do
    root_url "https://github.com/lurepheonix/homebrew-intel/releases/download/libdatrie-0.2.14"
    sha256 cellar: :any, sequoia: "82ca42f782e664c07ca258983eb370f6afcf740ac533063df9704142b079dfbf"
  end

  depends_on "lurepheonix/intel/pkgconf" => :build

  deny_network_access!

  def install
    system "./configure", "--enable-shared", *std_configure_args
    system "make"
    system "make", "install-exec"
    system "make", "install"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/trietool --version", 1)
    assert_match "Cannot open alphabet map file ./list.abm", shell_output("#{bin}/trietool list 2>&1", 1)

    (testpath/"test.abm").write <<~EOF
      [0x0061,0x007a]
    EOF
    (testpath/"test.txt").write <<~TEXT
      foo\t1
      bar\t1
    TEXT
    system "#{bin}/trietool", "test", "add-list", "test.txt"

    (testpath/"test.c").write <<~C
      #include <datrie/trie.h>
      #include <stdio.h>
      int main() {
        Trie *trie = trie_new_from_file("test.tri");
        if (trie == NULL) {
          return 1;
        }
        return 0;
      }
    C

    system ENV.cc, "test.c", "-I#{include}", "-L#{lib}", "-ldatrie", "-o", "test"
    system "./test"
  end
end
