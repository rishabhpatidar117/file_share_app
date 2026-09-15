# SwiftShare

A cross-platform Flutter file transfer app for sharing **multiple files at once**
between nearby devices at high speed, with chunked transfer, pause/resume, integrity
verification, and automatic selection of the fastest local transport.

Built with a white + violet glassmorphism design language, immersive edge-to-edge
UI, and a single shared codebase for the transfer/session logic.

## Platforms

| Platform | Transport | Notes |
|----------|-----------|-------|
| Android  | `LanSocketTransport` (UDP beacon + raw TCP, `dart:io`) | The `NearbyTransport` wrapper exists for a future Wi-Fi Direct upgrade but is not wired up yet, so all native platforms use the same LAN socket transport. |
| Windows  | `LanSocketTransport` (UDP beacon + raw TCP, `dart:io`) | mDNS-style UDP discovery beacon; length-prefixed framed messages over TCP for max throughput. |
| Web      | `WebRtcTransport` (WebRTC DataChannels) | Browsers have no raw sockets or Bluetooth file access. Web uses secure P2P over WebRTC with QR/session-based signaling. |

### Why this hybrid design?

True simultaneous channel-bonding of Wi-Fi + classic Bluetooth data is **not a
standard OS capability**. The realistic, high-performing pattern is:

- **Bluetooth/BLE for discovery + handshake**
- **Wi-Fi (Wi-Fi Direct / LAN) for bulk data**

Windows mirrors it with UDP discovery + TCP data. Web has no OS radios at all, so
it uses WebRTC DataChannels — the highest-speed P2P path a browser can offer.

## Runtime permissions

- LAN sockets need only the **INTERNET** permission, which is install-time
  (auto-granted) on Android — no prompt required.
- On Android 13+ the app requests `POST_NOTIFICATIONS` at startup
  (`PermissionService`) so transfer progress/completion notifications still show.
- The manifest no longer declares unused Bluetooth/Nearby/location permissions.

## Android emulator ↔ desktop discovery

The emulator runs behind a NAT, so UDP broadcast does not cross to the host. To
connect a **desktop app** (sender) to an **emulator** (receiver), forward the
service port and connect via the emulator's host alias (`10.0.2.2`):

```sh
adb shell ip route | grep default   # note the 10.0.2.x gateway
adb forward tcp:48732 tcp:48732     # host:48732 -> emulator:48732
```

Then in the desktop app just tap the emulator device (its beacon is unicast to
the host alias `10.0.2.2` automatically).

To connect an **emulator** (sender) to a **desktop** (receiver), use the
**"Connect by IP"** link button in the discovery screen and enter the host
alias:

```
IP: 10.0.2.2    Port: 48732
```

For two real devices on the same Wi-Fi, broadcast discovery works with no setup.

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





1. Large file transfer approx 4-20 gb file transfer using the concurrent file transfer for faster trasfer for files and chunks. the issue is selected file is not showing properly after selection and takes too long time to load the file . first need to fix that by instead of taking whole file firstly take file path and show the file in the app before share and untill he shares it it will be in the page except when go back or remove it . and when click on the send file then transfer it with runtime instead of creating all the chunks firstly so that the app will not crash and only some of the data like 10-40 % more than the current chunk need to load so that the app will not crash and works fine in everywhere. 
2. file allow opening using system ones if cant find . also the files are unable to open properly (shows file not found even though recentky transfered). store the true paths.

