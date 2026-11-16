import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/error_message.dart';
import 'post_review_card.dart';
import '../../services/live_signals.dart';

class RoomPostReviewPage extends StatefulWidget {
  const RoomPostReviewPage({
    super.key,
    required this.roomId,
    required this.roomName,
    this.mode = 'unofficial',
  });

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
  LiveSubscription? _liveSubscription;
  final _liveRefresh = Debouncer();

  @override
  void initState() {
    super.initState();
    _load();
    _liveSubscription = LiveSignals.instance.listen('feed:${widget.mode}', (
      signal,
    ) {
      final room = signal['room_id'] as String?;
      final kind = signal['kind'];
      if (kind != 'post' && kind != 'resync') return;
      if (room != null && room != widget.roomId) return;
      _liveRefresh.run(() {
        if (mounted) _load(showLoading: false);
      });
    });
  }

  @override
  void dispose() {
    _liveSubscription?.cancel();
    _liveRefresh.dispose();
    super.dispose();
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final result = await _db.rpc(
        widget.mode == 'official'
            ? 'get_pending_official_room_posts'
            : 'get_pending_unofficial_room_posts',
        params: {'p_room_id': widget.roomId},
      );
      final rows = List<Map<String, dynamic>>.from(result);
      _imageUrls.clear();
      for (final row in rows) {
        final path = row['image_path']?.toString();
        if (path == null) continue;
        try {
          _imageUrls[row['post_id'].toString()] = await _db.storage
              .from(
                widget.mode == 'official'
                    ? 'official-post-images'
                    : 'campus-post-images',
              )
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
        _error = friendlyError(error);
      });
    }
  }

  Future<void> _review(String postId, String decision) async {
    setState(() => _working.add(postId));
    try {
      await _db.rpc(
        widget.mode == 'official'
            ? 'review_official_room_post'
            : 'review_unofficial_room_post',
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
        SnackBar(
          content: Text('Could not review post: ${friendlyError(error)}'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Review · ${widget.roomName}')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load pending posts: $_error',
                textAlign: TextAlign.center,
              ),
            ),
          )
        : _posts.isEmpty
        ? const Center(child: Text('No posts waiting for review.'))
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _posts.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final row = _posts[index];
              final id = row['post_id'].toString();
              return PostReviewCard(
                heading: widget.roomName,
                subheading:
                    row[widget.mode == 'official'
                            ? 'author_name'
                            : 'author_username']
                        ?.toString() ??
                    (widget.mode == 'official' ? 'Student' : 'Anonymous'),
                submittedAt: DateTime.tryParse('${row['created_at'] ?? ''}'),
                content: row['content']?.toString() ?? '',
                imageUrl: _imageUrls[id],
                busy: _working.contains(id),
                onReject: () => _review(id, 'rejected'),
                onApprove: () => _review(id, 'approved'),
              );
            },
          ),
  );
}
