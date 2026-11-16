import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/utils/error_message.dart';

/// Kinds of content a student can report. These match the `target_type` values
/// accepted by the `report_content` database function.
enum ReportTarget {
  post('post'),
  reply('reply'),
  message('message'),
  officialPost('official_post'),
  officialReply('official_reply');

  const ReportTarget(this.value);
  final String value;
}

const reportReasons = <String, String>{
  'harassment': 'Harassment or bullying',
  'hate': 'Hate or discrimination',
  'sexual': 'Sexual content',
  'violence': 'Violence or threats',
  'self_harm': 'Self-harm',
  'spam': 'Spam',
  'other': 'Something else',
};

/// Asks the student for a reason and sends the report. The author is never
/// revealed to the reporter, and moderators review reports without author
/// identity. Shows a confirmation or a friendly error afterwards.
Future<void> reportContent(
  BuildContext context, {
  required ReportTarget target,
  required String targetId,
}) async {
  final choice = await showDialog<({String reason, String details})>(
    context: context,
    builder: (_) => const _ReportDialog(),
  );
  if (choice == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    await Supabase.instance.client.rpc(
      'report_content',
      params: {
        'p_target_type': target.value,
        'p_target_id': targetId,
        'p_reason': choice.reason,
        'p_details': choice.details.isEmpty ? null : choice.details,
      },
    );
    messenger.showSnackBar(
      const SnackBar(content: Text('Thanks. Your report was sent to moderators.')),
    );
  } catch (error) {
    debugPrint('REPORT ERROR: $error');
    messenger.showSnackBar(SnackBar(content: Text(friendlyError(error))));
  }
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog();

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  final _details = TextEditingController();
  String? _reason;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Report this content'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RadioGroup<String>(
                groupValue: _reason,
                onChanged: (value) => setState(() => _reason = value),
                child: Column(
                  children: [
                    for (final entry in reportReasons.entries)
                      RadioListTile<String>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: entry.key,
                        title: Text(entry.value),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _details,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Details (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _reason == null
              ? null
              : () => Navigator.pop(context, (
                  reason: _reason!,
                  details: _details.text.trim(),
                )),
          child: const Text('Send report'),
        ),
      ],
    );
  }
}
