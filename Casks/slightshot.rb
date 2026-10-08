cask "slightshot" do
  version "1.4.0"
  sha256 "725db9d357aac22d5283b689ac9b224ee6c80a1c7b3c9f1284a52d9edbd3cbec"

  url "https://github.com/jmpijll/slightshot/releases/download/v#{version}/Slightshot-#{version}.dmg"
  name "Slightshot"
  desc "Native open-source screenshot tool inspired by Lightshot"
  homepage "https://github.com/jmpijll/slightshot"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "Slightshot.app"

  uninstall quit: "com.jmpijll.slightshot"

  zap trash: [
    "~/Library/Caches/com.jmpijll.slightshot",
    "~/Library/Preferences/com.jmpijll.slightshot.plist",
  ]
end
