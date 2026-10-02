#!/bin/bash
# Builds build/PhotoStacks.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product PhotoStacks
BIN="$(swift build -c release --show-bin-path)/PhotoStacks"
APP="build/PhotoStacks.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotoStacks"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PhotoStacks</string>
    <key>CFBundleDisplayName</key><string>PhotoStacks</string>
    <key>CFBundleIdentifier</key><string>nl.harmbout.photostacks</string>
    <key>CFBundleExecutable</key><string>PhotoStacks</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key><string>nl</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Map</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Klaar: $APP"
