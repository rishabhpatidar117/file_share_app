# On-Device Validation Checklist — Phase 44

Use this to close the "Explicitly unverified" section of `PHASE_44_REPORT.md` (§7).
Run on real hardware; the CI gate (`flutter analyze`, `flutter test --timeout 60s`,
`flutter build apk --debug`) does NOT cover any of this.

## 0. Prerequisites

- [ ] Two Android devices (A = owner-capable, B = client) with Wi-Fi enabled.
- [ ] One Windows host with Wi-Fi for the hotspot-fallback scenario (or a second
      Android acting as hotspot).
- [ ] `adb` available; both devices show in `adb devices` and are authorized.
- [ ] Build the test APK: `flutter build apk --release`
      → `build\app\outputs\flutter-apk\app-release.apk`
- [ ] Install on both devices: `adb -s <device> install path\to\app-release.apk`
- [ ] Grant all runtime permissions on first launch (Nearby/location, notifications,
      storage per Android version).
- [ ] Baseline captured **before** any Phase-44 change (see §7 benchmarks).

## 1. Logging harness

Enable app logs while testing:

```
adb -s <device> logcat -c
adb -s <device> logcat -v time | findstr /i "swiftshare TRANSFER TRANSPORT WIFIDIRECT flutter"
```

Key log anchors you must observe:
- `[TRANSFER] session=... files=... ver=2` — engine accepts a v2 binary session.
- `[TRANSFER] lanes=... avgChunkRtt=...us` — adaptive lanes active.
- `[TRANSPORT] actual=... recommended=... (NN%) — ...` — decision fired.
- `[WIFIDIRECT] connecting to group owner ...` — P2P client path chosen.

## 2. LAN TCP baseline (both devices on the same AP)

- [ ] A → B single file 100 MB completes; received file SHA-256 == source.
- [ ] Duplex: A→B and B→A in parallel both complete with correct hashes.
- [ ] Cancel mid-transfer, re-send same file → resumes (not full re-send).
- [ ] Kill app mid-file, re-send → parity points used (no corruption).
- [ ] Lock both screens mid-transfer → no stall, no crash (engine not UI-bound).

### LAN concurrency sweep (all must pass integrity)
| maxConcurrentFiles | result (OK/fail) |
|---|---|
| 1  | [ ] |
| 2  | [ ] |
| 4  | [ ] |
| 8  | [ ] |

## 3. Wi-Fi Direct (discovery + group + owner)

### 3a. Group formation
- [ ] A and B on same screen; A starts discovery (`swiftshare/wifi_p2p → startDiscovery`).
- [ ] B appears in A's event sink (`wifi_p2p_events`, `onPeersChanged`).
- [ ] A connects to B → `connectTo` completes; group formed (`getGroupInfo` returns `GroupInfo` with owner info and `p2pGroupStarted=true`).
- [ ] Negotiation creates BOTH configurations across 2 runs:
      - [ ] Run 1: A becomes **group owner** (verifies owner path).
      - [ ] Run 2: B becomes **group owner** (verifies client path).
- [ ] `logcat` shows `groupOwnerAddress ^\d+\.\d+\.\d+\.\d+$` resolved; if `groupOwnerAddress` path fails, p2p0 interface enumeration logs the IP.

### 3b. Transfer over P2P
- [ ] Client role: send 500 MB from client → owner; file hash correct; `[WIFIDIRECT] connecting to group owner ...` logged.
- [ ] Owner role: start transfer from the owner device while B is connected inbound; file hash correct (exercises the owner-mode engine path proven by `test/lan_transport_test.dart`).
- [ ] Pause/resume during a P2P transfer (group stays formed).
- [ ] Both devices move >10 m apart mid-transfer → stall then recover or clean error (no hang).
- [ ] Disconnect group → both ends return to discovery state, no leaked sockets (`disconnectGroup`).

### 3c. Negative cases
- [ ] Connect while another app owns the P2P channel → graceful error surfaced, no crash.
- [ ] Owner IP unavailable (group state unknown) → stated `TransportException`, decision falls back to `lan`.
- [ ] We ARE the owner → no deadlock; user is told to start the send from the owner (hold/open incoming).

## 4. Hotspot fallback (Windows ↔ Android)

- [ ] Android A creates a hotspot (5 GHz or 2.4 GHz), A and Windows host on that SSID.
- [ ] Host PCs and A discover each other via LAN beacon (`lan` decision, confidence ≥35).
- [ ] 1 GB A → Windows and Windows → A; both complete, hashes correct.
- [ ] A hotspot toggled (AP switch) mid-transfer → transfer errors cleanly and restarts on reconnect.

## 5. Foreground service

- [ ] Sending or receiving on P2P/hotspot auto-starts the service:
      `logcat | findstr "TransferForegroundService"` and Android settings → Apps → Swiftshare → *Running*.
- [ ] A persistent notification (id 7002, foreground) is visible in the shade.
- [ ] Background both apps mid-transfer then lock → transfer continues to completion.
- [ ] Service stops (no lingering notification) after: complete, cancel, pause, and peer disconnect.
- [ ] Repeat while the device has "Background activity limits"/Doze enabled (Android 12+ aggressive battery options) — confirm the service survives Doze for ≥10 min.

## 6. Notifications & diagnostics readout

- [ ] Progress notification throttle: posts ≤1 per 250 ms during bursty transfer (UI stays smooth).
- [ ] Terminal notification (complete/failed) appears immediately even during throttling.
- [ ] Cancel from notification clears pending progress + stops service.
- [ ] Transfer screen shows transport line, e.g. `LAN • Wi-Fi Direct (85%)`, matching `[TRANSPORT]` log on the same session.
- [ ] `networkInfo.summaryLabel` reflects the active link while on P2P and on hotspot.

## 7. Benchmarks (record before/after, same device pair, same file cache state)

| scenario | pre-44 (MB/s) | post-44 (MB/s) | delta |
|---|---|---|---|
| 100 MB LAN | | | |
| 1 GB LAN | | | |
| 5 GB LAN | | | |
| 500 MB P2P owner→client | n/a (was slower) | | |
| 1 GB hotspot A↔Windows | | | |
| 1 GB duplex LAN | | | |

Sweeps (post-44 only):
- Chunk size: 1 MB / 4 MB / 8 MB / 16 MB → record MB/s + peak lanes per setting.
- Concurrency 1/2/4/8: record MB/s + `[TRANSFER] lanes=` at steady state.
- Target: LAN ≥ pre-44 (flush batching + binary frames must never regress), P2P within 20% of same-devices-over-LAN AP bandwidth.

## 8. Final regression gate on every device used

- [ ] `flutter analyze` → No issues found
- [ ] `flutter test --timeout 60s` → 59/59 passed
- [ ] `flutter build apk --debug` → SUCCESS
- [ ] After all field tests: re-pair fresh device pair, run §2/§3 once more (no state leakage).

## 9. Results sign-off

| section | status | notes / timestamps |
|---|---|---|
| §2 LAN baseline | | |
| §3 Wi-Fi Direct | | |
| §4 Hotspot fallback | | |
| §5 Foreground service | | |
| §6 Notifications & diagnostics | | |
| §7 Benchmarks | | |
| §8 Regression gate | | |

- [ ] All §7 unverified items in `DOCS/PHASE_44_REPORT.md` updated with measured numbers.

Signed-off by: ______________________   Date: ____________