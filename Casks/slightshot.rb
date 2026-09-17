cask "slightshot" do
  version "1.0.2"
  sha256 "4002b20a7aa7c4989fa4b9ca4b11e4add34b4a6df7f33debed8ca321e3f798bb"

  url "https://github.com/jmpijll/slightshot/releases/download/v#{version}/Slightshot-#{version}.dmg",
      verified: "github.com/jmpijll/slightshot/"
  name "Slightshot"
  desc "Native open-source screenshot tool inspired by Lightshot"
  homepage "https://github.com/jmpijll/slightshot"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app itself requires macOS 27 via LSMinimumSystemVersion; :tahoe is
  # the newest symbol Homebrew knows, so it acts as the cask-level floor.
  depends_on macos: ">= :tahoe"

  app "Slightshot.app"

  uninstall quit: "com.jmpijll.slightshot"

  zap trash: [
    "~/Library/Caches/com.jmpijll.slightshot",
    "~/Library/Preferences/com.jmpijll.slightshot.plist",
  ]
end
