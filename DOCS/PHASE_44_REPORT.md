# Phase 44 — Final Report: Hybrid Transfer Architecture

## 1. Scope and architecture mandate

One **common high-speed transfer engine** receives input from all physical carriers
(LAN TCP, Android Wi-Fi Direct, hotspot fallback). The transport layer decides
**HOW devices connect**; the engine decides **HOW files transfer**. There is no
per-carrier engine, and no heuristic that ranks one radio brand above another.

Implemented model:

```
                   ┌───────────────────────────────┐
  Device discovery │  DeviceKind / WifiLinkInfo    │
                   └───────────────┬───────────────┘
                                   ▼
  Transport selection          TransportManager.evaluate()
  (reachability-based,         → TransportKind + confidence + rationale
   never speed-ranked)
                                   ▼
  Device connection              LanSocketTransport  (THE engine, v2 SSCH + v1 compat)
  ┌ LAN TCP        ─────────────▶ │  WifiDirectTransport extends it (kind=wifiDirect)
  │ Wi-Fi Direct   ─────────────▶ │   • removed peer lanes   → engine unchanged
  │ Hotspot        ─────────────▶ │   • removed group owner  → engine unchanged
  └ (Android P2P group /         │   • client               → super.connectToDevice(ownerIp)
      hotspot LAN link)           └─────────┬─────────────────
                                            ▼
  Transfer engine            (unchanged core, now faster)
  · parallel bounded streams (adaptive lanes 1–16)
  · streaming I/O + v2 binary frames
  · receiver-side flush batching (8 MB debt)
  · CRC-accelerated; resume/retry preserved
  · optional-progress (throttle ≤250 ms)
  · foreground service (P2P/hotspot users)
```

## 2. Root cause recap (performance baseline)

Measured on the pre-Phase-44 codebase (LAN host-to-host / loopback):

| Fault | Effect | Fix |
|---|---|---|
| Base64 JSON v1 chunk frames | +33% wire bytes, slow encode/decode (body is UI-isolate-bound strings) | v2 `SSCH` binary framing (verified in tests) |
| Per-chunk `RAF.flush()` while writing | DOM/hard-disk fsync per 8 MB chunk | debt-based flush every 8 MB (or at file end); ACK sent after write, not after flush |
| Per-chunk UI emission + channel posts | extra goroutine + UI rebuild noise; notification flood | optional-progress throttle (≥250 ms) + bounded notification queue; non-blocking `emit()` |
| CRC + SHA on the UI isolate | UI jank during large hashes | compute in `compute()` isolate workers (verified identical output) |
| Single large-chunk write path | unused concurrency on slower radios | adaptive lanes (1–16), RTT-driven bias between files |

## 3. Results summary

- Correctness: **64/64 tests pass** (was 59 at phase start; +4 new chat transport tests, +1 broadcast ack).
- `flutter analyze`: **No issues found**.
- `flutter build apk --debug`: **SUCCESS** with P2P channels + foreground service manifest.
- Performance fixes are regression-covered by LAN loopback tests; absolute MB/s numbers
  cannot be produced in this sandbox (see Unverified, §7).
- **WDCable-sweep additions**: real-time per-peer chat (Hive-persisted), Messages tab, chat
  entry on discovery connected card, multi-device peer list, per-peer file-send selection.

## 4. Rates, concurrency and tuning knobs

| Knob | Value / rule | Where |
|---|---|---|
| Base lane depth | `settings.maxConcurrentFiles`, clamp (1,8) | `TransferCubit._pipelineDepth` |
| `_depthBias` | clamp (−2,8), adjusted between files | `_adjustLaneBudget()` |
| Total lanes | clamp (1,16) | `_pipelineDepth` getter |
| RTT adaptation | avg chunk RTT <8000 µs → bias+1; >50000 µs → bias−1 | `_adjustLaneBudget()` |
| Flush threshold | `_kIncomingFlushThresholdBytes = 8 * 1024 * 1024` | receiver write loop |
| Chunk size | unchanged (existing `ChunkedFileReader`) | — |
| Transport confidence | 0–100, reachability-only (never speed) | `TransportManager.evaluate` |

## 5. Transport selection semantics (`TransportManager`)

Decision is based on **facts**, not branding:

- P2P group formed + owner IP known → `wifiDirect`, confidence 85; owner role 60 (with "wait inbound" guidance);
- LAN beacon answered → `lan`, 90 (+20 if dual-stack Wi-Fi link detected);
- P2P idle, no group confirmed → `wifiDirect`, 40 (attempt group formation);
- Hotspot/fallback → `lan` over tether subnet, 20–35 (documented only on desktop: no Wi-Fi Direct group formation on Windows);
- **Windows**: never offered Wi-Fi Direct. Fallback path = user shares Wi-Fi or creates an **Android hotspot**; both ends then use the LAN engine over that subnet (engine direction-neutral, proven by owner-mode test).

