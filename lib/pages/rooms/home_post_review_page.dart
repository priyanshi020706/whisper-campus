import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/error_message.dart';
import 'post_review_card.dart';
import '../../services/live_signals.dart';

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
  LiveSubscription? _liveSubscription;
  final _liveRefresh = Debouncer();
  List<Map<String, dynamic>> _posts = [];
  bool _loading = true;
  String? _error;

  bool get _official => widget.mode == 'official';

  @override
  void initState() {
    super.initState();
    _load();
    _liveSubscription = LiveSignals.instance.listen('feed:${widget.mode}', (
      signal,
    ) {
      final kind = signal['kind'];
      if (kind != 'post' && kind != 'resync') return;
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
        _error = friendlyError(error);
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
        SnackBar(
          content: Text('Could not review post: ${friendlyError(error)}'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final campusName = _official ? 'Official' : 'Unofficial';
    return Scaffold(
      appBar: AppBar(
        title: Text('$campusName post approvals'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
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
                    TextButton(
                      onPressed: _load,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            )
          : _posts.isEmpty
          ? Center(child: Text('No $campusName posts waiting for approval.'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _posts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final row = _posts[index];
                final id = row['post_id'].toString();
                return PostReviewCard(
                  heading: '${row['room_name'] ?? 'Room'}',
                  subheading: row['author_label']?.toString(),
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
}
