# Homebrew cask for Ullage.
#
# This file belongs in a separate tap repository named `homebrew-ullage`,
# at `Casks/ullage.rb`. It lives here so it's versioned alongside the app it
# installs; `Scripts/release.sh` prints the two lines to update after a release.
#
# Once the tap exists, install is one command:
#
#     brew install --cask ullage/ullage/ullage
#
cask "ullage" do
  version "0.1.0"
  sha256 "REPLACE_AFTER_FIRST_RELEASE"

  url "https://github.com/REPLACE_OWNER/Ullage/releases/download/v#{version}/Ullage-#{version}.dmg"
  name "Ullage"
  desc "Menu-bar usage and cost tracking for Claude and Cursor"
  homepage "https://github.com/REPLACE_OWNER/Ullage"

  depends_on macos: ">= :ventura"

  app "Ullage.app"

  # This build is ad-hoc signed rather than notarised, so Gatekeeper quarantines
  # it on download. Homebrew strips the quarantine attribute for casks it
  # installs, which is why `brew install` needs no right-click dance while a
  # manual DMG download does. Stated here because it's the difference between
  # the two install paths and it surprises people.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Ullage.app"],
                   sudo: false
  end

  uninstall quit: "com.ullage.app"

  # Everything the app writes, so `brew uninstall --zap` genuinely leaves no
  # trace. The Keychain items are listed for completeness but Homebrew can't
  # remove them — the README says how.
  zap trash: [
    "~/Library/Application Support/Ullage",
    "~/Library/Preferences/com.ullage.app.plist",
    "~/Library/Caches/com.ullage.app",
  ]
end
