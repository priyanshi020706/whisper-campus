import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/utils/error_message.dart';
import '../core/widgets/edit_dialogs.dart';

/// Talks to the server about edits. All rules (own posts only, 10 minutes, review
/// after an edit) are enforced in the database; see
/// `20261118000000_notification_settings_saved_posts_and_edits.sql`.
class PostEditService {
  PostEditService([SupabaseClient? client])
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Returns `approved` when the edit is live, or `pending` when it has gone
  /// back for a moderator's review.
  Future<String> editPost(String kind, String postId, String content) async {
    final result = await _client.rpc(
      'edit_post',
      params: {'p_kind': kind, 'p_post_id': postId, 'p_content': content},
    );
    return result as String? ?? 'approved';
  }

  Future<void> editReply(String kind, String replyId, String content) async {
    await _client.rpc(
      'edit_reply',
      params: {'p_kind': kind, 'p_reply_id': replyId, 'p_content': content},
    );
  }

  /// Edit times for the given ids, keyed by id. Items never edited are left out.
  Future<Map<String, DateTime>> editTimes(String kind, List<String> ids) async {
    if (ids.isEmpty) return const {};
    final rows = await _client.rpc(
      'get_edit_times',
      params: {'p_kind': kind, 'p_ids': ids},
    );
    return {
      for (final row in List<Map<String, dynamic>>.from(rows as List))
        row['item_id'] as String: DateTime.parse(row['edited_at'] as String),
    };
  }
}

void _say(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Edit a post: ask for the new text, save it, and tell the user what
/// happened. Returns true if the post changed (the caller should reload).
///
/// [kind] is `post` (unofficial) or `official_post`.
Future<bool> runEditPostFlow(
  BuildContext context, {
  required String kind,
  required String postId,
  required String content,
  bool hasImage = false,
  PostEditService? service,
}) async {
  final edited = await showEditPostDialog(
    context,
    initialContent: content,
    hasImage: hasImage,
  );
  if (edited == null || edited == content || !context.mounted) return false;
  try {
    final status = await (service ?? PostEditService()).editPost(
      kind,
      postId,
      edited,
    );
    if (context.mounted) {
      _say(
        context,
        status == 'pending'
            ? 'Saved. Your edit will show once a moderator reviews it.'
            : 'Post updated.',
      );
    }
    return true;
  } catch (error) {
    debugPrint('EDIT POST ERROR: $error');
    if (context.mounted) _say(context, friendlyError(error));
    return false;
  }
}

/// Edit a comment. [kind] is `reply` or `official_reply`. Returns true if the
/// comment changed.
Future<bool> runEditCommentFlow(
  BuildContext context, {
  required String kind,
  required String replyId,
  required String content,
  PostEditService? service,
}) async {
  final edited = await showEditCommentDialog(context, initialText: content);
  if (edited == null || edited == content.trim() || !context.mounted) {
    return false;
  }
  try {
    await (service ?? PostEditService()).editReply(kind, replyId, edited);
    if (context.mounted) _say(context, 'Comment updated.');
    return true;
  } catch (error) {
    debugPrint('EDIT COMMENT ERROR: $error');
    if (context.mounted) _say(context, friendlyError(error));
    return false;
  }
}
