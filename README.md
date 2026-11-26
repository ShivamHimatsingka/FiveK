<p align="center"><img src="docs/icon.png" width="128" alt="FiveK icon"></p>

<h1 align="center">FiveK</h1>

<p align="center">
<b>Use a 27" 5K iMac as a true 5120×2880 extended display for your MacBook, over Wi-Fi.</b><br>
One click to start. Nothing running on either Mac when you're not using it.
</p>

<p align="center">
<a href="https://github.com/ShivamHimatsingka/FiveK/releases/latest"><img src="https://img.shields.io/github/v/release/ShivamHimatsingka/FiveK?label=download" alt="Latest release"></a>
<img src="https://img.shields.io/badge/macOS-12%2B%20receiver%20%C2%B7%2014%2B%20sender-blue" alt="macOS versions">
<img src="https://img.shields.io/badge/Swift-no%20dependencies-orange" alt="Swift">
<a href="LICENSE"><img src="https://img.shields.io/github/license/ShivamHimatsingka/FiveK" alt="MIT license"></a>
</p>

---

macOS can extend your screen onto another Mac with AirPlay, but AirPlay limits the stream to about **1080p**.
On a 5K iMac that looks blurry, and there's no setting to raise it. Sidecar and Target Display Mode don't help
either: neither supports a 2020 iMac as a display for another Mac.

FiveK streams the picture itself: hardware HEVC encoding on the MacBook, hardware decoding on the iMac, at the
full 5120×2880. Text is as crisp as the iMac's own display.

It isn't limited to that pair: FiveK works between **any two Macs**. When they connect, the receiver reports
its measured screen (pixels, points, HiDPI, physical size), and FiveK sizes everything from that. You can also
**mirror** the sending Mac's screen instead of extending it.

|  | AirPlay "Extend" | **FiveK** |
|---|---|---|
| Resolution on a 5K iMac | ~1920×1080, upscaled | **5120×2880** (2560×1440 HiDPI) |
| Cursor | part of the video | **drawn on the iMac** (moves at network speed) |
| Starts with | Control Center | one click, from the app or Dock |
| Cost | free | free, no third-party streaming apps |

## Real-world performance

Measured on a **MacBook Air M5** streaming to a **2020 27" iMac** over home Wi-Fi:

| | |
|---|---|
| Frame rate while working | **30 fps** typical, up to **50 fps** when dragging windows |
| Encode on the MacBook | 20–50 ms per 5K frame (hardware HEVC) |
| Network round trip | 8 ms median, 12 ms at the 90th percentile |
| Bandwidth | 2–9 Mbps while working, close to 0 when the screen is still |
| Dropped frames | effectively none (at most 2/s) |

The screen is only captured when something changes, so a still desktop costs almost nothing. At 5K, the
MacBook's video encoder is the limit, not Wi-Fi. **Turn off Low Power Mode** while streaming: with it on, the
frame rate above drops by more than half.

## Quick start

Nothing else to install: FiveK creates its own virtual 5K display.

