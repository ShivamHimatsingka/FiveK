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
- Source display: BetterDisplay-created virtual display, 5120x2880 (already set up on the Air).
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
- FiveK.app (Air, LSUIElement, signed with local "FiveK Local Signing" identity, bundle id com.fivek.sender): checks Screen Recording permission,
  launches BetterDisplay if needed, runs BetterDisplay's built-in CLI (`.../MacOS/BetterDisplay set -name="Virtual 16:9"
  -connected=on`, then `-resolution=2560x1440 -hiDPI=on`), waits for a 5120-px-wide CG display, then streams.
  Stop (menu, re-launching the app, or receiver closing) disconnects the virtual screen and quits BetterDisplay
  if FiveK launched it. Settings via `defaults` (see README).
- Sender: ScreenCaptureKit (NV12, 709 matrix) -> VideoToolbox HEVC hardware encode (low-latency RC with
  fallback, no reordering, MaxFrameDelayCount 0, no periodic keyframes, ~60 Mbps) -> TCP (Network.framework,
  noDelay, interactiveVideo). Bonjour `_fivek._tcp` or Host setting.
- Receiver: "FiveK Receiver.app" (universal x86_64+arm64, macOS 12+, ad-hoc signed). Opened by the user it is a
  self-installer: copies itself to ~/Applications (avoids Gatekeeper translocation), writes
  ~/Library/LaunchAgents/com.fivek.receiver.plist, `launchctl bootstrap gui/<uid>`; opened again offers Uninstall.
  `--listen` = manual debug mode. Started by launchd = stream mode:
  launchd LaunchAgent `com.fivek.receiver` with socket activation
  (Sockets/Listener, port 5959, Bonjour "fivek"), so nothing runs when idle. Uses launch_activate_socket
  (looked up via dlsym; not exposed to Swift), BSD sockets, a blocking reader thread, AVSampleBufferDisplayLayer
  with DisplayImmediately. Wakes the display, disables idle display sleep while running, exits on disconnect.
  Run by hand it listens itself (DNSServiceRegister) and stays up.
- Wire format: [type u8][len u32 BE][payload]. type 1 = parameter sets
  ([count u8] then [len u16 BE][bytes] each, sent before every keyframe);
  type 2 = frame ([flags u8, 1=key][HEVC NALs, 4-byte length-prefixed]).
  Back-channel (receiver -> sender): 0x01 per type-2 message received (ack), 0x4B ('K') = keyframe request.
  Sender keeps <= 2 unacked frames; frames captured while full are skipped before encoding, but the newest
  one is held and sent when a slot frees, so the final screen state always arrives.

## Status
Everything compiles (`./build.sh`). Verified on the Air (iMac off): Screen Recording permission (needs the
signing cert), BetterDisplay CLI connect + switch to 2560x1440 HiDPI, Bonjour search timeout, cleanup
(virtual screen disconnected). NOT yet run: capture/encode at 5120x2880, the stream, the iMac receiver
(launchd socket activation, Bonjour advertisement, decode).
BetterDisplay CLI quirk: a `set` that changes nothing prints "Failed." to stderr and exits 1, so the app reads
state with `get` first and only sets what differs.

## Suggested test plan
1. `./build.sh --install` on the Air; copy build/FiveK Receiver.app to the iMac and open it once (right-click > Open).
2. `dns-sd -B _fivek._tcp` on the Air should list the iMac.
3. Open FiveK; check the menu bar status, the iMac log (/tmp/fivek-recv.log), and the encoder line
   (low-latency rate control true/false; run build/fivek-send in Terminal to see stdout).
4. Measure real Wi-Fi throughput, latency (target <90 ms), skip behaviour.

## Known risks / likely next work
- TCP head-of-line blocking on Wi-Fi loss -> may need UDP + packetization + keyframe request on loss.
- ScreenCaptureKit with a BetterDisplay virtual display (display selection by pixel width 5120).
- Latency tuning (bitrate/fps, queueDepth, encoder settings); 30 fps fallback.
- Colour tags: sender tags 709 primaries/matrix + sRGB transfer, receiver sets the same; unverified visually.
- Keyframe request while the Air screen is static is only served on the next screen change.
- TCC: ad-hoc signing did NOT get Screen Recording on Tahoe (denied even with the toggle on). build.sh signs with a
  self-signed "FiveK Local Signing" identity (make-signing-cert.sh, login keychain, not trusted) instead.

## Earlier artifact
`tools/airplay-native.swift`: standalone CLI that lists/sets display modes via CoreGraphics. It cannot
raise the AirPlay cap and is only useful for inspecting what modes a display exposes.
