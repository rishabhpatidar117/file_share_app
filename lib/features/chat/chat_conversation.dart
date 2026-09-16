import '../../transport/transport_channel.dart';

/// One persisted, single-peer chat thread. Messages are ordered oldest first;
/// the stub transport and the LAN transport both stamp `ChatMessage` with the
/// peer's device id as `senderId`, so conversations key cleanly by that id.
class ChatConversation {
  final String peerId;
  final String peerName;
  final List<ChatMessage> messages;

  const ChatConversation({
    required this.peerId,
    required this.peerName,
    this.messages = const [],
  });

  DateTime get lastMessageAt =>
      messages.isEmpty ? DateTime.fromMillisecondsSinceEpoch(0) : messages.last.timestamp;

  ChatConversation copyWith({String? peerName, List<ChatMessage>? messages}) {
    return ChatConversation(
      peerId: peerId,
      peerName: peerName ?? this.peerName,
      messages: messages ?? this.messages,
    );
  }

  Map<String, dynamic> toJson() => {
        'peerId': peerId,
        'peerName': peerName,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory ChatConversation.fromJson(Map<String, dynamic> json) => ChatConversation(
        peerId: json['peerId'] as String? ?? '',
        peerName: json['peerName'] as String? ?? 'Peer',
        messages: (json['messages'] as List? ?? const [])
            .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}