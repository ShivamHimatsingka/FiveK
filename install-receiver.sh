#!/bin/bash
# Run ON THE iMAC, from the folder containing fivek-recv:   ./install-receiver.sh
# Uninstall:                                                 ./install-receiver.sh --uninstall
#
# Installs a per-user launchd agent with socket activation: launchd listens on TCP 5959 and advertises
# _fivek._tcp over Bonjour. Nothing runs until the Air connects; then launchd starts fivek-recv, which
# shows the stream fullscreen and exits when the Air disconnects. Needs you to be logged in on the iMac.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.fivek.receiver
DEST="$HOME/Library/Application Support/fivek"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "$PLIST"; rm -rf "$DEST"
    echo "Receiver uninstalled."
    exit 0
fi

mkdir -p "$DEST" "$HOME/Library/LaunchAgents"
cp fivek-recv "$DEST/fivek-recv"
chmod +x "$DEST/fivek-recv"
xattr -d com.apple.quarantine "$DEST/fivek-recv" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>                  <string>$LABEL</string>
    <key>ProgramArguments</key>       <array><string>$DEST/fivek-recv</string></array>
    <key>Sockets</key>
    <dict>
        <key>Listener</key>
        <dict>
            <key>SockServiceName</key> <string>5959</string>
            <key>SockType</key>        <string>stream</string>
            <key>Bonjour</key>         <string>fivek</string>
        </dict>
    </dict>
    <key>LimitLoadToSessionType</key> <string>Aqua</string>
    <key>ProcessType</key>            <string>Interactive</string>
    <key>StandardOutPath</key>        <string>/tmp/fivek-recv.log</string>
    <key>StandardErrorPath</key>      <string>/tmp/fivek-recv.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Receiver installed. Nothing is running now; it starts when FiveK on the Air connects."
echo "Check Bonjour:  dns-sd -B _fivek._tcp     Log: /tmp/fivek-recv.log"
