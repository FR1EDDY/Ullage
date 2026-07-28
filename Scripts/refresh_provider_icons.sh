#!/usr/bin/env bash
#
# Re-extracts the bundled provider icons from the installed desktop apps.
#
# Ullage draws provider icons *only* from the bundled copies these produce (see
# `ProviderIcon`) — never from the installed app, so every user sees the same
# artwork whether or not they have the desktop apps. This script is therefore
# the sole way that artwork enters the repo, and its output must be committed.
#
# Run it when a vendor ships a new icon — the bundled copy is a snapshot and
# will otherwise drift from the vendor's current mark:
#
#     Scripts/refresh_provider_icons.sh
#
# Requires the apps to be installed locally. Icons that can't be found are
# skipped with a warning rather than failing the run, so having only one of the
# two installed still refreshes that one.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Sources/Ullage/Resources"

# 256pt is four times the largest size either icon is drawn at (the 32pt card
# header on a Retina display), which leaves room for a future larger use
# without carrying the 512pt file's ~250KB into the binary.
SIZE="icon_256x256.png"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# app path : icns name inside Contents/Resources : output name
# The icns filename is the app's own, not a convention — Claude is an Electron
# app and ships its icon as `electron.icns`.
extract() {
    local app="$1" icns="$2" out="$3"
    local source="$app/Contents/Resources/$icns"

    if [[ ! -f "$source" ]]; then
        echo "warning: $source not found — skipping $out" >&2
        return 0
    fi

    iconutil -c iconset "$source" -o "$WORK/$out.iconset"
    if [[ ! -f "$WORK/$out.iconset/$SIZE" ]]; then
        echo "warning: $source has no $SIZE — skipping $out" >&2
        return 0
    fi

    cp "$WORK/$out.iconset/$SIZE" "$DEST/$out.png"
    echo "wrote $DEST/$out.png ($(du -h "$DEST/$out.png" | cut -f1))"
}

extract "/Applications/Claude.app" "electron.icns" "claude-icon"
extract "/Applications/Cursor.app" "Cursor.icns"   "cursor-icon"
