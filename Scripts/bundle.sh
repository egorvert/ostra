#!/bin/zsh
# Builds Ostra in release mode and assembles dist/Ostra.app.
#
# Usage: Scripts/bundle.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
APP="dist/Ostra.app"

swift build -c release --product Ostra
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Ostra" "$APP/Contents/MacOS/Ostra"

# SwiftPM puts each target's resources in a bundle next to the binary.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Ostra</string>
  <key>CFBundleIdentifier</key><string>app.ostra.Ostra</string>
  <key>CFBundleName</key><string>Ostra</string>
  <key>CFBundleDisplayName</key><string>Ostra</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

# An ad-hoc signature is enough to run the app on the Mac that built it.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then
  open "$APP"
fi
