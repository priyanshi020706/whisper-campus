import 'package:flutter/material.dart';

import '../../models/poll.dart';

/// How long a poll stays open.
enum PollDuration {
  none('No end', null),
  hour('1 hour', Duration(hours: 1)),
  day('1 day', Duration(days: 1)),
  threeDays('3 days', Duration(days: 3)),
  week('7 days', Duration(days: 7));

  const PollDuration(this.label, this.length);

  final String label;
  final Duration? length;
}

/// Asks the user to write a poll. Returns the draft, or null if cancelled.
/// [confirmLabel] is the button text ("Send poll" in chat, "Add poll" on a post).
Future<PollDraft?> showCreatePollSheet(
  BuildContext context, {
  String title = 'Create poll',
  String confirmLabel = 'Create poll',
}) {
  return showModalBottomSheet<PollDraft>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _CreatePollSheet(title: title, confirmLabel: confirmLabel),
  );
}

class _CreatePollSheet extends StatefulWidget {
  const _CreatePollSheet({required this.title, required this.confirmLabel});

  final String title;
  final String confirmLabel;

  @override
  State<_CreatePollSheet> createState() => _CreatePollSheetState();
}

class _CreatePollSheetState extends State<_CreatePollSheet> {
  static const _maxOptions = 6;

  final _question = TextEditingController();
  final List<TextEditingController> _options = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _multiple = false;
  PollDuration _duration = PollDuration.none;
  String? _error;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  void _addOption() {
    if (_options.length >= _maxOptions) return;
    setState(() => _options.add(TextEditingController()));
  }

  void _removeOption(int index) {
    if (_options.length <= 2) return;
    setState(() => _options.removeAt(index).dispose());
  }

  void _submit() {
    final texts = [for (final c in _options) c.text];
    final problem = validatePollDraft(_question.text, texts);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final length = _duration.length;
    Navigator.of(context).pop(
      PollDraft(
        question: _question.text.trim(),
        options: [
          for (final t in texts)
            if (t.trim().isNotEmpty) t.trim(),
        ],
        allowsMultiple: _multiple,
        closesAt: length == null ? null : DateTime.now().add(length),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The sheet lifts above the keyboard and scrolls, so nothing is ever hidden.
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _question,
              maxLength: 200,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Question',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < _options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _options[i],
                        maxLength: 80,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          labelText: 'Choice ${i + 1}',
                          counterText: '',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    if (_options.length > 2)
                      IconButton(
                        tooltip: 'Remove choice',
                        onPressed: () => _removeOption(i),
                        icon: const Icon(Icons.close_rounded),
                      ),
                  ],
                ),
              ),
            if (_options.length < _maxOptions)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addOption,
                  icon: const Icon(Icons.add),
                  label: const Text('Add choice'),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow multiple answers'),
              value: _multiple,
              onChanged: (v) => setState(() => _multiple = v),
            ),
            Text('Poll length', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final d in PollDuration.values)
                  ChoiceChip(
                    label: Text(d.label),
                    selected: _duration == d,
                    onSelected: (_) => setState(() => _duration = d),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.poll_outlined),
              label: Text(widget.confirmLabel),
            ),
          ],
        ),
      ),
    );
  }
}
