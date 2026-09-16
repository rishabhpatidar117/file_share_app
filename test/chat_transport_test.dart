import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftshare/transport/lan_socket/lan_socket_transport.dart';
import 'package:swiftshare/transport/device_info.dart';
import 'package:swiftshare/transport/transport_channel.dart';

/// Exercises the chat layer and multi-device bookkeeping of the real LAN
/// transport over loopback: two peers chat bidirectionally, identity getters
/// work, and onPeerList emits on connect/disconnect.
void main() {
  late LanSocketTransport receiver;
  late LanSocketTransport sender;

  setUp(() async {
    receiver = LanSocketTransport()..setDeviceName('Receiver');
    sender = LanSocketTransport()..setDeviceName('Sender');
    await receiver.startIncoming();
  });

  tearDown(() async {
    await sender.disconnect();
    await receiver.disconnect();
  });

  Future<void> waitForState(LanSocketTransport t, TransportState expected,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (t.state != expected) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for state $expected (was ${t.state})');
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> connectSenderToReceiver() async {
    await sender.connectToDevice(const DeviceInfo(
      id: 'loopback',
      name: 'Loopback',
      address: '127.0.0.1',
      port: LanSocketTransport.servicePort,
    ));
    await waitForState(sender, TransportState.connected);
    await waitForState(receiver, TransportState.connected);
  }

  // -------------------------------------------------------------------------
  // Chat tests
  // -------------------------------------------------------------------------

  test('two peers exchange chat messages in both directions', () async {
    final gotOnA = Completer<ChatMessage>();
    final gotOnB = Completer<ChatMessage>();
    receiver.onChatReceived.listen(gotOnA.complete);
    sender.onChatReceived.listen(gotOnB.complete);

    await connectSenderToReceiver();

    // sender → receiver
    final peerAId = sender.connectedPeers.first.deviceId;
    expect(peerAId, isNotEmpty);
    await sender.sendChat(peerAId, 'hello from sender');
    final onA = await gotOnA.future.timeout(const Duration(seconds: 5));
    expect(onA.text, 'hello from sender');
    expect(onA.senderName, 'Sender');

    // receiver → sender
    final peerBId = receiver.connectedPeers.first.deviceId;
    await receiver.sendChat(peerBId, 'hi back');
    final onB = await gotOnB.future.timeout(const Duration(seconds: 5));
    expect(onB.text, 'hi back');
    expect(onB.senderName, 'Receiver');
  });

  test('deviceId/deviceName identity getters reflect setDeviceName', () {
    expect(receiver.deviceId, isNotEmpty);
    expect(receiver.deviceName, 'Receiver');
    expect(sender.deviceId, isNotEmpty);
    expect(sender.deviceName, 'Sender');
  });

  test('onPeerList reports peer and clears on disconnect', () async {
    final peerLists = <List<PeerConnection>>[];
    receiver.onPeerList.listen(peerLists.add);

    await connectSenderToReceiver();
    await Future.delayed(const Duration(milliseconds: 100));
    expect(peerLists, isNotEmpty);
    expect(peerLists.last, hasLength(1));
    expect(peerLists.last.first.deviceName, 'Sender');

    await sender.disconnectPeers();
    await Future.delayed(const Duration(milliseconds: 100));
    expect(peerLists.last, isEmpty);
  });

  test('broadcast sends without error and recipient receives the message', () async {
    final received = <ChatMessage>[];
    receiver.onChatReceived.listen(received.add);

    await connectSenderToReceiver();
    await sender.sendChatBroadcast('hello everyone');
    await Future.delayed(const Duration(milliseconds: 200));
    expect(received, hasLength(1));
    expect(received.first.text, 'hello everyone');
  });
}