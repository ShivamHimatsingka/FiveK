#!/bin/bash
# Builds everything into ./build:
#   build/FiveK.app              sender for the MacBook   (./build.sh --install copies it to /Applications)
#   build/FiveK Receiver.app     receiver for the iMac: copy it over and double-click it once (it installs itself)
#   build/FiveK.zip, build/FiveK-Receiver.zip   the same apps zipped, for AirDrop / GitHub releases
#   build/fivek-send             debug CLI sender (needs the virtual screen already connected)
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build
echo "Drawing icon…"
swift src/make-icon.swift build/AppIcon.icns >/dev/null && rm -f build/AppIcon.png

echo "Building FiveK.app (Air)…"
APP=build/FiveK.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O src/Sender.swift src/FiveKApp.swift -o "$APP/Contents/MacOS/FiveK"
cp build/AppIcon.icns "$APP/Contents/Resources/"
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

echo "Building FiveK Receiver.app (iMac, universal, macOS 12+)…"
RAPP="build/FiveK Receiver.app"
mkdir -p "$RAPP/Contents/MacOS" "$RAPP/Contents/Resources"
swiftc -O -target x86_64-apple-macos12.0 src/fivek-recv.swift -o build/recv-x86_64
swiftc -O -target arm64-apple-macos12.0  src/fivek-recv.swift -o build/recv-arm64
lipo -create build/recv-x86_64 build/recv-arm64 -output "$RAPP/Contents/MacOS/fivek-recv"
rm build/recv-x86_64 build/recv-arm64
cp build/AppIcon.icns "$RAPP/Contents/Resources/"
cat > "$RAPP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>           <string>com.fivek.receiver</string>
    <key>CFBundleName</key>                 <string>FiveK Receiver</string>
    <key>CFBundleDisplayName</key>          <string>FiveK Receiver</string>
    <key>CFBundleExecutable</key>           <string>fivek-recv</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>   <string>1.0</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>LSMinimumSystemVersion</key>       <string>12.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
</dict>
</plist>
EOF
# The receiver needs no privacy permissions, so ad-hoc signing is enough.
codesign --force --sign - --identifier com.fivek.receiver "$RAPP"

echo "Zipping…"
(cd build && ditto -c -k --keepParent FiveK.app FiveK.zip && ditto -c -k --keepParent "FiveK Receiver.app" FiveK-Receiver.zip)
rm build/AppIcon.icns

if [[ "${1:-}" == "--install" ]]; then
    pkill -x FiveK 2>/dev/null || true
    rm -rf /Applications/FiveK.app && cp -R "$APP" /Applications/
    echo "Installed /Applications/FiveK.app"
fi
echo "Done."