1. **Download** `FiveK.zip` and `FiveK-Receiver.zip` from the
   **[latest release](https://github.com/ShivamHimatsingka/FiveK/releases/latest)**.
2. **On the iMac:** unzip `FiveK-Receiver.zip`, then **right-click > Open** on **FiveK Receiver**. It
   installs itself and quits. Nothing stays running.
3. **On the MacBook:** unzip `FiveK.zip`, move **FiveK** to Applications, and **right-click > Open** it.
   Allow **Screen Recording** and **Local Network** when asked, then open FiveK again.

From then on, just **open FiveK**. It finds the iMac, adds a 5K display called **FiveK** to your Mac, wakes
the iMac's display and starts streaming. To choose which side of your MacBook the iMac sits on, drag the
FiveK display in **System Settings > Displays > Arrange** while streaming. macOS remembers the position.

> The apps aren't notarized by Apple, which is why the first launch needs **right-click > Open**. If macOS
> keeps denying Screen Recording, build FiveK yourself (below): a self-built copy is signed with your own
> local certificate, which macOS remembers.

## Using it

| To… | Do this |
|---|---|
| **Start** | Open FiveK (from the Dock, Spotlight or Launchpad) |
| **Stop from the MacBook** | Click FiveK again, or use the menu bar icon > **Stop** |
| **Stop from the iMac** | Press **Esc** or **⌘Q**. Or move the iMac's mouse and click **Disconnect** |
| **Extend or mirror** | Menu bar icon > **Extend** (second screen) or **Mirror** (show this Mac's screen) |
| **Change the resolution** | Menu bar icon > **Display Resolution** (applies instantly, while streaming) |
| **Change text sharpness** | Menu bar icon > **Text Sharpness** (full colour 4:4:4 or standard 4:2:0) |
| **See live stats** | Click the menu bar icon (fps, Mbps, encode and network times) |

### Extend or mirror

- **Extend** (default): the other Mac becomes a second screen. FiveK adds a virtual display called **FiveK**,
  sized from the receiver's measurements, and removes it when you stop.
- **Mirror**: the other Mac shows exactly what's on this Mac's own screen, at this Mac's measured resolution.
  If the two screens have different shapes (a 16:10 MacBook on a 16:9 iMac, say), the receiver adds black bars
  rather than stretching the picture.

You can switch between them mid-stream. Display Resolution only applies to Extend.

### Display resolution

The default is **Auto**: the virtual display matches the other Mac's screen exactly, pixel for pixel, using the
size and HiDPI scale it reports. On a 5K iMac that's 2560×1440 HiDPI (5120×2880 pixels). The other sizes are
steps relative to the receiver's own screen, so they keep its shape on any Mac:

| Option | Size relative to the other Mac's screen | On a 5K iMac |
|---|---|---|
| **Auto** (default) | exactly its screen | 2560×1440 HiDPI (5120×2880) |
| Most space | 1.25× | looks like 3200×1800 (6400×3600) |
| More space | 1.125× | looks like 2880×1620 |
| Native | 1× HiDPI | looks like 2560×1440 |
| Larger text | 0.9×, 0.8×, 0.75×, 0.625× | e.g. 2048×1152, 1920×1080 |
| Largest text | 0.5× | looks like 1280×720 |
| Low DPI | 1× or 0.75× at 1x scale | 2560×1440 or 1920×1080 pixels; much faster, visibly softer |
| **Custom…** | any size you type | width 640–4096, height 360–2304 points, HiDPI on or off |

Until a receiver has connected (or with a receiver older than 0.3), sizes are based on 2560×1440. Anything
other than Auto is resampled on the receiver, so Auto is the sharpest; the menu warns when the stream and the
receiver's screen don't match. Changes apply instantly, and the virtual display is resized in place, so windows
stay where they are.

### Text sharpness

Normal video (4:2:0) stores colour at a quarter of the resolution, which softens coloured text and UI edges:
it's the main reason a stream looks less crisp than the iMac's own screen. FiveK can stream **full colour
(4:4:4)** instead. Measured on 5K text with `tools/qualitybench.swift`, standard video tops out around 28–29 dB,
while full colour reaches about 35 dB at a similar size.

| Option | What it does |
|---|---|
| **Auto** (default) | Full colour if the iMac can decode it, otherwise standard. The receiver checks this each time it connects |
| Full colour (4:4:4) | Sharpest text. The MacBook's encoder handles it easily (≈18 ms vs 15 ms per 5K frame) |
| Standard (4:2:0) | Lightest for the iMac to decode |

Older Intel iMacs may only be able to decode full colour in software. If the receiver can't keep up, or a
decode fails, it asks the MacBook to switch to standard on its own, and the menu shows that it fell back.

When a session ends, the FiveK display is removed, so your windows come back to the MacBook.

**iMac tips:** keep it logged in, and stop it from sleeping on its own (System Preferences > Energy Saver >
*Prevent computer from sleeping automatically when the display is off*). The display itself can sleep, since
FiveK wakes it.

## How it works

```mermaid
flowchart LR
    subgraph MacBook["MacBook · FiveK.app (menu bar)"]
        BD["FiveK virtual display (Extend)<br/>sized from the receiver's measured screen<br/>or this Mac's own screen (Mirror)"] --> SCK["ScreenCaptureKit<br/>only when the screen changes"]
        SCK --> VT["VideoToolbox<br/>hardware HEVC"]
        CUR["Cursor position + shape<br/>on every mouse move, over UDP"]
    end
    subgraph iMac["iMac · FiveK Receiver"]
        LD["launchd<br/>listens on :5959, Bonjour"] -->|starts on connect| RX["Hardware HEVC decode<br/>fullscreen, aspect-correct"]
        OV["Cursor overlay"]
    end
    VT -- "TCP over Wi-Fi" --> RX
    CUR -- "same connection" --> OV
    RX -. "per-frame acks" .-> VT
```

- **Its own virtual display.** FiveK creates the 5K display itself, with CoreGraphics' `CGVirtualDisplay`
  (the private API that display utilities such as BetterDisplay are built on). The display exists only while
  FiveK runs, and only after the iMac has connected, so windows never land on a screen you can't see.
- **Nothing runs when idle.** On the iMac, launchd holds the port and advertises it over Bonjour, and only
  starts the receiver when the MacBook connects. On the MacBook, FiveK runs only while you're streaming.
- **Latency can't build up.** The iMac acknowledges every frame, and the MacBook limits how much unacknowledged
  data is in flight (2–5 frames, capped by bytes). When the link is busy, frames are skipped *before* encoding,
  and the newest frame is always sent once there's room. So the picture is never stale.
- **Responsive cursor.** The pointer isn't part of the video. Its position is sent on every mouse movement,
  over UDP, so it never waits behind a large video frame; the iMac draws it. The cursor's shape follows along.
- **Sharp text.** Full-colour 4:4:4 encoding when the iMac supports it, and a quality floor (QP ≤ 24) so no
  frame is ever encoded too coarsely.
- **Light on the laptop.** Hardware HEVC encoding, no CPU pixel work, and nothing is encoded while the screen
  is still.

<details>
<summary><b>Wire format</b></summary>

Every message is `[type u8][length u32 big-endian][payload]`.

| Type | Direction | Payload |
|---|---|---|
| 1 | MacBook → iMac | HEVC parameter sets, sent before every keyframe: `[count u8]` then `[len u16][bytes]` each |
| 2 | MacBook → iMac | Frame: `[flags u8, 1 = keyframe]` + 4-byte length-prefixed NAL units |
| 3 | MacBook → iMac | Cursor position: `[x u16][y u16]` as a fraction of the screen × 65535, `[visible u8]` |
| 4 | MacBook → iMac | Cursor image: `[hotX][hotY][width][height]` as u16 in 1/100 pt, then PNG |
| 5 | MacBook → iMac | Display info, sent whenever capture (re)starts: `[pointsW][pointsH][pixelW][pixelH]` as u16, then `[flags u8]` (1 = 4:4:4) |

Back-channel, iMac → MacBook: `0x01` acknowledges a frame; `0x4B` (`K`) requests a keyframe; `0x52` (`R`) plus
`[pointsW][pointsH][pixelW][pixelH]` (u16) reports the iMac's screen and `0x43` (`C`) plus `[flags u8]` its
capabilities (1 = decodes 4:4:4, 2 = in hardware, 4 = takes the cursor over UDP), and `0x50` (`P`) plus
`[mmW][mmH]` (u16) its physical screen size, all once on connect;
`0x46` (`F`) asks for standard 4:2:0 because full colour isn't working.

Cursor over UDP, MacBook → iMac port 5959: 11-byte datagrams `['F' '5'][seq u32][x u16][y u16][visible u8]`.
Older or out-of-order datagrams are dropped.
</details>

## Building from source

Requires the Xcode command-line tools (`xcode-select --install`). No other dependencies.

```bash
git clone https://github.com/ShivamHimatsingka/FiveK.git
cd FiveK
./make-signing-cert.sh    # once: local code-signing certificate, so macOS remembers Screen Recording
./build.sh --install      # builds everything into build/ and installs /Applications/FiveK.app
```

`build/` then contains `FiveK.app`, `FiveK Receiver.app` (universal: Intel and Apple Silicon) and zips of both.
Copy the receiver to the iMac and open it once, as in Quick start.

## Settings

All optional, on the MacBook:

```bash
defaults write com.fivek.sender DisplayMode auto                   # same as the menu (auto, s125…s050, l100, l075, custom)
defaults write com.fivek.sender ScreenMode mirror                  # extend (default) or mirror
defaults write com.fivek.sender Chroma 444                         # same as Text Sharpness: auto, 444, 420
defaults write com.fivek.sender MaxQP -int 24                      # quality floor; lower = sharper, bigger frames
defaults write com.fivek.sender Mbps -int 100                      # lower if Wi-Fi stutters
defaults write com.fivek.sender FPS -int 60                        # 30 halves the bandwidth
defaults write com.fivek.sender Host "192.168.1.20"                # skip Bonjour, connect to this IP
defaults write com.fivek.sender LowLatencyRC -bool true            # alternative encoder mode (slower at 5K)
```

Undo any setting with `defaults delete com.fivek.sender <Name>`.

## Troubleshooting

| Problem | Fix |
|---|---|
| **Choppy, or lags when dragging windows** | Turn off **Low Power Mode** (System Settings > Battery). The stats line (`fps · Mbps · enc ms · net ms · skipped`) shows whether encoding or the network is slow. `tools/encbench.swift` benchmarks the encoder on its own. |
| **"Couldn't find the iMac"** | The iMac must be on, logged in and on the same network. Check with `dns-sd -B _fivek._tcp` on the MacBook, or set `Host` (see Settings). |
| **Screen Recording keeps being denied** | Run `./make-signing-cert.sh`, rebuild, then remove FiveK from *Privacy & Security > Screen & System Audio Recording* and add it again. |
| **"Couldn't create the virtual 5K display"** | FiveK relies on a private macOS API (`CGVirtualDisplay`, available since macOS 11). If a future macOS update breaks it, please open an issue. |
| **iMac is on the wrong side** | While streaming, drag the **FiveK** display in System Settings > Displays > Arrange. |
| **Uninstall the receiver** | Open `~/Applications/FiveK Receiver.app` on the iMac and choose **Uninstall**. |

**Logs:** `~/Library/Logs/FiveK.log` on the MacBook, `/tmp/fivek-recv.log` on the iMac.

**Running by hand:** uninstall the receiver, then run `"FiveK Receiver.app/Contents/MacOS/fivek-recv" --listen`
on the iMac. On the MacBook, run `build/fivek-send --host <iMac IP>` (it creates the virtual display too).

## Project layout

```
src/Sender.swift            capture → encode → network, flow control, cursor, refinement
src/FiveKApp.swift          menu bar app: permissions, start/stop, settings
src/VirtualDisplay.swift    creates the 5K virtual display (CGVirtualDisplay)
src/CGVirtualDisplay.h      declarations for the private CGVirtualDisplay classes
src/fivek-recv.swift        receiver: self-installer, launchd socket activation, decode, display
src/send-cli.swift          debug command-line sender
src/make-icon.swift         draws the app icon
build.sh                    builds both apps (+ zips) into build/
make-signing-cert.sh        creates the local "FiveK Local Signing" certificate
tools/encbench.swift        HEVC encoder speed benchmark (5K/4K, each rate-control mode)
tools/qualitybench.swift    HEVC picture-quality benchmark on 5K text (4:2:0 vs 4:4:4, quality settings)
tools/airplay-native.swift  lists or sets display modes with CoreGraphics (diagnostics)
tools/fakereceiver.py       stand-in receiver for testing the sender on one Mac
```

## Roadmap

- [ ] Give the encoder fewer frames at once, to cut latency during fast motion
- [ ] UDP transport with loss recovery, for congested Wi-Fi
- [ ] Automatic 30 fps fallback under load
- [ ] Notarized builds, so the first launch doesn't need right-click > Open

## License

[MIT](LICENSE) © 2026 Shivam Himatsingka
