cask "slightshot" do
  version "1.2.0"
  sha256 "61ec9b6d3db2f63c9e93faa4e064081c2ef7bdef05bf4a5139f89d01b4391e9b"

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