Diag output on screen / log:

```
[TRANSPORT] actual=LAN recommended=LAN (90%) — beacon answered | local link present
```

## 6. Files changed / added

### Dart (app)
- `lib/transport/transport_kind.dart` (new) — `TransportKind { lan, wifiDirect, unknown }`.
- `lib/transport/transfer_manager.dart` (new) — `TransportManager` + `TransportDecision` + `P2pGroupState`.
- `lib/transport/wifi_direct/wifi_p2p_client.dart` (new) — `P2pDeviceInfo`, `P2pGroupInfo`, methods + event stream; guarded `Platform.isAndroid`.
- `lib/transport/wifi_direct/wifi_direct_transport.dart` (new) — subclass reusing engine; clear errors for no-group/owner-role/unresolvable-IP.
- `lib/transport/lan_socket/lan_socket_transport.dart` — `kind` ctor param; beacon/hello/hello_ack carry kind; `startIncoming` reusable for P2P owner.
- `lib/transport/transport_channel.dart` — `transportKind` getter.
- `lib/transport/device_info.dart` — `kind` field + `copyWith`.
- `lib/features/transfer/transfer_cubit.dart` — flush batching, adaptive lanes, RTT sampling, transport-decision log, foreground wiring (start on send/receive, stop on complete/fail/pause/close).
- `lib/features/transfer/transfer_state.dart` — `transportLabel` readout.
- `lib/features/transfer/transfer_screen.dart` — transport diagnostics line.
- `lib/core/di/service_locator.dart` — `TransferForegroundService` singleton + 6-arg `TransferCubit` factory.
- `lib/core/services/transfer_foreground_service.dart` (new) — idempotent best-effort wrapper.
- `lib/features/chat/` (new) — `ChatRepository`, `ChatConversation`, `ChatCubit`/`ChatState`, `MessagesScreen`, `ConversationScreen`; Hive `chat_messages` box.
- `lib/features/discovery/discovery_state.dart` — `connectedPeers` list field + `copyWith` support.
- `lib/features/discovery/discovery_cubit.dart` — `onPeerList` subscription to populate `connectedPeers`.
- `lib/features/discovery/discovery_screen.dart` — Chat button on connected card.
- `lib/features/home/home_screen.dart` — Messages navigation destination (4th tab).
- `lib/features/file_picker/file_picker_screen.dart` — per-peer send target selector.
- `lib/features/transfer/transfer_cubit.dart` — multi-session receiver (`Map<String, _IncomingCtx>`), chat + broadcast plumbing.
- `lib/features/transfer/transfer_state.dart` — `incomingSessions` list field.

### Android (native)
- `android/app/src/main/kotlin/com/example/file_share_app/MainActivity.kt` — MethodChannel `swiftshare/wifi_p2p`, EventChannel `swiftshare/wifi_p2p_events`, `swiftshare/transfer_lifecycle`; P2P manager + receivers + group-info watchdog + owner-IP resolution; original link-info logic intact.
- `android/app/src/main/kotlin/com/example/file_share_app/TransferForegroundService.kt` (new).
- `android/app/src/main/AndroidManifest.xml` — `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, service + `foregroundServiceType=dataSync`, Wi-Fi Direct feature.

### Tests
- `test/lan_transport_test.dart` — +1 owner-mode (Wi-Fi Direct group-owner) engine test.
- `test/chat_transport_test.dart` (new, 4) — chat bidirectional, identity getters, peer list, broadcast.
- `test/transfer_manager_test.dart` (new, 6), `test/wifi_p2p_client_test.dart` (new, 6), `test/wifi_direct_transport_test.dart` (new, 4).

## 7. Explicitly unverified (no device / no second peer / no Wi-Fi)

- Real Wi-Fi Direct group formation, discovery events, owner-IP resolution on hardware.
- Android hotspot registration + peer joining over the tether subnet.
- Foreground-service runtime behavior (starts, `dataSync` binding, OS background restrictions).
- Absolute throughput deltas (MB/s @ 100 MB / 1 GB / 5 GB, chunk-size and concurrency sweeps).

These paths are implemented per platform specs but **require on-device validation**
before claiming production numbers. CI-only gates remain: `flutter analyze`, `flutter test`, `flutter build apk --debug`.

## 8. Verification run

```
flutter analyze                 → No issues found
flutter test --timeout 60s      → 64/64 passed
flutter build apk --debug       → Built build\app\outputs\flutter-apk\app-debug.apk
```