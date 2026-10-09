cask "slightshot" do
  version "1.4.2"
  sha256 "83e49fa6d2f27ae6f973fbbfe0840790a7fc163bc71a8884b164b01a7af8e737"

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
