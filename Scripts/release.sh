#!/bin/bash
#
# Cuts a release: packages the app, creates a GitHub release, and prints the
# exact cask edit needed to point the Homebrew tap at it.
#
# Deliberately does NOT push to the tap itself — that's a second repository and
# a separate decision. It prints what to change so the step is one paste rather
# than a guess.
#
# Requires: gh (authenticated).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
APP_NAME="Ullage"
DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
TAG="v$VERSION"

command -v gh >/dev/null || { echo "gh CLI not found — install it or upload the DMG by hand" >&2; exit 1; }

echo "==> Packaging $VERSION"
"$ROOT/Scripts/package_app.sh"
[[ -f "$DMG" ]] || { echo "expected $DMG" >&2; exit 1; }

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "==> Tag $TAG already exists, reusing"
else
    echo "==> Tagging $TAG"
    git -C "$ROOT" tag -a "$TAG" -m "$APP_NAME $VERSION"
    git -C "$ROOT" push origin "$TAG"
fi

echo "==> Creating GitHub release"
gh release create "$TAG" "$DMG" \
    --title "$APP_NAME $VERSION" \
    --notes "Menu-bar usage and cost tracking for Claude and Cursor.

**Install**

    brew install --cask ullage/ullage/ullage

Or download the DMG below.

**First launch:** this build is ad-hoc signed rather than notarised, so macOS
will refuse the first double-click. Right-click the app → **Open** → **Open**.
Once only." \
    2>/dev/null || gh release upload "$TAG" "$DMG" --clobber

URL="$(gh release view "$TAG" --json assets --jq '.assets[0].url')"

cat <<SUMMARY

==> Release published.

Update the cask in the homebrew-ullage tap:

    version "$VERSION"
    sha256 "$SHA"

  url: $URL

SUMMARY
