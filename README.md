# SwiftShare

A cross-platform Flutter file transfer app for sharing **multiple files at once**
between nearby devices at high speed, with chunked transfer, pause/resume, integrity
verification, and automatic selection of the fastest local transport.

Built with a white + violet glassmorphism design language, immersive edge-to-edge
UI, and a single shared codebase for the transfer/session logic.

## Platforms

| Platform | Transport | Notes |
|----------|-----------|-------|
| Android  | `NearbyTransport` (Google Nearby Connections, `Strategy.P2P_STAR`) | Nearby Connections uses Bluetooth/BLE for discovery and handshake, then **automatically upgrades to Wi-Fi Direct / hotspot** for the bulk payload — no manual radio-switch code. |
| Windows  | `LanSocketTransport` (UDP beacon + raw TCP, `dart:io`) | mDNS-style UDP discovery beacon; length-prefixed framed messages over TCP for max throughput. |
| Web      | `WebRtcTransport` (WebRTC DataChannels) | Browsers have no raw sockets or Bluetooth file access. Web uses secure P2P over WebRTC with QR/session-based signaling. |

### Why this hybrid design?

True simultaneous channel-bonding of Wi-Fi + classic Bluetooth data is **not a
standard OS capability**. The realistic, high-performing pattern is:

- **Bluetooth/BLE for discovery + handshake**
- **Wi-Fi (Wi-Fi Direct / LAN) for bulk data**

Android's Nearby Connections already performs this exact behavior automatically.
Windows mirrors it with UDP discovery + TCP data. Web has no OS radios at all, so
it uses WebRTC DataChannels — the highest-speed P2P path a browser can offer.

## Architecture

```
lib/
  app/                    # MaterialApp, global bloc providers
  core/
    theme/                # colors, text styles, theme data
    widgets/              # GlassCard, GlassScaffold, GradientBackground, ProgressRing, GlassToast
    utils/                # crc32c, chunker (reader/writer), hasher, byte formatter
    services/             # notification service (foreground progress)
    di/                   # get_it service locator
  transport/              # TransportChannel interface + platform impls + factory
  features/
    discovery/            # device discovery UI + cubit
    file_picker/          # multi-file selection UI + cubit
    transfer/             # session model, persistence, TransferCubit, progress UI
    history/              # past transfers
    settings/             # theme, chunk size, concurrency, device name
```

## Transfer protocol

Transport-agnostic and fully unit-tested:

- Files are split into fixed-size chunks (configurable, default 512 KB) and sent
  with a **sequence number + CRC-32C checksum** per chunk.
- The receiver verifies each chunk's CRC before writing; corrupt chunks are
  rejected and retried, never the whole file.
- The full file is verified with **SHA-256** after reassembly.
- Session state (file list, byte offsets, chunk ack bitmap / `lastAckedChunk`)
  is persisted to disk (Hive) so a transfer **resumes from the last acked chunk**
  after a manual pause, a dropped link, or even an app restart.
- If the link drops mid-transfer the cubit auto-persists the session as paused;
  `Resume` re-negotiates from the last acked chunk. Android posts a progress
  notification so transfers remain visible in the background.

## Build & run

```sh
flutter pub get
flutter run -d windows    # desktop
flutter run -d chrome     # web
flutter run -d <android>  # Android emulator/device
```

Tests:

```sh
flutter test              # chunking / CRC / session serialization
```

## Design system

- Primary violet `#7C4DFF`, gradient `#7C4DFF → #B388FF`, light bg `#F7F6FB`,
  dark bg `#14101F`.
- Glass surfaces via `BackdropFilter` + `ImageFilter.blur`, soft violet glow
  shadows, translucent borders.
- Responsive: mobile single-column + bottom nav; desktop side `NavigationRail`.
- Inter typography via `google_fonts`, motion via `flutter_animate`.