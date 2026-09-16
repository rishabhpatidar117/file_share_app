import 'chat_conversation.dart';

class ChatState {
  final bool isLoading;
  final List<ChatConversation> conversations;

  /// This device's own identity, stamped on outgoing messages so the UI can
  /// render them as leaving-side bubbles.
  final String myDeviceId;
  final String myDeviceName;

  const ChatState({
    this.isLoading = false,
    this.conversations = const [],
    this.myDeviceId = '',
    this.myDeviceName = '',
  });

  ChatState copyWith({
    bool? isLoading,
    List<ChatConversation>? conversations,
    String? myDeviceId,
    String? myDeviceName,
  }) {
    return ChatState(
      isLoading: isLoading ?? this.isLoading,
      conversations: conversations ?? this.conversations,
      myDeviceId: myDeviceId ?? this.myDeviceId,
      myDeviceName: myDeviceName ?? this.myDeviceName,
    );
  }

  ChatConversation? conversationFor(String peerId) {
    for (final c in conversations) {
      if (c.peerId == peerId) return c;
    }
    return null;
  }
}