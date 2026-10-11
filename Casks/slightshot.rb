cask "slightshot" do
  version "1.5.1"
  sha256 "a9ed823cea108648bc2dde5cba19996d71dd11104b16d22657ea66f48fab8938"

  url "https://github.com/jmpijll/slightshot/releases/download/v#{version}/Slightshot-#{version}.dmg"
  name "Slightshot"
  desc "Native screenshot and screen recording app"
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
