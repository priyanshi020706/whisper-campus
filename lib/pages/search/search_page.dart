import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/error_message.dart';
import '../../core/widgets/post_card_tile.dart';
import '../../models/post_card.dart';
import '../../services/saved_posts_controller.dart';

/// Where search results come from.
abstract class PostSearchSource {
  Future<List<PostCardData>> search(String kind, String query);
}

class SupabasePostSearchSource implements PostSearchSource {
  SupabasePostSearchSource([SupabaseClient? client])
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<List<PostCardData>> search(String kind, String query) async {
    final rows = await _client.rpc(
      'search_posts',
      params: {'p_kind': kind, 'p_query': query, 'p_limit': 30},
    );
    return [
      for (final row in List<Map<String, dynamic>>.from(rows as List))
        PostCardData.fromMap(row),
    ];
  }
}

/// Search posts by title, text or tag. Results respect the same visibility and
/// anonymity rules as the feeds.
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.initialKind,
    required this.saved,
    required this.onOpenComments,
    this.source,
    this.imageUrlLoader = defaultImageUrlLoader,
    this.debounce = const Duration(milliseconds: 450),
  });

  /// `post` (anonymous) or `official_post`: the mode to search first.
  final String initialKind;
  final SavedPostsController saved;
  final void Function(PostCardData post) onOpenComments;
  final PostSearchSource? source;
  final ImageUrlLoader imageUrlLoader;
  final Duration debounce;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  late final PostSearchSource _source =
      widget.source ?? SupabasePostSearchSource();
  late String _kind = widget.initialKind;
  Timer? _timer;
  int _requestNumber = 0;
  List<PostCardData> _results = const [];
  bool _searching = false;
  String? _error;
  String _searchedFor = '';

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _timer?.cancel();
    setState(() {}); // shows or hides the clear button
    final query = text.trim();
    if (query.length < 2) {
      _requestNumber++; // drop any answer still on its way
      setState(() {
        _results = const [];
        _searching = false;
        _error = null;
        _searchedFor = '';
      });
      return;
    }
    _timer = Timer(widget.debounce, _run);
  }

  Future<void> _run() async {
    final query = _controller.text.trim();
    if (query.length < 2) return;
    final number = ++_requestNumber;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await _source.search(_kind, query);
      // An older answer must never replace a newer search.
      if (!mounted || number != _requestNumber) return;
      setState(() {
        _results = results;
        _searchedFor = query;
        _searching = false;
      });
    } catch (error) {
      debugPrint('SEARCH ERROR: $error');
      if (!mounted || number != _requestNumber) return;
      setState(() {
        _error = friendlyError(error);
        _searching = false;
      });
    }
  }

  void _setKind(String kind) {
    if (kind == _kind) return;
    setState(() => _kind = kind);
    _run();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (_) {
            _timer?.cancel();
            _run();
          },
          decoration: InputDecoration(
            hintText: 'Search posts',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Anonymous'),
                  selected: _kind == 'post',
                  onSelected: (_) => _setKind('post'),
                ),
                ChoiceChip(
                  label: const Text('Official'),
                  selected: _kind == 'official_post',
                  onSelected: (_) => _setKind('official_post'),
                ),
              ],
            ),
          ),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget message(IconData icon, String title, String? subtitle) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: colors.outline),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );

    if (_error != null) {
      return message(
        Icons.error_outline,
        _error!,
        'Check your connection and try again.',
      );
    }
    if (_controller.text.trim().length < 2) {
      return message(
        Icons.search_rounded,
        'Search the campus',
        'Find posts by title, text or tag.',
      );
    }
    if (_results.isEmpty && !_searching && _searchedFor.isNotEmpty) {
      return message(
        Icons.search_off_rounded,
        'No posts match "$_searchedFor"',
        'Try a different word.',
      );
    }
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final post = _results[index];
        return ListenableBuilder(
          listenable: widget.saved,
          builder: (context, _) {
            final saved = widget.saved.isSaved(post.kind, post.postId);
            return PostCardTile(
              key: ValueKey(postKey(post.kind, post.postId)),
              post: post,
              imageUrlLoader: widget.imageUrlLoader,
              onOpen: () => widget.onOpenComments(post),
              actions: [
                TextButton.icon(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final problem = await widget.saved.toggle(
                      post.kind,
                      post.postId,
                    );
                    if (problem != null) {
                      messenger
                        ..hideCurrentSnackBar()
                        ..showSnackBar(SnackBar(content: Text(problem)));
                    }
                  },
                  icon: Icon(
                    saved
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_border_rounded,
                    size: 18,
                  ),
                  label: Text(saved ? 'Saved' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
