import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/post_content.dart';

class RoomPostReviewPage extends StatefulWidget {
  const RoomPostReviewPage({super.key, required this.roomId, required this.roomName, this.mode = 'unofficial'});

  final String roomId;
  final String roomName;
  final String mode;

  @override
  State<RoomPostReviewPage> createState() => _RoomPostReviewPageState();
}

class _RoomPostReviewPageState extends State<RoomPostReviewPage> {
  final _db = Supabase.instance.client;
  List<Map<String, dynamic>> _posts = [];
  final Map<String, String> _imageUrls = {};
  bool _loading = true;
  String? _error;
  final Set<String> _working = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final result = await _db.rpc(
        widget.mode == 'official' ? 'get_pending_official_room_posts' : 'get_pending_unofficial_room_posts',
        params: {'p_room_id': widget.roomId},
      );
      final rows = List<Map<String, dynamic>>.from(result);
      _imageUrls.clear();
      for (final row in rows) {
        final path = row['image_path']?.toString();
        if (path == null) continue;
        try {
            _imageUrls[row['post_id'].toString()] = await _db.storage
                .from(widget.mode == 'official' ? 'official-post-images' : 'campus-post-images')
                .createSignedUrl(path, 600);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() { _posts = rows; _loading = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _loading = false; _error = error.toString(); });
    }
  }

  Future<void> _review(String postId, String decision) async {
    setState(() => _working.add(postId));
    try {
      await _db.rpc(
        widget.mode == 'official' ? 'review_official_room_post' : 'review_unofficial_room_post',
        params: {'p_post_id': postId, 'p_decision': decision},
      );
      if (!mounted) return;
      setState(() { _posts.removeWhere((row) => row['post_id'].toString() == postId); _working.remove(postId); });
    } catch (error) {
      if (!mounted) return;
      setState(() => _working.remove(postId));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not review post: $error')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Review · ${widget.roomName}')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Could not load pending posts: $_error', textAlign: TextAlign.center)))
            : _posts.isEmpty
                ? const Center(child: Text('No posts waiting for review.'))
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _posts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final row = _posts[index];
                      final id = row['post_id'].toString();
                      final imageUrl = _imageUrls[id];
                      final content = row['content']?.toString() ?? '';
                      final formatted = PostContent.decode(content);
                      return Card(child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(row[widget.mode == 'official' ? 'author_name' : 'author_username']?.toString() ?? (widget.mode == 'official' ? 'Student' : 'Anonymous'), style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 10),
                          if (formatted.title.isNotEmpty) Text(formatted.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                          if (formatted.tags.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Wrap(spacing: 6, children: [for (final tag in formatted.tags) Chip(label: Text(tag), visualDensity: VisualDensity.compact)]),
                          ],
                          if (formatted.body.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(formatted.body),
                          ],
                          if (imageUrl != null) ...[
                            const SizedBox(height: 12),
                            ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(imageUrl, fit: BoxFit.cover)),
                          ],
                          const SizedBox(height: 12),
                          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                            TextButton(onPressed: _working.contains(id) ? null : () => _review(id, 'rejected'), child: const Text('Reject')),
                            const SizedBox(width: 8),
                            FilledButton(onPressed: _working.contains(id) ? null : () => _review(id, 'approved'), child: _working.contains(id) ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Approve')),
                          ]),
                        ]),
                      ));
                    },
                  ),
  );
}
