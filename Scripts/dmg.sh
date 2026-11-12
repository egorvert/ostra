#!/bin/zsh
# Builds Ostra and packs it into dist/Ostra-<version>.dmg to share with others.
#
# The app is signed ad hoc, not with a Developer ID, and isn't notarized, so
# macOS asks each person to confirm the first launch. The disk image carries
# a note that says how.
#
# Usage: Scripts/dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/bundle.sh
APP="dist/Ostra.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="dist/Ostra-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# Dragging the app onto this link installs it.
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<'NOTE'
Ostra

Requirements
- A Mac with Apple silicon, running macOS 26 or later.
- A Codex or Claude account. Ostra runs agents through them.

Install
1. Drag Ostra onto the Applications folder.
2. Open Ostra from Applications.

If macOS says it can't verify Ostra
Ostra isn't notarized by Apple yet, so macOS asks you to confirm it once:
1. In the message, click Done.
2. Open System Settings, then Privacy & Security.
3. Scroll to the message about Ostra and click Open Anyway.
4. Click Open Anyway again, and enter your password if asked.

First launch
Ostra downloads its engine, T3 Code (about 115 MB), and starts it. Then
sign in to Codex or Claude if you haven't, add a project folder, and type a
task in the chat box. Press ? to see every shortcut.
NOTE

rm -f "$DMG"
hdiutil create -volname "Ostra $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
echo "Built $DMG"
