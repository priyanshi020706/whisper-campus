import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/chat_extras.dart';
import '../models/poll.dart';

/// Talks to the server about chat replies, reactions and polls. All the rules
/// live in `20261118010000_chat_replies_reactions_and_polls.sql`.
class ChatExtrasService {
  ChatExtrasService([SupabaseClient? client])
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<ChatExtras> fetch(List<String> messageIds) async {
    if (messageIds.isEmpty) return const ChatExtras();
    final json = await _client.rpc(
      'get_chat_message_extras',
      params: {'p_message_ids': messageIds},
    );
    return ChatExtras.fromJson(json);
  }

  /// React with [emoji]; the same emoji again, or null, takes it back.
  Future<void> react(String messageId, String? emoji) async {
    await _client.rpc(
      'react_to_message',
      params: {'p_message_id': messageId, 'p_emoji': emoji},
    );
  }

  Future<void> vote(String pollId, List<String> optionIds) async {
    await _client.rpc(
      'vote_poll',
      params: {'p_poll_id': pollId, 'p_option_ids': optionIds},
    );
  }

  /// Sends a chat message that replies to [replyTo]. Returns the new message id.
  Future<String> sendReply({
    required String roomId,
    required String mode,
    required String content,
    required String replyTo,
  }) async {
    final id = await _client.rpc(
      'send_chat_message_with_reply',
      params: {
        'p_room_id': roomId,
        'p_mode': mode,
        'p_content': content,
        'p_reply_to': replyTo,
      },
    );
    return id as String;
  }

  Future<void> createPoll({
    required String roomId,
    required String mode,
    required PollDraft draft,
  }) async {
    await _client.rpc(
      'create_chat_poll',
      params: {
        'p_room_id': roomId,
        'p_mode': mode,
        'p_question': draft.question,
        'p_options': draft.options,
        'p_multiple': draft.allowsMultiple,
        'p_closes_at': draft.closesAt?.toUtc().toIso8601String(),
      },
    );
  }
}
