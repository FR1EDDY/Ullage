#!/bin/bash
#
# Builds Ullage.app and a DMG from the SwiftPM package.
#
# SwiftPM produces a bare executable; a menu-bar app needs a real bundle with an
# Info.plist (for LSUIElement, which is what keeps it out of the Dock and the
# app switcher). This script assembles that bundle by hand — deliberately, so
# distribution doesn't depend on the broken .xcodeproj in this repo.
#
# The app is **ad-hoc signed**, not notarised. That's a chosen tradeoff, not an
# oversight: it needs no paid Apple Developer account, and the cost is that the
# first launch requires right-click → Open. The README says so.
#
# Usage:
#   Scripts/package_app.sh                 # universal build + DMG
#   Scripts/package_app.sh --arch arm64    # this machine's arch only (faster)
#   Scripts/package_app.sh --no-dmg
#
set -euo pipefail

APP_NAME="Ullage"
BUNDLE_ID="com.ullage.app"
# Single source of truth for the version. The Homebrew cask and the release tag
# must match this.
VERSION="$(cat "$(dirname "$0")/../VERSION" 2>/dev/null || echo "0.1.0")"
MIN_MACOS="13.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

ARCH_FLAGS=(--arch arm64 --arch x86_64)
MAKE_DMG=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH_FLAGS=(--arch "$2"); shift 2 ;;
        --no-dmg) MAKE_DMG=0; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

echo "==> Building $APP_NAME $VERSION (release)"
cd "$ROOT"
swift build -c release "${ARCH_FLAGS[@]}"

BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"
[[ -f "$EXECUTABLE" ]] || { echo "no executable at $EXECUTABLE" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"

# Resources are copied twice on purpose. SwiftPM's generated bundle is what the
# code looks for first, but `Bundle.module` is deliberately unused (it traps
# when the bundle is missing — see ModelPricing), so a loose copy in
# Contents/Resources is the belt to that braces: if the bundle ever fails to
# copy, pricing still resolves instead of everything showing as "unpriced".
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
find "$ROOT/Sources/$APP_NAME/Resources" -type f -exec cp {} "$APP/Contents/Resources/" \; 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>              <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleExecutable</key>           <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>LSMinimumSystemVersion</key>       <string>$MIN_MACOS</string>
    <!-- The whole point: no Dock icon, no app-switcher entry. A menu-bar app
         without this behaves like a normal app and feels wrong immediately. -->
    <key>LSUIElement</key>                  <true/>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key>  <false/>
</dict>
</plist>
PLIST

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# Ad-hoc signature ("-"). This does not make Gatekeeper trust the app; it makes
# the bundle internally consistent so macOS will run it at all once the user
# approves it, and it's required for the Keychain items to keep a stable owner
# across launches. Without a stable signature the app would re-prompt for
# Keychain access on every update.
echo "==> Ad-hoc signing"
# `cp -R` carries extended attributes across, and codesign refuses to sign a
# bundle containing them ("resource fork, Finder information, or similar
# detritus not allowed"). Stripping them is not cosmetic — without this the
# signing step fails outright.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature OK"

APP_SIZE="$(du -sh "$APP" | cut -f1 | tr -d ' ')"
echo "==> $APP ($APP_SIZE)"

if [[ "$MAKE_DMG" == "1" ]]; then
    DMG="$DIST/$APP_NAME-$VERSION.dmg"
    echo "==> Building DMG"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    # The Applications symlink is what makes "drag to install" obvious without
    # a background image or a custom window layout.
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
    rm -rf "$STAGE"
    echo "==> $DMG ($(du -sh "$DMG" | cut -f1 | tr -d ' '))"
    echo
    echo "    sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
fi

echo
echo "Done. First launch on another Mac needs right-click → Open (unsigned build)."
