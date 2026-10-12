# Homebrew cask template for BetterDock. release/publish.sh fills in the version and sha256 and writes
# the result to the release output folder (and, with --tap, to Bilal-Bjo/homebrew-tap Casks/betterdock.rb).
cask "betterdock" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/Bilal-Bjo/betterdock/releases/download/v#{version}/BetterDock-#{version}.dmg"
  name "BetterDock"
  desc "Lightweight Dock replacement with app folders, widgets and agent status"
  homepage "https://github.com/Bilal-Bjo/betterdock"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "BetterDock.app"

  uninstall quit: "com.betterdock.app"

  zap trash: [
    "~/Library/Application Support/BetterDock",
    "~/Library/Caches/com.betterdock.app",
    "~/Library/HTTPStorages/com.betterdock.app",
    "~/Library/Preferences/com.betterdock.app.plist",
  ]
end
