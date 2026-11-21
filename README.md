<p align="center"><img src="docs/icon.png" width="128" alt="FiveK icon"></p>

<h1 align="center">FiveK</h1>

<p align="center">
Use a 27" 5K iMac as a true <b>5120×2880</b> extended display for a MacBook, over Wi-Fi.<br>
One click to start. Nothing runs on either Mac when it's idle.
</p>

> **Status: prototype.** Everything builds. The sender has been tested on the Air: permissions,
> BetterDisplay control and the receiver search all work. The full stream to the iMac has **not** been run
> yet, so expect rough edges.

## Why

macOS can extend onto another Mac with AirPlay, but AirPlay caps the stream at about 1080p. On a 5K iMac that
looks soft. FiveK streams the picture itself, at full resolution:

```
MacBook (sender)                                       iMac (receiver)
BetterDisplay virtual screen, 2560x1440 HiDPI          launchd listens on :5959, advertises _fivek._tcp
  -> ScreenCaptureKit (only on screen changes)           -> starts fivek-recv when the Air connects
  -> VideoToolbox HEVC hardware encode                   -> hardware HEVC decode
  -> TCP over Wi-Fi  ─────────────────────────────────►  -> borderless fullscreen, 5120x2880
                     ◄──────── per-frame acks ─────────
```

- **Light on the laptop.** Hardware HEVC encoding, zero-copy NV12 capture, and frames are only captured when
  the screen changes.
- **Low latency.** The receiver acknowledges every frame, and the sender limits unacknowledged data (2–5 frames,
  capped by bytes), so a slow link can't build up a queue. When the link is busy, frames are skipped *before*
  encoding, and the newest one is always sent once there's room.
- **Responsive cursor.** The mouse pointer isn't part of the video. Its position and shape are sent separately
  about 120 times a second and drawn on the iMac, so it moves without waiting for encoding.
- **Sharp when still.** Once the screen stops changing, the last frame is re-encoded a few times so the encoder
  can refine it to full detail.
- **Native-utility feel.** A menu bar app on the Air, and a socket-activated launchd agent on the iMac.
  Nothing is resident when you're not using it.

## Requirements

| | |
|---|---|
| **Sender** | Apple Silicon Mac running macOS 14+ (developed on macOS Tahoe) with [BetterDisplay](https://github.com/waydabber/BetterDisplay) (free) |
| **Receiver** | Intel or Apple Silicon Mac running macOS 12+ with a 5K panel (developed for a 2020 27" iMac) |
| **Network** | Both Macs on the same network. 5 GHz Wi-Fi works; Ethernet on either side helps. |
| **Build** | Xcode command-line tools (`swiftc`) |

## Setup

**On the MacBook**
```bash
git clone https://github.com/ShivamHimatsingka/FiveK.git
cd FiveK
./make-signing-cert.sh      # once: local code-signing certificate, so Screen Recording permission sticks
./build.sh --install        # builds both apps into build/ and installs /Applications/FiveK.app
```
In BetterDisplay, create a **16:9 virtual screen** named `Virtual 16:9`. To use a different name, see Settings below.

**On the iMac**: copy `build/FiveK Receiver.app` over (or `build/FiveK-Receiver.zip`; AirDrop is fine) and
open it once. It copies itself to `~/Applications` and registers an on-demand launchd agent. Then it quits,
and nothing keeps running. From then on, the receiver starts by itself whenever the MacBook connects.
Because the app isn't notarized, the first time you open it you need to **right-click > Open** and confirm.
To uninstall, open `~/Applications/FiveK Receiver.app` and choose **Uninstall**.

Keep the iMac logged in, and stop it from sleeping on its own (System Preferences > Energy Saver >
"Prevent computer from sleeping automatically when the display is off"). The display itself can sleep:
FiveK wakes it.

**First launch**: open FiveK. macOS asks for **Screen Recording** and **Local Network** permission.
Allow both, then open FiveK again.

## Use

- **Start:** open FiveK. It starts BetterDisplay if needed, connects the virtual screen at 2560×1440 HiDPI,
  finds the iMac, wakes its display and streams.
- **Stop from the MacBook:** click FiveK again, or use the menu bar icon > **Stop**.
- **Stop from the iMac:** press **Esc** or **⌘Q**. Or move the iMac's own mouse: its pointer comes back with a
  bar at the top of the screen, where you click **Disconnect**.

Either way, the MacBook's virtual screen is disconnected, so windows come back to the MacBook. If FiveK started
BetterDisplay, it quits it too. On the iMac nothing keeps running; the receiver starts again the next time you
open FiveK.

The menu bar shows live fps and Mbps.

## Settings

All optional:
```bash
defaults write com.fivek.sender VirtualScreenName "Virtual 16:9"
defaults write com.fivek.sender Resolution "2560x1440"    # "looks like" size on the iMac
defaults write com.fivek.sender HiDPI -bool true          # false = 5120x2880 at 1x (tiny text)
defaults write com.fivek.sender Mbps -int 100             # lower if Wi-Fi stutters
defaults write com.fivek.sender FPS -int 60               # 30 halves the bandwidth
defaults write com.fivek.sender Host "192.168.1.20"       # skip Bonjour discovery
```

## Troubleshooting

- **Logs:** `~/Library/Logs/FiveK.log` on the MacBook, `/tmp/fivek-recv.log` on the iMac.
- **"Couldn't find the iMac":** run `dns-sd -B _fivek._tcp` on the MacBook. The iMac must be on, logged in
  and on the same network.
- **Screen Recording keeps getting denied:** run `./make-signing-cert.sh`, rebuild, then remove FiveK from
  Privacy & Security > Screen & System Audio Recording and add it again. An ad-hoc signed build doesn't
  keep the permission.
- **Running things by hand:** on the iMac, uninstall the receiver (see Setup), then run
  `"FiveK Receiver.app/Contents/MacOS/fivek-recv" --listen`. On the MacBook, connect the virtual screen
  yourself, then run `build/fivek-send --host <iMac IP>`.

## Project layout

```
src/Sender.swift          capture -> encode -> network, with flow control (shared)
src/FiveKApp.swift        menu bar app: permissions, BetterDisplay control, start/stop
src/send-cli.swift        debug command-line sender
src/fivek-recv.swift      receiver: self-installer, launchd socket activation, decode, fullscreen display
src/make-icon.swift       draws the app icon
build.sh                  builds FiveK.app, FiveK Receiver.app (universal) and zips into build/
make-signing-cert.sh      creates the local "FiveK Local Signing" identity
tools/airplay-native.swift  inspects or sets display modes with CoreGraphics (diagnostics)
```

### Wire format
`[type u8][len u32 BE][payload]`. Type 1 carries HEVC parameter sets (sent before every keyframe). Type 2 is a
frame: `[flags u8 (1=key)][4-byte length-prefixed NALs]`. Type 3 is the cursor position and type 4 the cursor
image (PNG plus hotspot). The receiver sends back `0x01` per frame (ack) or
`0x4B` to request a keyframe.

## Roadmap

- End-to-end testing on real hardware, plus latency and throughput measurements
- UDP transport with loss recovery, if TCP stalls on lossy Wi-Fi
- A 30 fps fallback that switches automatically under load

## License

[MIT](LICENSE)
