#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; APP="$ROOT/build/Blackout.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/Blackout" -framework AppKit -framework CoreGraphics -framework Carbon -framework ServiceManagement
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.miketomkins.Blackout</string>
<key>CFBundleName</key><string>Blackout</string><key>CFBundleDisplayName</key><string>Blackout</string>
<key>CFBundleExecutable</key><string>Blackout</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string><key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/><key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
if [ -f "$ROOT/Assets/AppIcon.icns" ]; then cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP/Contents/Info.plist" || true; fi
codesign --force --deep --sign - "$APP" >/dev/null
printf 'Built %s\n' "$APP"
