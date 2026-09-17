cask "slightshot" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/jmpijll/slightshot/releases/download/v#{version}/Slightshot-#{version}.dmg",
      verified: "github.com/jmpijll/slightshot/"
  name "Slightshot"
  desc "Native open-source screenshot tool inspired by Lightshot"
  homepage "https://github.com/jmpijll/slightshot"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :tahoe"

  app "Slightshot.app"

  uninstall quit: "com.jmpijll.slightshot"

  zap trash: [
    "~/Library/Caches/com.jmpijll.slightshot",
    "~/Library/Preferences/com.jmpijll.slightshot.plist",
  ]
end
