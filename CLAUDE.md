# Project brief: fivek (5K extended display over Wi-Fi, no third-party apps)

Read this first. It is the full context from the chat that produced this code.

## Goal
Extend a MacBook Air's screen onto a 27" 5K iMac at its native 5120x2880 over Wi-Fi.
Native AirPlay "Extend" is capped around 1080p (Apple's stream limit, not overridable via public APIs),
so we stream the video ourselves.

## Hardware / software
- Sender: MacBook Air M5, base config, macOS Tahoe. Must use negligible CPU/GPU/RAM
  (hardware HEVC encode only; ScreenCaptureKit delivers frames only on change).
- Receiver: 2020 Intel i5 27" iMac 5K, base config, macOS Monterey (12) (Radeon Pro, Intel UHD 630, T2, Wi-Fi 5).
  Resources are NOT a concern here. Hardware HEVC decode available.
- Source display: FiveK's own virtual display via private CGVirtualDisplay (src/VirtualDisplay.swift).
  BetterDisplay is NO LONGER used or needed (removed 2026-11-23 at the user's request).
- Network: Wi-Fi preferred (USB cable is not an option; no Thunderbolt link). Ethernet is acceptable for debugging.

## User constraints / preferences
- No money: no Luna Display, Duet, etc.
- Does NOT want Sunshine/Moonlight or other big third-party apps ("too unstable").
- Wants it to behave like a native utility: nothing running in the background when idle,
  ideally a one-click start (a Shortcut / menu bar item that runs the sender, with the receiver
  launched on demand, e.g. launchd socket activation). Control Center cannot be extended by third parties,
  so a Shortcut or menu bar item is the realistic stand-in.
- Only worth it if the picture is genuinely 5K; their existing 1080p AirPlay display already works.

## Architecture (current)
Layout: `src/Sender.swift` (sender core, shared), `src/FiveKApp.swift` (one-click menu bar app),
`src/send-cli.swift` (debug CLI), `src/fivek-recv.swift` (receiver), `src/make-icon.swift` (app icon),
`build.sh`, `make-signing-cert.sh`, `tools/airplay-native.swift`.
Repo: github.com/ShivamHimatsingka/FiveK (MIT). build/ is gitignored.
- FiveK.app (Air, LSUIElement, signed with local "FiveK Local Signing" identity, bundle id com.fivek.sender): checks
  Screen Recording permission, starts the Sender; once the TCP connection is up, Sender.prepareDisplay creates a
  VirtualDisplay (CGVirtualDisplay, name "FiveK", 2560x1440 pt HiDPI = 5120x2880 px, 27" size, sRGB primaries,
  fixed vendor 0xF15C / product 0x5000 / serial 1 so macOS remembers its arrangement) and capture starts on it.
  Releasing the object (stop/quit/crash) removes the display.
  Menu bar > Display Resolution (stored as defaults DisplayMode; default "5k"): Auto (match receiver), HiDPI presets
  3200x1800, 2880x1620, 5k 2560x1440, 2304x1296, 4096=2048x1152, 4k 1920x1080, 1600x900, 1280x720 (all @2x),
  low-DPI 1440/1080 (@1x), and "custom" (CustomWidth/CustomHeight/CustomHiDPI, dialog clamps 640-4096 x 360-2304,
  even numbers). Virtual display is created with max 6400x3600 so every preset switches in place. Menu warns when
  stream pixels != receiver pixels (resampling on the iMac).
  Menu bar > Text Sharpness (defaults Chroma: auto|444|420): 4:4:4 captures BGRA and encodes HEVC_Main444_AutoLevel
  (string constant; not exported by name); 4:2:0 captures NV12. Auto = 4:4:4 iff receiver's 'C' flag says it can
  decode it; receiver sends 'F' on decode failure or >30 frames with the layer not ready -> sender forces 4:2:0. Changing it while
  streaming calls Sender.reconfigure: stop SCStream + invalidate encoder (generation counter drops stale encoder
  callbacks; inFlight reset to sentFrames.count), VirtualDisplay.reconfigure applies new CGVirtualDisplaySettings
  IN PLACE (same displayID, windows stay; display created with max 5120x2880 or larger), restart capture, keyframe. Built with -import-objc-header src/CGVirtualDisplay.h
  (Swift renames applySettings: to apply(_:)). Settings via `defaults` (see README).
- Sender: ScreenCaptureKit (NV12, 709 matrix, captureResolution .best, no cursor) -> VideoToolbox HEVC
  hardware encode (NORMAL rate control by default, low-latency RC optional via LowLatencyRC; no reordering,
  no periodic keyframes, 100 Mbps) -> TCP (Network.framework,
  noDelay, interactiveVideo). Bonjour `_fivek._tcp` or Host setting.
- Receiver: "FiveK Receiver.app" (universal x86_64+arm64, macOS 12+, ad-hoc signed). Opened by the user it is a
  self-installer: copies itself to ~/Applications (avoids Gatekeeper translocation), writes
  ~/Library/LaunchAgents/com.fivek.receiver.plist, `launchctl bootstrap gui/<uid>`; opened again offers Uninstall.
  `--listen` = manual debug mode. Started by launchd = stream mode:
  launchd LaunchAgent `com.fivek.receiver` with socket activation
  (Sockets/Listener, port 5959, Bonjour "fivek"), so nothing runs when idle. Uses launch_activate_socket
  (looked up via dlsym; not exposed to Swift), BSD sockets, a blocking reader thread, AVSampleBufferDisplayLayer
  with DisplayImmediately. Wakes the display, disables idle display sleep while running, exits on disconnect.
  Ending a session on the iMac: Esc / Cmd-Q (main-menu key equivalents, so they work with the menu bar hidden),
  or moving the iMac's own mouse (global+local mouse monitors, no permission needed) shows its pointer and a HUD
  with a first-click Disconnect button for 3 s. In launchd mode all of these quit the process.
  Run by hand it listens itself (DNSServiceRegister) and stays up.
- Wire format: [type u8][len u32 BE][payload]. type 1 = parameter sets
  ([count u8] then [len u16 BE][bytes] each, sent before every keyframe);
  type 2 = frame ([flags u8, 1=key][HEVC NALs, 4-byte length-prefixed]).
  type 3 = cursor position ([x u16][y u16] fraction*65535, [visible u8]), ~120 Hz, on change.
  type 4 = cursor image ([hotX][hotY][w][h] u16 in 1/100 pt, then PNG), polled at 20 Hz via
  NSCursor.currentSystemCursor (called by selector; to-be-deprecated). Capture uses showsCursor=false.
  type 5 = display info [ptW][ptH][pxW][pxH] u16, sent at every capture (re)start; receiver scales the cursor by
  its own points width / sender points width, and flushes the layer when the stream dimensions change.
  Back-channel (receiver -> sender): 0x01 per type-2 message received (ack), 0x4B ('K') = keyframe request,
  0x52 ('R') + [ptW][ptH][pxW][pxH] u16 = receiver screen, sent right after accept (Auto mode waits up to 0.8 s).
  Flow control: always 2 unacked frames, up to 5 while unacked bytes < 600 KB. Frames captured while full are
  skipped before encoding, but the newest is held and sent when a slot frees.
  Quality: MaxAllowedFrameQP 24 (defaults MaxQP). The old "refinement" re-encodes were REMOVED 2026-11-25:
  tools/qualitybench.swift showed each pass adds <0.1 dB. Measured on 5K text: 4:2:0 ABR 27.9 dB, 4:2:0 maxQP24
  28.4, 4:2:0 quality 0.95 29.3 (5.4 MB key); 4:4:4 ABR 31.9, 4:4:4 maxQP24 34.6, 4:4:4 quality 0.95 40.6 (7.7 MB).
  Chroma subsampling is the dominant loss. 4:4:4 from BGRA costs ~18 ms vs 15 ms encode at 5K on the M5.
  Cursor: position sent on cq (own queue) from NSEvent global/local mouse monitors + 240 Hz poll; over UDP to the
  receiver's IP port 5959 when 'C' flag 4 is set (11-byte 'F5' datagrams with seq), else TCP type 3. Receiver
  binds UDP 5959 (SO_NET_SERVICE_TYPE VO) on its own thread and ignores TCP type 3 while UDP is active.
  Receiver probes 4:4:4 decode on connect by decoding an embedded 128x64 Main444 keyframe (Probe444).
  Default bitrate 100 Mbps.

## First real test (2026-11-21, Wi-Fi)
Worked; sharper than AirPlay but softer than native, laggy cursor. Log: max 37 fps with 15-24 skipped/s
(capture ~55-60), avg 1.4 Mbps, peak 25 Mbps => limited by the 2-frame window x ~57 ms round trip, not
bandwidth. Low-latency RC accepted; MaxFrameDelayCount and PrioritizeEncodingSpeedOverQuality return -12900
(not supported with low-latency RC). Virtual screen was 2560x1440 HiDPI (mode 68); BetterDisplay had restored
it itself, so the set returned "Failed." harmlessly. Fixes above (cursor overlay, byte-budget window,
refinement, 100 Mbps) are NOT yet tested on the iMac. Stats line now shows enc/net ms.

## Status
Working end to end on the real hardware (MacBook Air M5 -> 2020 iMac over Wi-Fi), released as v0.1.0 and v0.2.0 (v0.3.0 built, not yet released)
(GitHub release with FiveK.zip + FiveK-Receiver.zip). Commits are authored by Shivam Himatsingka only
(no Claude co-author trailers; history was rewritten once to remove them).
Virtual display verified locally 2026-11-23 with a fake receiver (scratch script acking frames on 127.0.0.1):
display created at 2560x1440 pt / 5120x2880 px, captured and encoded (51 fps burst, ~22 ms encode), removed on
quit. 2026-11-25 local test (fake receiver reporting 5K + caps 5): 4:4:4 negotiated, sizes switched in place
(5K -> 6400x3600 -> 5K on one display), Text Sharpness 4:4:4 -> 4:2:0 live, Custom 2200x1238 HiDPI -> 4400x2476,
UDP cursor datagrams received. Resolution menu verified locally 2026-11-23 the same way: Auto with a fake 1920x1080 1x receiver made a
1920x1080 display (encode ~6 ms); switching to 5K from the menu resized display 7 in place and restarted the
stream on the same connection (new type 5 + keyframe). Idle cost: ~5 encodes/s on a still desktop (1 Hz menu bar clock change + up to 3 refinement passes each).

## Third test (2026-11-21, Low Power Mode off, normal RC)
fps while active median 30, p90 42, max 50; skipped <= 2/s; net median 8 ms (p90 12); encode median 37 ms
(p90 49). Encode figure is submit->output and likely includes queueing (up to 5 frames in flight), since the
standalone benchmark is ~15 ms. Possible next step: cap frames inside the encoder at 1-2 and hold only the
newest (user said current performance is fine for now).

## Suggested test plan
1. `./build.sh --install` on the Air; copy build/FiveK Receiver.app to the iMac and open it once (right-click > Open).
2. `dns-sd -B _fivek._tcp` on the Air should list the iMac.
3. Open FiveK; check the menu bar status, the iMac log (/tmp/fivek-recv.log), and the encoder line
   (low-latency rate control true/false; run build/fivek-send in Terminal to see stdout).
4. Measure real Wi-Fi throughput, latency (target <90 ms), skip behaviour.

## Known risks / likely next work
- TCP head-of-line blocking on Wi-Fi loss -> may need UDP + packetization + keyframe request on loss.
- CGVirtualDisplay is private API: a macOS update could break or change it (same risk BetterDisplay has).
- 4:4:4 decode on the 2020 iMac is UNTESTED: Intel UHD 630 / Radeon Pro 5300 likely lack HW 4:4:4 HEVC decode, so
  it may run in software (probe reports this); fallback via 'F' exists but the 30-frame not-ready threshold is a guess.
- Latency tuning (bitrate/fps, queueDepth, encoder settings); 30 fps fallback.
- Colour tags: sender tags 709 primaries/matrix + sRGB transfer, receiver sets the same; unverified visually.
- Keyframe request while the Air screen is static is only served on the next screen change.
- TCC: ad-hoc signing did NOT get Screen Recording on Tahoe (denied even with the toggle on). build.sh signs with a
  self-signed "FiveK Local Signing" identity (make-signing-cert.sh, login keychain, not trusted) instead.

## Second test + encoder benchmark (2026-11-21)
Cursor overlay and quit options work. Log: net round trip median 9 ms (p90 17), but encode median 36 ms,
p90 106, max 198 ms => encoder-bound, fps median 10 / max 29. Low Power Mode was ON (even on AC).
tools/encbench.swift, M5 Air, LPM on, 5120x2880 HEVC: low-latency RC 27 ms/frame and ~20 fps sustained;
normal RC + RealTime 15 ms and ~48 fps; H.264 can't do 5K (-12903); MaxFrameDelayCount rejected (-12900)
in both modes. Performance drops as the fanless Air heats up. Switched default to normal RC (untested live).

## Earlier artifact
`tools/airplay-native.swift`: standalone CLI that lists/sets display modes via CoreGraphics. It cannot
raise the AirPlay cap and is only useful for inspecting what modes a display exposes.
