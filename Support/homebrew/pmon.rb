# The Homebrew formula for pmon. This copy is the source: the Release workflow (Support/homebrew.sh)
# fills in the release's url and sha256, adds the bottle block and pushes it to kKEo/homebrew-tap.
class Pmon < Formula
  desc "Local macOS activity monitor: find what makes the machine sluggish"
  homepage "https://github.com/kKEo/macos-proc-monitor"
  url "https://github.com/kKEo/macos-proc-monitor/releases/download/v0.2.2/pmon-0.2.2.tar.gz"
  sha256 "900090d3e8c35874b3e44e525502159fdf8727168eeb7618c84620e8e32525ca"

  livecheck do
    url :stable
    strategy :github_latest
  end

  # The release archive holds prebuilt Apple Silicon binaries; pmon needs macOS 14 or later.
  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    bin.install "bin/pmon", "bin/pmond", "bin/pmon-menu", "bin/pmon-helper"
    doc.install "README.md", "DESIGN.md", "docs"
  end

  # Runs the collection daemon now and at every login. Data stays in
  # ~/Library/Application Support/pmon, whichever way pmon was installed.
  service do
    run opt_bin/"pmond"
    keep_alive true
    process_type :background
    log_path var/"log/pmond.log"
    error_log_path var/"log/pmond.log"
  end

  def caveats
    <<~EOS
      Start the daemon now and at every login:
        brew services start pmon

      If you installed pmon earlier with `pmon install` or install.sh, remove that copy
      first (your data is kept), or two daemons will compete:
        pmon uninstall

      Optional:
        pmon menu install              # menu-bar item, started at login
        sudo pmon helper install       # exact data for system processes

      pmon checks GitHub for a new release once a day; upgrade with `brew upgrade pmon`.
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/pmon --version").strip
    assert_match "usage: pmond", shell_output("#{bin}/pmond --help", 2)
  end
end
