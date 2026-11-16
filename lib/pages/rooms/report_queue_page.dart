import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/error_message.dart';
import '../../services/report_service.dart';

/// Super Admin queue for reported content. Shows the content, the reason and
/// how many strikes its author already has, but never who the author is.
class ReportQueuePage extends StatefulWidget {
  const ReportQueuePage({super.key});

  @override
  State<ReportQueuePage> createState() => _ReportQueuePageState();
}

class _ReportQueuePageState extends State<ReportQueuePage> {
  final _db = Supabase.instance.client;
  final Set<String> _working = {};
  List<Map<String, dynamic>> _reports = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _db.rpc('list_content_reports');
      if (!mounted) return;
      setState(() {
        _reports = List<Map<String, dynamic>>.from(result);
        _loading = false;
      });
    } catch (error) {
      debugPrint('REPORT QUEUE ERROR: $error');
      if (!mounted) return;
      setState(() {
        _error = friendlyError(error);
        _loading = false;
      });
    }
  }

  String _bucketFor(String targetType) =>
      targetType == 'official_post' ? 'official-post-images' : 'campus-post-images';

  Future<void> _resolve(Map<String, dynamic> report, String action) async {
    final id = report['report_id'].toString();
    if (!_working.add(id)) return;
    setState(() {});
    try {
      final imagePath = await _db.rpc(
        'resolve_content_report',
        params: {'p_report_id': id, 'p_action': action},
      );
      if (imagePath is String && imagePath.isNotEmpty) {
        try {
          await _db.storage
              .from(_bucketFor(report['target_type'].toString()))
              .remove([imagePath]);
        } catch (error) {
          debugPrint('REPORT IMAGE CLEANUP ERROR: $error');
        }
      }
      await _load();
    } catch (error) {
      debugPrint('REPORT RESOLVE ERROR: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(error))),
        );
      }
    } finally {
      _working.remove(id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reported content'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : _reports.isEmpty
          ? const Center(child: Text('No open reports.'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _reports.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) => _card(_reports[index]),
            ),
    );
  }

  Widget _card(Map<String, dynamic> report) {
    final busy = _working.contains(report['report_id'].toString());
    final reason = reportReasons[report['reason']] ?? '${report['reason']}';
    final preview = report['content_preview']?.toString();
    final details = report['details']?.toString();
    final reports = report['report_count'] as int? ?? 1;
    final strikes = report['author_strikes'] as int? ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Chip(label: Text(reason)),
                Chip(label: Text('${report['target_type']}')),
                Chip(label: Text('$reports report${reports == 1 ? '' : 's'}')),
                Chip(label: Text('Author strikes: $strikes')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              preview == null || preview.isEmpty
                  ? 'The content was already removed.'
                  : preview,
            ),
            if (details != null && details.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Reporter note: $details',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : () => _resolve(report, 'dismiss'),
                  child: const Text('Dismiss'),
                ),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => _resolve(report, 'remove_content'),
                  child: const Text('Remove'),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => _resolve(report, 'remove_and_strike'),
                  child: const Text('Remove + strike'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
