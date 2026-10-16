#!/bin/zsh
# Builds dist/iRemote.app (ad-hoc signed). Usage: ./build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product iRemote
BIN="$(swift build -c release --show-bin-path)/iRemote"
APP=dist/iRemote.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iRemote"
cp THIRD_PARTY.md "$APP/Contents/Resources/ThirdPartyNotices.md"
cp LICENSE "$APP/Contents/Resources/LICENSE"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>in.4nkitd.iremote</string>
    <key>CFBundleName</key><string>iRemote</string>
    <key>CFBundleDisplayName</key><string>iRemote</string>
    <key>CFBundleExecutable</key><string>iRemote</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>iRemote finds and controls Google TVs on your home network.</string>
    <key>NSBonjourServices</key>
    <array><string>_androidtvremote2._tcp</string></array>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/iRemote.app
    cp -R "$APP" ~/Applications/
    echo "Installed ~/Applications/iRemote.app"
fi
