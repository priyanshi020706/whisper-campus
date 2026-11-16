import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/post_content.dart';

class HomePostReviewPage extends StatefulWidget {
  const HomePostReviewPage({super.key, required this.mode});

  final String mode;

  @override
  State<HomePostReviewPage> createState() => _HomePostReviewPageState();
}

class _HomePostReviewPageState extends State<HomePostReviewPage> {
  final _db = Supabase.instance.client;
  final Map<String, String> _imageUrls = {};
  final Set<String> _working = {};
  List<Map<String, dynamic>> _posts = [];
  bool _loading = true;
  String? _error;

  bool get _official => widget.mode == 'official';

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
      final result = await _db.rpc(
        'get_pending_room_reviews',
        params: {'p_mode': widget.mode},
      );
      final rows = List<Map<String, dynamic>>.from(result);
      _imageUrls.clear();
      for (final row in rows) {
        final path = row['image_path']?.toString();
        if (path == null || path.isEmpty) continue;
        try {
          _imageUrls[row['post_id'].toString()] = await _db.storage
              .from(_official ? 'official-post-images' : 'campus-post-images')
              .createSignedUrl(path, 600);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _posts = rows;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _review(String postId, String decision) async {
    setState(() => _working.add(postId));
    try {
      await _db.rpc(
        _official ? 'review_official_room_post' : 'review_unofficial_room_post',
        params: {'p_post_id': postId, 'p_decision': decision},
      );
      if (!mounted) return;
      setState(() {
        _posts.removeWhere((row) => row['post_id'].toString() == postId);
        _working.remove(postId);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _working.remove(postId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not review post: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final campusName = _official ? 'Official' : 'Unofficial';
    return Scaffold(
      appBar: AppBar(
        title: Text('$campusName post approvals'),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Could not load approvals: $_error'),
                    TextButton(onPressed: _load, child: const Text('Try again')),
                  ],
                ),
              ),
            )
          : _posts.isEmpty
          ? Center(child: Text('No $campusName posts waiting for approval.'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _posts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final row = _posts[index];
                final id = row['post_id'].toString();
                final formatted = PostContent.decode(
                  row['content']?.toString() ?? '',
                );
                final image = _imageUrls[id];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${row['room_name']} · ${row['author_label']}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        if (formatted.title.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            formatted.title,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ],
                        if (formatted.body.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(formatted.body),
                        ],
                        if (image != null) ...[
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.network(image, fit: BoxFit.cover),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: _working.contains(id)
                                  ? null
                                  : () => _review(id, 'rejected'),
                              child: const Text('Reject'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: _working.contains(id)
                                  ? null
                                  : () => _review(id, 'approved'),
                              child: _working.contains(id)
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Approve'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
