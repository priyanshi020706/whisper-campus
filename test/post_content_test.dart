import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/models/post_content.dart';

void main() {
  previewTests();
  group('PostContent', () {
    test('encode then decode keeps title, tags and body', () {
      const original = PostContent(
        title: 'Lab timing',
        tags: ['Urgent', 'Academic'],
        body: 'Is the lab open on Sunday?',
      );

      final decoded = PostContent.decode(original.encode());

      expect(decoded.title, original.title);
      expect(decoded.tags, original.tags);
      expect(decoded.body, original.body);
    });

    test('plain text without the marker becomes the body', () {
      final decoded = PostContent.decode('just a normal post');

      expect(decoded.title, isEmpty);
      expect(decoded.tags, isEmpty);
      expect(decoded.body, 'just a normal post');
    });

    test('broken encoded content falls back to the raw text', () {
      const broken = 'WC_POST_V1:{not json';

      expect(PostContent.decode(broken).body, broken);
    });

    test('encoded content that is not a JSON object falls back', () {
      const notAnObject = 'WC_POST_V1:[1,2,3]';

      expect(PostContent.decode(notAnObject).body, notAnObject);
    });

    test('non-string tags are ignored', () {
      final decoded = PostContent.decode(
        'WC_POST_V1:{"title":"t","tags":["Tea",5,null],"body":"b"}',
      );

      expect(decoded.tags, ['Tea']);
    });

    test('displayText joins the non-empty parts', () {
      const content = PostContent(title: 'T', tags: ['Tea'], body: 'B');
      const bodyOnly = PostContent(title: '', tags: [], body: 'B');

      expect(content.displayText, 'T\n\nTea\n\nB');
      expect(bodyOnly.displayText, 'B');
    });
  });
}

void previewTests() {
  group('PostContent.previewText', () {
    test('plain text is returned as is', () {
      expect(PostContent.previewText('  hello there '), 'hello there');
    });

    test('a complete encoded post shows title and body, not the encoding', () {
      const post = PostContent(title: 'Lab', tags: ['Urgent'], body: 'Open?');

      expect(PostContent.previewText(post.encode()), 'Lab · Open?');
    });

    test('a post cut off mid-body still reads cleanly', () {
      const cut =
          'WC_POST_V1:{"title":"faltu log","tags":[],"body":"most faltu nithha';

      expect(PostContent.previewText(cut), 'faltu log · most faltu nithha');
    });

    test('a post cut off inside the title', () {
      const cut = 'WC_POST_V1:{"title":"kuute ki dum sid';

      expect(PostContent.previewText(cut), 'kuute ki dum sid');
    });

    test('a cut in the middle of an escape sequence does not break', () {
      // Real JSON escape: one backslash, then u00e (cut before the 4th digit).
      const cut = r'WC_POST_V1:{"title":"hi","tags":[],"body":"caf\u00e';

      expect(PostContent.previewText(cut), 'hi · caf');
    });

    test('escaped quotes and newlines are decoded', () {
      const cut = r'WC_POST_V1:{"title":"say \"hi\"","tags":[],"body":"a\nb';

      expect(PostContent.previewText(cut), 'say "hi" · a\nb');
    });

    test('an encoded post with no text falls back to a label', () {
      expect(PostContent.previewText('WC_POST_V1:{"tags":["Tea"]'), 'Post');
    });
  });
}
