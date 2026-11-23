#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
app="$PWD/dist/FamilyRelay.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/FamilyRelay" "$app/Contents/MacOS/FamilyRelay"
cp -R "$bin_dir/FamilyRelay_FamilyRelay.bundle" "$app/Contents/Resources/"
cp "$PWD/Resources/MessagingBridge.icns" "$app/Contents/Resources/MessagingBridge.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.family-relay</string>
<key>CFBundleName</key><string>FamilyRelay</string>
<key>CFBundleDisplayName</key><string>Мост сообщений</string>
<key>CFBundleExecutable</key><string>FamilyRelay</string>
<key>CFBundleIconFile</key><string>MessagingBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf '%s\n' "$app"
