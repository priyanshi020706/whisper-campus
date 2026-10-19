import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/widgets/campus_live_action.dart';
import '../../models/profile_activity.dart';
import '../../models/profile_model.dart';
import '../../models/post_content.dart';
import 'profile_post_detail_page.dart';

const _avatarChoices = [
  _AvatarChoice(seed: '8E6CFF', emoji: '🤖', label: 'Bot'),
  _AvatarChoice(seed: '4CC9F0', emoji: '👾', label: 'Alien'),
  _AvatarChoice(seed: 'FF8A65', emoji: '🧑‍🚀', label: 'Space'),
  _AvatarChoice(seed: 'F5B942', emoji: '🛸', label: 'UFO'),
  _AvatarChoice(seed: 'F06292', emoji: '🐱', label: 'Cat'),
  _AvatarChoice(seed: '4CAF87', emoji: '🐸', label: 'Frog'),
  _AvatarChoice(seed: '7389FF', emoji: '🐙', label: 'Octo'),
  _AvatarChoice(seed: 'A46FE0', emoji: '🪐', label: 'Orbit'),
];

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    this.officialMode = false,
    this.onCreatePost,
    this.onNavigateHome,
    this.onOpenLiveChat,
  });

  final bool officialMode;
  final Future<void> Function()? onCreatePost;
  final VoidCallback? onNavigateHome;
  final VoidCallback? onOpenLiveChat;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _supabase = Supabase.instance.client;
  ProfileModel? _profile;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _realName;
  ProfileStats _stats = const ProfileStats();
  List<ProfileActivity> _activity = [];
  _ProfileSection _section = _ProfileSection.posts;

  @override
  void initState() {
    super.initState();
    _fetchProfile();
  }

  Future<void> _fetchProfile() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      if (!mounted) return;
      setState(() {
        _error = 'No logged-in user found.';
        _loading = false;
      });
      return;
    }

    try {
      final data = await _supabase
          .from('profiles')
          .select(
            'anon_username, avatar_seed, role, department, academic_year, bio',
          )
          .eq('id', userId)
          .single();
      String? realName;
      if (widget.officialMode) {
        final identityRows = await _supabase.rpc('get_my_identity');
        if (identityRows is List && identityRows.isNotEmpty) {
          realName = identityRows.first['real_name'] as String?;
        }
      }

      final statsRows = await _supabase.rpc(
        widget.officialMode
            ? 'get_my_official_profile_stats'
            : 'get_my_unofficial_profile_stats',
      );
      final activityRows = await _fetchActivityRows(_section);

      if (!mounted) return;
      setState(() {
        _profile = ProfileModel.fromMap(data);
        _realName = realName;
        _stats = ProfileStats.fromRow(
          Map<String, dynamic>.from((statsRows as List).first),
        );
        _activity = activityRows;
        _error = null;
        _loading = false;
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your profile: ${error.message}';
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your profile. Please try again.';
        _loading = false;
      });
      debugPrint('PROFILE ERROR: $error');
    }
  }

  Future<List<ProfileActivity>> _fetchActivityRows(
    _ProfileSection section,
  ) async {
    final rows = await _supabase.rpc(
      widget.officialMode
          ? 'get_my_official_profile_activity'
          : 'get_my_unofficial_profile_activity',
      params: {'p_section': section.name, 'p_limit': 100},
    );
    final items = List<Map<String, dynamic>>.from(rows)
        .map(
          (row) => ProfileActivity.fromRow(row, official: widget.officialMode),
        )
        .toList();
    return Future.wait(
      items.map((item) async {
        if (item.imagePath == null) return item;
        try {
          final url = await _supabase.storage
              .from(
                widget.officialMode
                    ? 'official-post-images'
                    : 'campus-post-images',
              )
              .createSignedUrl(item.imagePath!, 3600);
          return item.copyWith(imageUrl: url);
        } catch (_) {
          return item;
        }
      }),
    );
  }

  Future<void> _selectSection(_ProfileSection section) async {
    if (_section == section) return;
    setState(() {
      _section = section;
      _loading = true;
      _error = null;
    });
    try {
      final activity = await _fetchActivityRows(section);
      if (!mounted) return;
      setState(() {
        _activity = activity;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your ${section.name}. Please try again.';
        _loading = false;
      });
      debugPrint('PROFILE ACTIVITY ERROR: $error');
    }
  }

  Future<void> _openActivity(ProfileActivity item) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProfilePostDetailPage(
          activity: item,
          officialMode: widget.officialMode,
          currentUserAvatarSeed: _profile?.avatarSeed,
          onNavigateHome: widget.onNavigateHome == null
              ? null
              : () {
                  Navigator.of(context).pop();
                  widget.onNavigateHome?.call();
                },
          onOpenLiveChat: widget.onOpenLiveChat == null
              ? null
              : () {
                  Navigator.of(context).pop();
                  widget.onOpenLiveChat?.call();
                },
        ),
      ),
    );
    if (mounted) await _fetchProfile();
  }

  Future<void> _createPost() async {
    final callback = widget.onCreatePost;
    if (callback == null) return;
    await callback();
    if (mounted) await _fetchProfile();
  }

  Future<void> _editProfile() async {
    final profile = _profile;
    final userId = _supabase.auth.currentUser?.id;
    if (profile == null || userId == null || _saving) return;

    final edits = await showModalBottomSheet<_ProfileEdits>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _ProfileEditorSheet(
        bio: profile.bio ?? '',
        avatarSeed: profile.avatarSeed,
      ),
    );
    if (edits == null || !mounted) return;

    setState(() => _saving = true);
    try {
      await _supabase
          .from('profiles')
          .update({
            'bio': edits.bio.trim().isEmpty ? null : edits.bio.trim(),
            'avatar_seed': edits.avatarSeed,
          })
          .eq('id', userId)
          .select('bio, avatar_seed')
          .single();
      await _fetchProfile();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profile updated.')));
    } on PostgrestException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save profile: ${error.message}')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save your profile.')),
      );
      debugPrint('PROFILE UPDATE ERROR: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _signOut() async {
    try {
      await _supabase.auth.signOut();
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on AuthException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      debugPrint('SIGN OUT ERROR: $error');
    }
  }

  Color _avatarColor(String seed) {
    for (final choice in _avatarChoices) {
      if (choice.seed == seed) return choice.color;
    }
    if (seed.length >= 6) {
      try {
        return Color(int.parse('0xFF${seed.substring(0, 6)}'));
      } catch (_) {
        // Older or unknown avatar seeds use the default lavender avatar.
      }
    }
    return const Color(0xFF8E6CFF);
  }

  Widget _avatarFace(String seed, {double fontSize = 36}) {
    for (final choice in _avatarChoices) {
      if (choice.seed == seed) {
        return Text(choice.emoji, style: TextStyle(fontSize: fontSize));
      }
    }
    final fallback = _avatarChoices.first;
    return Text(fallback.emoji, style: TextStyle(fontSize: fontSize));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = widget.officialMode
        ? 'Official profile'
        : 'Unofficial profile';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Home',
            onPressed: widget.onNavigateHome,
            icon: const Icon(Icons.home_outlined),
          ),
          CampusLiveAction(active: false, onPressed: () => widget.onOpenLiveChat?.call()),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
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
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                  FilledButton.tonal(
                    onPressed: _fetchProfile,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _fetchProfile,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 36),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 780),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildIdentityHeader(colors),
                          const SizedBox(height: 16),
                          _buildStats(colors),
                          const SizedBox(height: 18),
                          _buildActivitySection(colors),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildIdentityHeader(ColorScheme colors) {
    final profile = _profile!;
    final hasBio = profile.bio?.trim().isNotEmpty == true;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 84,
            decoration: BoxDecoration(
              color: widget.officialMode
                  ? Color.alphaBlend(
                      colors.tertiary.withValues(alpha: 0.24),
                      colors.surfaceContainerHigh,
                    )
                  : Color.alphaBlend(
                      colors.primary.withValues(alpha: 0.2),
                      colors.surfaceContainerHigh,
                    ),
            ),
            child: Stack(
              children: [
                Positioned(
                  right: 18,
                  top: 10,
                  child: Icon(
                    widget.officialMode
                        ? Icons.school_outlined
                        : Icons.forum_outlined,
                    size: 64,
                    color: colors.onSurface.withValues(alpha: 0.07),
                  ),
                ),
                Positioned(
                  left: 18,
                  top: 15,
                  child: _ModePill(officialMode: widget.officialMode),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Transform.translate(
                  offset: const Offset(0, -32),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      CircleAvatar(
                        radius: 42,
                        backgroundColor: widget.officialMode
                            ? colors.primaryContainer
                            : _avatarColor(profile.avatarSeed),
                        child: widget.officialMode
                            ? Icon(
                                Icons.school_rounded,
                                size: 38,
                                color: colors.onPrimaryContainer,
                              )
                            : _avatarFace(profile.avatarSeed, fontSize: 32),
                      ),
                      const Spacer(),
                      if (!widget.officialMode)
                        IconButton.filledTonal(
                          tooltip: 'Edit bio and avatar',
                          onPressed: _saving ? null : _editProfile,
                          icon: const Icon(Icons.edit_rounded),
                        ),
                    ],
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, -22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.officialMode
                            ? (_realName ?? 'Student')
                            : profile.anonUsername,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.officialMode
                            ? 'MITS student'
                            : 'Anonymous student',
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                      if (widget.officialMode &&
                          (profile.department != null ||
                              profile.academicYear != null)) ...[
                        const SizedBox(height: 11),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            if (profile.department != null)
                              _ProfileTag(
                                label: profile.department!,
                                icon: Icons.account_balance_outlined,
                              ),
                            if (profile.academicYear != null)
                              _ProfileTag(
                                label: 'Year ${profile.academicYear}',
                                icon: Icons.school_outlined,
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        hasBio
                            ? profile.bio!.trim()
                            : 'Add a short bio to introduce yourself.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: hasBio
                              ? colors.onSurface
                              : colors.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                      if (!widget.officialMode) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _saving ? null : _editProfile,
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: Text(_saving ? 'Saving…' : 'Edit profile'),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStats(ColorScheme colors) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Row(
          children: [
            _StatCell(
              label: 'Posts',
              value: _stats.posts,
              icon: Icons.article_outlined,
            ),
            _StatDivider(color: colors.outlineVariant),
            _StatCell(
              label: 'Likes received',
              value: _stats.likesReceived,
              icon: Icons.favorite_border_rounded,
            ),
            _StatDivider(color: colors.outlineVariant),
            _StatCell(
              label: 'Comments',
              value: _stats.comments,
              icon: Icons.mode_comment_outlined,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivitySection(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Your activity',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              tooltip: 'Refresh activity',
              onPressed: _fetchProfile,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        SegmentedButton<_ProfileSection>(
          segments: const [
            ButtonSegment(
              value: _ProfileSection.posts,
              label: Text('Posts'),
              icon: Icon(Icons.article_outlined),
            ),
            ButtonSegment(
              value: _ProfileSection.comments,
              label: Text('Comments'),
              icon: Icon(Icons.mode_comment_outlined),
            ),
          ],
          selected: {_section},
          onSelectionChanged: (selection) => _selectSection(selection.first),
        ),
        if (_section == _ProfileSection.posts &&
            widget.onCreatePost != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _createPost,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Create a post'),
          ),
        ],
        const SizedBox(height: 12),
        if (_activity.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              child: Column(
                children: [
                  Icon(
                    _section == _ProfileSection.posts
                        ? Icons.article_outlined
                        : Icons.mode_comment_outlined,
                    size: 30,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(height: 9),
                  Text(
                    _section == _ProfileSection.posts
                        ? 'Your posts will appear here.'
                        : 'Comments you write will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          )
        else
          ..._activity.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: _ProfileActivityCard(
                item: item,
                officialMode: widget.officialMode,
                onTap: () => _openActivity(item),
              ),
            ),
          ),
      ],
    );
  }
}

class _ProfileEditorSheet extends StatefulWidget {
  const _ProfileEditorSheet({required this.bio, required this.avatarSeed});

  final String bio;
  final String avatarSeed;

  @override
  State<_ProfileEditorSheet> createState() => _ProfileEditorSheetState();
}

class _ProfileEditorSheetState extends State<_ProfileEditorSheet> {
  late final TextEditingController _bioController;
  late String _selectedAvatarSeed;

  @override
  void initState() {
    super.initState();
    _bioController = TextEditingController(text: widget.bio);
    _selectedAvatarSeed =
        _avatarChoices.any((choice) => choice.seed == widget.avatarSeed)
        ? widget.avatarSeed
        : _avatarChoices.first.seed;
  }

  @override
  void dispose() {
    _bioController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, bottomInset + 24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Edit your profile',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 20),
            Text(
              'Choose an avatar',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _avatarChoices.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.9,
              ),
              itemBuilder: (context, index) {
                final choice = _avatarChoices[index];
                final selected = choice.seed == _selectedAvatarSeed;
                return Semantics(
                  button: true,
                  selected: selected,
                  label: '${choice.label} avatar',
                  child: Material(
                    color: colors.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: selected
                            ? colors.primary
                            : colors.outlineVariant,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () =>
                          setState(() => _selectedAvatarSeed = choice.seed),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircleAvatar(
                            radius: 23,
                            backgroundColor: choice.color,
                            child: Text(
                              choice.emoji,
                              style: const TextStyle(fontSize: 24),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            choice.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _bioController,
              maxLength: 160,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Bio',
                hintText: 'A little about you…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                _ProfileEdits(
                  bio: _bioController.text,
                  avatarSeed: _selectedAvatarSeed,
                ),
              ),
              child: const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileTag extends StatelessWidget {
  const _ProfileTag({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(icon, size: 16),
      label: Text(label),
      backgroundColor: colors.secondaryContainer,
      side: BorderSide.none,
    );
  }
}

class _ProfileActivityCard extends StatelessWidget {
  const _ProfileActivityCard({
    required this.item,
    required this.officialMode,
    required this.onTap,
  });

  final ProfileActivity item;
  final bool officialMode;
  final VoidCallback onTap;

  String _timeLabel() {
    final elapsed = DateTime.now().difference(item.createdAt.toLocal());
    if (elapsed.inMinutes < 1) return 'just now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
    if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
    if (elapsed.inDays < 7) return '${elapsed.inDays}d ago';
    final local = item.createdAt.toLocal();
    return '${local.day}/${local.month}/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isComment = item.isComment;
    final postDisplayText = PostContent.decode(item.postContent).displayText;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isComment
                        ? Icons.mode_comment_outlined
                        : Icons.article_outlined,
                    size: 18,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isComment
                          ? 'Commented on ${item.postAuthorName}’s post'
                          : item.scopeName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Text(
                    _timeLabel(),
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(width: 7),
                  _ModePill(officialMode: officialMode, compact: true),
                ],
              ),
              const SizedBox(height: 10),
              if (item.imageUrl != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    height: 148,
                    width: double.infinity,
                    child: Image.network(
                      item.imageUrl!,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          const Center(
                            child: Icon(Icons.broken_image_outlined),
                          ),
                    ),
                  ),
                ),
                if (postDisplayText.isNotEmpty) const SizedBox(height: 9),
              ],
              if (postDisplayText.isNotEmpty)
                Text(
                  postDisplayText,
                  maxLines: item.imageUrl == null ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.4,
                    fontWeight: isComment ? FontWeight.w500 : null,
                  ),
                ),
              if (isComment) ...[
                const SizedBox(height: 11),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    item.activityContent,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(height: 1.4),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.favorite_border_rounded,
                    size: 17,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text('${item.likeCount}'),
                  const SizedBox(width: 15),
                  Icon(
                    Icons.mode_comment_outlined,
                    size: 17,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text('${item.commentCount}'),
                  const Spacer(),
                  Text(
                    isComment ? 'Open thread' : 'View post',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 16,
                    color: colors.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({required this.officialMode, this.compact = false});

  final bool officialMode;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = officialMode
        ? colors.tertiaryContainer
        : colors.secondaryContainer;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        officialMode ? 'Official' : 'Unofficial',
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(height: 5),
          Text(
            '$value',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 42, color: color);
}

enum _ProfileSection { posts, comments }

class _ProfileEdits {
  const _ProfileEdits({required this.bio, required this.avatarSeed});

  final String bio;
  final String avatarSeed;
}

class _AvatarChoice {
  const _AvatarChoice({
    required this.seed,
    required this.emoji,
    required this.label,
  });

  final String seed;
  final String emoji;
  final String label;

  Color get color => Color(int.parse('0xFF$seed'));
}
