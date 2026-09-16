import 'dart:convert';
import 'package:hive/hive.dart';
import 'chat_conversation.dart';

class ChatRepository {
  final Box _box;

  ChatRepository(this._box);

  Future<void> saveConversation(ChatConversation conversation) async {
    await _box.put(conversation.peerId, json.encode(conversation.toJson()));
  }

  Future<ChatConversation?> getConversation(String peerId) async {
    final data = _box.get(peerId);
    if (data == null) return null;
    return ChatConversation.fromJson(json.decode(data));
  }

  Future<List<ChatConversation>> getAllConversations() async {
    final conversations = <ChatConversation>[];
    for (final key in _box.keys) {
      final data = _box.get(key);
      if (data != null) {
        conversations.add(ChatConversation.fromJson(json.decode(data)));
      }
    }
    conversations.sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));
    return conversations;
  }

  Future<void> deleteConversation(String peerId) async {
    await _box.delete(peerId);
  }
}