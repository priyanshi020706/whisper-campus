import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/models/post_card.dart';
import 'package:whisper_campus/services/saved_posts_controller.dart';

class _FakeSource implements SavedPostsSource {
  final ids = <String, Set<String>>{'post': {}, 'official_post': {}};
  Object? failWith;

  @override
  Future<Set<String>> fetchIds(String kind) async => ids[kind]!;

  @override
  Future<List<PostCardData>> fetchPosts() async => const [];

  @override
  Future<void> setSaved(String kind, String postId, bool saved) async {
    final error = failWith;
    if (error != null) throw error;
    saved ? ids[kind]!.add(postId) : ids[kind]!.remove(postId);
  }
}

void main() {
  late _FakeSource source;
  late SavedPostsController controller;

  setUp(() {
    source = _FakeSource();
    controller = SavedPostsController(source: source);
    addTearDown(controller.dispose);
  });

  test('refresh reads bookmarks of both kinds', () async {
    source.ids['post'] = {'p1'};
    source.ids['official_post'] = {'o1', 'o2'};

    await controller.refresh();

    expect(controller.isSaved('post', 'p1'), isTrue);
    expect(controller.isSaved('official_post', 'o2'), isTrue);
    expect(controller.isSaved('post', 'o1'), isFalse); // kinds do not mix
    expect(controller.count, 3);
  });

  test('saving shows at once and calls the server', () async {
    final message = await controller.toggle('post', 'p1');

    expect(message, isNull);
    expect(controller.isSaved('post', 'p1'), isTrue);
    expect(source.ids['post'], {'p1'});
  });

  test('tapping again removes the bookmark', () async {
    await controller.toggle('post', 'p1');
    await controller.toggle('post', 'p1');

    expect(controller.isSaved('post', 'p1'), isFalse);
    expect(source.ids['post'], isEmpty);
  });

  test('a refused save is undone with a message', () async {
    source.failWith = StateError('boom');

    final message = await controller.toggle('post', 'p1');

    expect(controller.isSaved('post', 'p1'), isFalse);
    expect(message, 'Something went wrong. Please try again.');
  });

  test('a refused removal puts the bookmark back', () async {
    await controller.toggle('post', 'p1');
    source.failWith = StateError('boom');

    await controller.toggle('post', 'p1');

    expect(controller.isSaved('post', 'p1'), isTrue);
  });

  test('forget drops a bookmark locally and notifies', () async {
    await controller.toggle('official_post', 'o1');
    var notified = 0;
    controller.addListener(() => notified++);

    controller.forget('official_post', 'o1');
    controller.forget('official_post', 'o1'); // already gone: no second notify

    expect(controller.isSaved('official_post', 'o1'), isFalse);
    expect(notified, 1);
  });

  test('PostCardData.fromMap reads the server row', () {
    final card = PostCardData.fromMap({
      'post_kind': 'official_post',
      'post_id': 'x',
      'room_id': 'dept-cs',
      'author_label': 'Asha A',
      'content': 'hi',
      'created_at': '2026-11-17T10:00:00+00:00',
      'like_count': 3,
      'comment_count': 2,
      'is_mine': true,
      'edited_at': '2026-11-17T11:00:00+00:00',
      'saved_at': '2026-11-17T12:00:00+00:00',
    });

    expect(card.isOfficial, isTrue);
    expect(card.imageBucket, 'official-post-images');
    expect(card.likeCount, 3);
    expect(card.isMine, isTrue);
    expect(card.editedAt, isNotNull);
    expect(card.savedAt, isNotNull);
    expect(postKey(card.kind, card.postId), 'official_post:x');
  });
}
