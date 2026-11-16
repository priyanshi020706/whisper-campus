import 'package:flutter/material.dart';

import '../../models/post_content.dart';

/// What an edit of a stored post looks like to the user. Posts written by the
/// app are stored as an encoded title, tags and body; older plain posts have
/// only text and stay plain unless the author adds a title or tags.
class EditedPost {
  const EditedPost({required this.title, required this.tags, required this.body});

  final String title;
  final List<String> tags;
  final String body;

  /// The text to store.
  String encode({required bool wasEncoded}) {
    if (!wasEncoded && title.isEmpty && tags.isEmpty) return body;
    return PostContent(title: title, tags: tags, body: body).encode();
  }
}

/// Checks an edit and returns a message for the user, or null when it is fine.
String? validateEditedPost(
  EditedPost post, {
  required bool wasEncoded,
  required bool hasImage,
}) {
  if (post.title.isEmpty && post.body.isEmpty && !hasImage) {
    return 'Add some text or keep the image.';
  }
  if (wasEncoded && post.title.isEmpty && !hasImage && post.body.isEmpty) {
    return 'Add a title.';
  }
  final stored = post.encode(wasEncoded: wasEncoded);
  if (stored.length > postContentLimit) {
    return 'That is too long. Shorten it a little.';
  }
  return null;
}

/// Lets the author change a post's title, tags and text. Returns the new stored
/// text, or null if cancelled.
Future<String?> showEditPostDialog(
  BuildContext context, {
  required String initialContent,
  bool hasImage = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) =>
        _EditPostDialog(initialContent: initialContent, hasImage: hasImage),
  );
}

class _EditPostDialog extends StatefulWidget {
  const _EditPostDialog({required this.initialContent, required this.hasImage});

  final String initialContent;
  final bool hasImage;

  @override
  State<_EditPostDialog> createState() => _EditPostDialogState();
}

class _EditPostDialogState extends State<_EditPostDialog> {
  late final bool _wasEncoded = widget.initialContent.startsWith('WC_POST_V1:');
  late final PostContent _initial = PostContent.decode(widget.initialContent);
  late final _title = TextEditingController(text: _initial.title);
  late final _body = TextEditingController(text: _initial.body);
  late final Set<String> _tags = {..._initial.tags};
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _save() {
    final post = EditedPost(
      title: _title.text.trim(),
      tags: _tags.toList(),
      body: _body.text.trim(),
    );
    final problem = validateEditedPost(
      post,
      wasEncoded: _wasEncoded,
      hasImage: widget.hasImage,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(post.encode(wasEncoded: _wasEncoded));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit post'),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _title,
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final tag in postTagOptions)
                  FilterChip(
                    label: Text(tag),
                    selected: _tags.contains(tag),
                    onSelected: (on) => setState(() {
                      on ? _tags.add(tag) : _tags.remove(tag);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Text',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Lets the author change the text of a comment. Returns the new text, or null
/// if cancelled.
Future<String?> showEditCommentDialog(
  BuildContext context, {
  required String initialText,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _EditCommentDialog(initialText: initialText),
  );
}

class _EditCommentDialog extends StatefulWidget {
  const _EditCommentDialog({required this.initialText});

  final String initialText;

  @override
  State<_EditCommentDialog> createState() => _EditCommentDialogState();
}

class _EditCommentDialogState extends State<_EditCommentDialog> {
  late final _controller = TextEditingController(text: widget.initialText);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'A comment cannot be empty.');
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit comment'),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: TextField(
          controller: _controller,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          maxLength: 2000,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            errorText: _error,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// How long after posting a post or comment can still be edited. The server
/// enforces the same limit.
const editWindow = Duration(minutes: 10);

bool canStillEdit(DateTime createdAt, {DateTime? now}) =>
    (now ?? DateTime.now()).difference(createdAt) < editWindow;
