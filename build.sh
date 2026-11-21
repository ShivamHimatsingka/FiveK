#!/bin/bash
# Builds everything into ./build:
#   build/FiveK.app             the one-click sender for the Air      (./build.sh --install copies it to /Applications)
#   build/fivek-send            debug CLI sender (needs the virtual screen already connected)
#   build/iMac/                 copy this folder to the iMac and run ./install-receiver.sh there
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/iMac

echo "Building FiveK.app (Air)…"
APP=build/FiveK.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O src/Sender.swift src/FiveKApp.swift -o "$APP/Contents/MacOS/FiveK"
swift src/make-icon.swift "$APP/Contents/Resources/AppIcon.icns" >/dev/null
rm -f "$APP/Contents/Resources/AppIcon.png"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>           <string>com.fivek.sender</string>
    <key>CFBundleName</key>                 <string>FiveK</string>
    <key>CFBundleDisplayName</key>          <string>FiveK</string>
    <key>CFBundleExecutable</key>           <string>FiveK</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>   <string>1.0</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSUIElement</key>                  <true/>
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>FiveK finds and streams to your iMac on the local network.</string>
    <key>NSBonjourServices</key>            <array><string>_fivek._tcp</string></array>
</dict>
</plist>
EOF
# Sign with the local "FiveK Local Signing" identity (./make-signing-cert.sh) so Screen Recording
# permission survives rebuilds. Ad-hoc signing works too, but macOS forgets the permission on every
# rebuild (and on Tahoe may not honour it at all).
if security find-certificate -c "FiveK Local Signing" >/dev/null 2>&1; then
    codesign --force --sign "FiveK Local Signing" --identifier com.fivek.sender "$APP"
else
    echo "warning: no \"FiveK Local Signing\" identity; run ./make-signing-cert.sh. Using ad-hoc signing." >&2
    codesign --force --sign - --identifier com.fivek.sender "$APP"
fi

echo "Building fivek-send (debug CLI)…"
swiftc -O src/Sender.swift src/send-cli.swift -o build/fivek-send

echo "Building iMac receiver (x86_64, macOS 12+)…"
swiftc -O -target x86_64-apple-macos12.0 src/fivek-recv.swift -o build/iMac/fivek-recv
codesign --force --sign - --identifier com.fivek.receiver build/iMac/fivek-recv
cp install-receiver.sh build/iMac/

if [[ "${1:-}" == "--install" ]]; then
    pkill -x FiveK 2>/dev/null || true
    rm -rf /Applications/FiveK.app && cp -R "$APP" /Applications/
    echo "Installed /Applications/FiveK.app"
fi
echo "Done."
