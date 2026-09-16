# Phase 45 — Report: Wi-Fi Direct integration + transfer persistence

## 1. Scope

Fixes four production issues reported against the built app (all verified by
`flutter analyze` + 64/64 tests + debug APK build):

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | Files never transfer over Wi-Fi Direct; no permission prompt on startup | `transport_io.dart` always created `LanSocketTransport()` (never `WifiDirectTransport`); only `POST_NOTIFICATIONS` was ever requested at runtime | Android now uses `WifiDirectTransport`; new `swiftshare/permissions` channel requests `ACCESS_FINE_LOCATION` (≤API 32) / `NEARBY_WIFI_DEVICES` (API 33+) at startup |
| 2 | Receiver sees no live progress; connection drops when either user switches screens | `DiscoveryScreen.dispose()` called `disconnectPeer()` unconditionally, tearing down the peer TCP link on navigation | `dispose()` now only stops discovery/listening (beacon + server socket); the transport singleton keeps the peer socket alive across screens |
| 3 | QR scan always connects by IP over the LAN; no Wi-Fi Direct path offered | The transport never exposed P2P peer discovery, and `connectToDevice` had no fallback or UI | Wi-Fi Direct peers now surface in the device list with a badge (via `wifiP2pClient` stream); tapping one forms the P2P group and resolves the owner IP before the TCP connect |
| 4 | Transfer stops when you navigate away; no way back to the transfer screen | TransferScreen was only reachable through the screen that started it | App-level `TransferOverlay` (in `MaterialApp.builder`, above every route) shows live sender/receiver progress and opens TransferScreen from anywhere |

## 2. Wi-Fi Direct transport (Android)

- `TransportChannel` gains `WifiP2pClient? get wifiP2pClient => null`; `WifiDirectTransport` overrides it.
- `transport_io.dart` now returns `WifiDirectTransport()` on Android, pure LAN sockets elsewhere.
- `WifiDirectTransport.connectToDevice` gained a safe fallback: a device carrying an explicit IP (QR / manual connect) bypasses the P2P group logic and connects directly — so existing workflows still work on Android.
- `DiscoveryCubit` subscribes to P2P peer events, maps peers to `DeviceInfo(kind: wifiDirect)`, and adds `connectWifiDirect()` which: `p2p.connectTo(mac)` → polls group info (30 s timeout) → resolves owner IP → connects the engine; if this device becomes the group owner it binds the listener and waits for the client's inbound TCP.
- `MainActivity.kt` now auto-accepts incoming group requests in `WIFI_P2P_CONNECTION_CHANGED_ACTION` (calls `connect()` with the remote address) so no extra tap is needed, and exposes the permission channel.

## 3. Transfer persistence + return path

- Root cause of "receiver progress not live / connection breaks": `dispose()` → `disconnectPeer()`. Removed; the TCP peer link now survives navigation (matches the transfer engine's singleton lifecycle).
- New `TransferOverlay` widget is injected via `MaterialApp.builder` so it layers above **every** route (home tabs, discovery, chat, file picker, settings). It shows percentage + progress bar for either an outgoing session or an incoming one, and tapping it pushes `TransferScreen` for any state of the transfer.

## 4. Verification

- `flutter analyze` → No issues found.
- `flutter test` → 64/64 pass (3 Wi-Fi Direct tests updated to use address-less P2P peers so they exercise group-role logic rather than the new IP fallback).
- `flutter build apk --debug` → success.

## 5. Files touched

| File | Change |
|------|--------|
| `lib/features/transfer/transfer_overlay.dart` | new app-level overlay |
| `lib/app/app.dart` | `MaterialApp.builder` stack with `TransferOverlay` |
| `lib/features/home/home_screen.dart` | removed tab-local banner (superseded by overlay) |
| `lib/features/discovery/discovery_screen.dart` | P2P badge, `connectWifiDirect` routing, dispose keeps peer link alive |
| `lib/features/discovery/discovery_cubit.dart` | P2P peer subscription, `connectWifiDirect`, owner-IP polling |
| `lib/transport/platform/transport_io.dart` | Android → `WifiDirectTransport()` |
| `lib/transport/transport_channel.dart` | `wifiP2pClient` getter |
| `lib/transport/wifi_direct/wifi_direct_transport.dart` | IP fallback + `wifiP2pClient` override |
| `lib/core/services/permission_service.dart` | `requestWifiDirectPermissions()` |
| `lib/main.dart` | requests Wi-Fi Direct permissions at startup |
| `android/.../MainActivity.kt` | permission channel + auto-accept of incoming P2P group |
| `test/wifi_direct_transport_test.dart` | tests use address-less P2P peers |

## 6. On-device validation (manual, not yet run by user)

1. Fresh install on Android 13+: confirm the Wi-Fi Direct permission dialog appears at first launch.
2. Receive mode on device A + send mode on device B on the same LAN: B should now also list A under a "Wi-Fi Direct" badge when nearby; tapping it forms a P2P group (A auto-accepts) and transfers start over the P2P interface.
3. During a transfer, navigate to Home/another tab or push any screen: the bottom overlay keeps showing progress and tapping it reopens the transfer screen.
4. QR scan still connects over IP (unchanged path); the Wi-Fi Direct option is now the peer badge / manual connection.