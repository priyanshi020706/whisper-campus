import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/utils/error_message.dart';
import '../models/post_card.dart';

/// Where saved posts live.
abstract class SavedPostsSource {
  Future<Set<String>> fetchIds(String kind);
  Future<List<PostCardData>> fetchPosts();
  Future<void> setSaved(String kind, String postId, bool saved);
}

class SupabaseSavedPostsSource implements SavedPostsSource {
  SupabaseSavedPostsSource([SupabaseClient? client])
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<Set<String>> fetchIds(String kind) async {
    final rows = await _client.rpc(
      'get_my_saved_post_ids',
      params: {'p_kind': kind},
    );
    return {
      for (final row in List<Map<String, dynamic>>.from(rows as List))
        row['post_id'] as String,
    };
  }

  @override
  Future<List<PostCardData>> fetchPosts() async {
    final rows = await _client.rpc('get_my_saved_posts');
    return [
      for (final row in List<Map<String, dynamic>>.from(rows as List))
        PostCardData.fromMap(row),
    ];
  }

  @override
  Future<void> setSaved(String kind, String postId, bool saved) async {
    await _client.rpc(
      saved ? 'save_post' : 'unsave_post',
      params: {'p_kind': kind, 'p_post_id': postId},
    );
  }
}

/// Which posts the user has bookmarked, shared by the feeds (bookmark icons)
/// and the Saved posts page.
class SavedPostsController extends ChangeNotifier {
  SavedPostsController({SavedPostsSource? source})
    : _source = source ?? SupabaseSavedPostsSource();

  final SavedPostsSource _source;
  final Set<String> _keys = {};
  bool _disposed = false;

  bool isSaved(String kind, String postId) =>
      _keys.contains(postKey(kind, postId));

  int get count => _keys.length;

  /// Reads both kinds of bookmark. Failures are ignored: icons just stay empty.
  Future<void> refresh() async {
    try {
      final results = await Future.wait([
        _source.fetchIds('post'),
        _source.fetchIds('official_post'),
      ]);
      if (_disposed) return;
      _keys
        ..clear()
        ..addAll(results[0].map((id) => postKey('post', id)))
        ..addAll(results[1].map((id) => postKey('official_post', id)));
      notifyListeners();
    } catch (error) {
      debugPrint('SAVED POSTS ERROR: $error');
    }
  }

  Future<List<PostCardData>> loadPosts() => _source.fetchPosts();

  /// Saves or removes a bookmark. Returns null on success or a message.
  Future<String?> toggle(String kind, String postId) async {
    final key = postKey(kind, postId);
    final save = !_keys.contains(key);
    if (save) {
      _keys.add(key);
    } else {
      _keys.remove(key);
    }
    notifyListeners();
    try {
      await _source.setSaved(kind, postId, save);
      return null;
    } catch (error) {
      debugPrint('SAVE TOGGLE ERROR: $error');
      if (!_disposed) {
        if (save) {
          _keys.remove(key);
        } else {
          _keys.add(key);
        }
        notifyListeners();
      }
      return friendlyError(error);
    }
  }

  /// Marks a post as no longer saved (used after removing it from the list).
  void forget(String kind, String postId) {
    if (_keys.remove(postKey(kind, postId))) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
