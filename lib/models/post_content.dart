import 'dart:convert';

const postContentLimit = 2000;
const postTagOptions = ['Doubt/Query', 'Urgent', 'Tea', 'Academic'];
const _postContentMarker = 'WC_POST_V1:';

class PostContent {
  const PostContent({required this.title, required this.tags, required this.body});

  final String title;
  final List<String> tags;
  final String body;

  String get displayText => [
    if (title.isNotEmpty) title,
    if (tags.isNotEmpty) tags.join(' · '),
    if (body.isNotEmpty) body,
  ].join('\n\n');

  String encode() =>
      '$_postContentMarker${jsonEncode({'title': title, 'tags': tags, 'body': body})}';

  static PostContent decode(String value) {
    if (!value.startsWith(_postContentMarker)) {
      return PostContent(title: '', tags: const [], body: value);
    }
    try {
      final decoded = jsonDecode(value.substring(_postContentMarker.length));
      if (decoded is! Map<String, dynamic>) {
        return PostContent(title: '', tags: const [], body: value);
      }
      return PostContent(
        title: decoded['title'] as String? ?? '',
        tags: (decoded['tags'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        body: decoded['body'] as String? ?? '',
      );
    } on FormatException {
      return PostContent(title: '', tags: const [], body: value);
    } on TypeError {
      return PostContent(title: '', tags: const [], body: value);
    }
  }
}
