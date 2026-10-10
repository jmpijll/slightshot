cask "slightshot" do
  version "1.5.0"
  sha256 "6ae8a77b0d983dd24d82a2b022e314979cbef872dd6f3f98df93c5bf1dec9037"

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
