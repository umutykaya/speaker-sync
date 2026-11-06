#!/bin/zsh
# Build SpeakerSync.app (universal: Apple silicon + Intel) and a DMG for
# installing on another Mac without the source tree.
#   scripts/package.sh 1.1.0   ->  dist/SpeakerSync-1.1.0.dmg
# The app is ad-hoc signed (no Developer ID): the first open on another Mac
# needs System Settings → Privacy & Security → Open Anyway.
set -euo pipefail

VERSION=${1:?usage: scripts/package.sh <version>}
ROOT=${0:A:h:h}
DIST="$ROOT/dist"
APP="$DIST/SpeakerSync.app"
DMG="$DIST/SpeakerSync-$VERSION.dmg"

echo "==> building web UI"
(cd "$ROOT/web" && npm ci --silent && npm run --silent build)

echo "==> building ssyncd (arm64 + x86_64)"
ARCHS=(--arch arm64 --arch x86_64)
(cd "$ROOT" && swift build -c release --product ssyncd $ARCHS)
BIN="$(cd "$ROOT" && swift build -c release --product ssyncd $ARCHS --show-bin-path)/ssyncd"

echo "==> assembling $APP"
rm -rf "$DIST" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ssyncd"
cp -R "$ROOT/web/dist" "$APP/Contents/Resources/web"
swift "$ROOT/scripts/make-icon.swift" "$DIST/AppIcon.iconset"
iconutil -c icns "$DIST/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$DIST/AppIcon.iconset"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.speakersync.ssyncd</string>
  <key>CFBundleName</key><string>Speaker Sync</string>
  <key>CFBundleDisplayName</key><string>Speaker Sync</string>
  <key>CFBundleExecutable</key><string>ssyncd</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Speaker Sync plays your Mac's audio (for example Spotify) on your Bluetooth speakers.</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "==> creating $DMG"
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<'EOF'
Speaker Sync

1. Drag "Speaker Sync" onto Applications.
2. Open it from Applications. macOS blocks it the first time because it is not
   notarized: open System Settings → Privacy & Security, scroll down, click
   "Open Anyway" next to Speaker Sync, and confirm.
3. A speaker icon appears in the menu bar and the web page opens. Pick your
   speakers under "Outputs". Use the menu bar icon → "Copy iPhone pairing link"
   to control it from your phone (same Wi-Fi).
4. If macOS asks to allow incoming network connections, click Allow (needed for
   the phone). For Spotify / Mac audio, allow "System Audio Recording" when asked.

It starts at login (menu bar icon → Open at Login to change). Settings live in
~/Library/Application Support/SpeakerSync. Requires macOS 15 or later.
Do not also install it with scripts/ssync.sh on the same Mac.
EOF
hdiutil create -volname "Speaker Sync $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$DMG"
