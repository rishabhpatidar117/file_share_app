import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import 'chat_state.dart';
import 'chat_conversation.dart';
import 'chat_repository.dart';
import '../../transport/transport_channel.dart';

/// Owns the chat feature: receives text messages from the transport, persists
/// them per peer in Hive, and sends new messages over the live peer link.
class ChatCubit extends Cubit<ChatState> {
  final TransportChannel _transport;
  final ChatRepository _repository;
  StreamSubscription<ChatMessage>? _chatSub;
  StreamSubscription<List<PeerConnection>>? _peerListSub;
  final _uuid = const Uuid();
  bool _loaded = false;

  ChatCubit(this._transport, this._repository)
      : super(ChatState(
          myDeviceId: _transport.deviceId,
          myDeviceName: _transport.deviceName,
        )) {
    _chatSub = _transport.onChatReceived.listen(_onChatReceived);
    _peerListSub = _transport.onPeerList.listen((_) {
      // Peer arrival/removal does not change the persisted thread list; the
      // listening screen derives "start a chat" entries straight from the
      // discovery state, so there is nothing to do here beyond keeping state
      // warm for the first load.
    });
  }

  String get myDeviceId => state.myDeviceId;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    emit(state.copyWith(isLoading: true));
    final conversations = await _repository.getAllConversations();
    if (isClosed) return;
    emit(state.copyWith(isLoading: false, conversations: conversations));
  }

  void _onChatReceived(ChatMessage message) {
    if (message.senderId.isEmpty || message.id.isEmpty) return;
    final conversation = state.conversationFor(message.senderId);
    final messages = [
      ...?conversation?.messages,
      message,
    ];
    final updated = ChatConversation(
      peerId: message.senderId,
      peerName: message.senderName,
      messages: messages,
    );
    _upsertConversation(updated);
  }

  /// Sends a message to one connected peer and mirrors it into the local
  /// thread (the transport stamps the same id/identity on the wire).
  Future<void> sendMessage(String peerId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _transport.sendChat(peerId, trimmed);
    _mirrorOutgoing(peerId, trimmed);
  }

  /// Broadcasts to every connected peer and mirrors one copy per peer so each
  /// thread reads like a normal one-to-one conversation.
  Future<void> sendBroadcast(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _transport.sendChatBroadcast(trimmed);
    for (final peer in _transport.connectedPeers) {
      _mirrorOutgoing(peer.deviceId, trimmed, peerName: peer.deviceName);
    }
  }

  void _mirrorOutgoing(String peerId, String text, {String? peerName}) {
    final now = DateTime.now();
    final outgoing = ChatMessage(
      id: _uuid.v4(),
      text: text,
      senderId: state.myDeviceId,
      senderName: state.myDeviceName,
      timestamp: now,
    );
    final conversation = state.conversationFor(peerId);
    final updated = ChatConversation(
      peerId: peerId,
      peerName: peerName ?? conversation?.peerName ?? 'Peer',
      messages: [...?conversation?.messages, outgoing],
    );
    _upsertConversation(updated);
  }

  Future<void> _upsertConversation(ChatConversation conversation) async {
    final conversations = List<ChatConversation>.from(state.conversations);
    final index = conversations.indexWhere((c) => c.peerId == conversation.peerId);
    if (index >= 0) {
      conversations[index] = conversation;
    } else {
      conversations.add(conversation);
    }
    conversations.sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));

    if (isClosed) return;
    emit(state.copyWith(conversations: conversations));
    await _repository.saveConversation(conversation);
  }

  @override
  Future<void> close() {
    _chatSub?.cancel();
    _peerListSub?.cancel();
    return super.close();
  }
}