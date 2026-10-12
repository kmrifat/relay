import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The chat panel on the right of every page: open or not, and which
/// agent a new chat goes to.
class ChatState {
  const ChatState({this.open = false, this.agentId});
  final bool open;
  final String? agentId;
}

class ChatNotifier extends Notifier<ChatState> {
  @override
  ChatState build() => const ChatState();

  void toggle() => state = ChatState(open: !state.open, agentId: state.agentId);
  void close() => state = ChatState(agentId: state.agentId);

  /// Opens the panel on a chat with [agentId].
  void openWith(String agentId) => state = ChatState(open: true, agentId: agentId);
}

final chatProvider = NotifierProvider<ChatNotifier, ChatState>(ChatNotifier.new);
