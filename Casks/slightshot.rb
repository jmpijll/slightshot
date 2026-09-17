cask "slightshot" do
  version "1.0.1"
  sha256 "a00cbe46a0cbc56fa95fc97b7b6e43fc5b5f823963baf5461e9286be6bf65402"

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
