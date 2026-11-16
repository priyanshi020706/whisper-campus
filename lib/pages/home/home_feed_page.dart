import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/theme_controller.dart';
import '../../core/widgets/campus_live_action.dart';
import '../../core/widgets/student_avatar.dart';
import '../../core/widgets/whisper_brand.dart';
import '../../models/campus_department.dart';
import '../../models/post_content.dart';
import '../profile/profile_page.dart';
import '../rooms/department_rooms_page.dart';
import '../rooms/faculty_moderator_page.dart';
import '../rooms/room_chat_page.dart';
import '../rooms/room_post_review_page.dart';
import '../rooms/home_post_review_page.dart';
import '../rooms/room_moderator_contact_page.dart';
import '../rooms/moderator_inbox_page.dart';
import '../notifications/notifications_page.dart';
import 'live_room_preview.dart';
import 'post_media_frame.dart';
import '../../core/utils/error_message.dart';
import '../../services/report_service.dart';
import '../rooms/report_queue_page.dart';
import '../../services/live_signals.dart';

/// Signed image URLs last an hour. They are reused across live refreshes while
/// younger than this, then signed again.
const _signedUrlReuseWindow = Duration(minutes: 50);

enum _CampusMode { unofficial, official }

const _postImageBucket = 'campus-post-images';
const _officialPostImageBucket = 'official-post-images';
const _maxPostImageBytes = 5 * 1024 * 1024;

class HomeFeedPage extends StatefulWidget {
  const HomeFeedPage({
    super.key,
    this.initialRoomId,
    this.initialRoomName,
    this.roomPage = false,
  });

  final String? initialRoomId;
  final String? initialRoomName;
  final bool roomPage;

  @override
  State<HomeFeedPage> createState() => _HomeFeedPageState();
}

class _HomeFeedPageState extends State<HomeFeedPage>
    with SingleTickerProviderStateMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _supabase = Supabase.instance.client;
  final _homeScrollController = ScrollController();
  List<_CampusRoom> _rooms = [];
  String? _selectedRoomId;
  String? _myAvatarSeed;
  bool _isFaculty = false;
  bool _isSuperAdmin = false;
  bool _hasModeratorInbox = false;
  bool _canReviewRoomPosts = false;
  int _pendingApprovalCount = 0;
  bool _identityLoaded = false;
  String? _identityError;
  List<_CampusPost> _posts = [];
  List<_OfficialPost> _officialPosts = [];
  final Set<String> _likingPostIds = {};
  bool _loading = true;
  bool _officialLoading = true;
  bool _posting = false;
  bool _livePanelOpen = false;
  bool _drawerOpen = false;
  bool _chatJoined = false;
  late final TabController _roomTabController;
  Timer? _roomUnreadTimer;
  Timer? _notificationTimer;
  DateTime? _urlsSignedAt;
  bool get _urlsStillFresh =>
      _urlsSignedAt != null &&
      DateTime.now().difference(_urlsSignedAt!) < _signedUrlReuseWindow;
  final List<LiveSubscription> _liveSubscriptions = [];
  final _feedRefresh = Debouncer();
  final _notificationRefresh = Debouncer();
  final _pendingRefresh = Debouncer();
  int _unreadNotifications = 0;
  bool _roomChatSelected = false;
  int _roomUnreadCount = 0;
  _CampusMode _mode = _CampusMode.unofficial;
  String? _error;
  String? _officialError;

  @override
  void initState() {
    super.initState();
    _roomTabController = TabController(length: 2, vsync: this)
      ..addListener(_handleRoomTabChanged);
    if (widget.roomPage) {
      _roomUnreadTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => _loadRoomUnreadCount(),
      );
    }
    unawaited(_loadUnreadNotifications());
    _notificationTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _loadUnreadNotifications();
      _loadPendingApprovalCount();
    });
    unawaited(_loadMyAvatarSeed(initializeHome: true));
    _startLiveUpdates();
  }

  /// Live updates: posts, likes and comments appear without a refresh. The
  /// timers above stay as a slow safety net.
  void _startLiveUpdates() {
    final userId = _supabase.auth.currentUser?.id;
    _liveSubscriptions.addAll([
      LiveSignals.instance.listen(
        'feed:unofficial',
        (signal) => _handleFeedSignal(_CampusMode.unofficial, signal),
      ),
      LiveSignals.instance.listen(
        'feed:official',
        (signal) => _handleFeedSignal(_CampusMode.official, signal),
      ),
      if (userId != null)
        LiveSignals.instance.listen('user:$userId', (_) {
          _notificationRefresh.run(() {
            if (!mounted) return;
            _loadUnreadNotifications();
          });
        }),
    ]);
  }

  void _handleFeedSignal(_CampusMode mode, Map<String, dynamic> signal) {
    if (!mounted) return;
    final kind = signal['kind'];
    final room = signal['room_id'] as String?;
    if (kind == 'post' || kind == 'resync') {
      _pendingRefresh.run(() {
        if (!mounted) return;
        _loadPendingApprovalCount();
      });
    }
    if (mode != _mode) return;
    final current = _selectedRoomId ?? 'general';
    final affectsThisRoom =
        kind == 'resync' ||
        room == null ||
        room == current ||
        room == 'general';
    if (!affectsThisRoom) return;
    _feedRefresh.run(() {
      if (!mounted) return;
      if (mode == _CampusMode.official) {
        _loadOfficialPosts(showLoading: false);
      } else {
        _loadPosts(showLoading: false);
      }
    });
  }

  void _handleRoomTabChanged() {
    if (_roomTabController.indexIsChanging) return;
    final chatSelected = _roomTabController.index == 1;
    if (_roomChatSelected == chatSelected || !mounted) return;
    setState(() {
      _roomChatSelected = chatSelected;
      if (chatSelected) _roomUnreadCount = 0;
    });
    if (!chatSelected) {
      Future<void>.delayed(
        const Duration(milliseconds: 250),
        _loadRoomUnreadCount,
      );
    }
  }

  Future<void> _loadRoomUnreadCount() async {
    final roomId = _selectedRoomId;
    if (!widget.roomPage || _roomChatSelected || roomId == null) return;
    try {
      final value = await _supabase.rpc(
        'get_room_chat_unread',
        params: {'p_room_id': roomId, 'p_mode': _mode.name},
      );
      if (!mounted || _roomChatSelected) return;
      setState(() => _roomUnreadCount = (value as num?)?.toInt() ?? 0);
    } catch (_) {
      // Unread badges are optional; keep the room and posts usable if the
      // chat migration has not been applied to the connected Supabase project.
    }
  }

  Future<void> _loadMyAvatarSeed({bool initializeHome = false}) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      if (initializeHome && mounted) {
        setState(() {
          _identityError = 'Please sign in again.';
          _identityLoaded = true;
        });
      }
      return;
    }
    try {
      final row = await _supabase
          .from('profiles')
          .select('avatar_seed, role')
          .eq('id', userId)
          .maybeSingle();
      final role = row?['role']?.toString();
      final isFaculty = role == 'faculty';
      final isSuperAdmin = role == 'super_admin';
      var hasModeratorInbox = isSuperAdmin;
      try {
        final rooms = await _supabase.rpc('list_my_moderated_rooms');
        // Super Admin has room-wide moderation access even without a
        // room_moderators assignment row (those rows are for students).
        hasModeratorInbox =
            hasModeratorInbox || (rooms is List && rooms.isNotEmpty);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _myAvatarSeed = row?['avatar_seed'] as String?;
          _isFaculty = isFaculty;
          _isSuperAdmin = isSuperAdmin;
          _hasModeratorInbox = hasModeratorInbox;
          if (initializeHome) {
            _mode = widget.roomPage
                ? _CampusMode.unofficial
                : (isFaculty || isSuperAdmin)
                ? _CampusMode.official
                : _CampusMode.unofficial;
            _identityLoaded = true;
            _identityError = row == null
                ? 'Could not load your profile.'
                : null;
          }
        });
      }
      if (initializeHome && row != null) {
        if (widget.roomPage) {
          await _loadRooms();
        } else if (isFaculty || isSuperAdmin) {
          await _loadOfficialPosts();
        } else {
          await _loadRooms();
        }
        if (!widget.roomPage) await _loadPendingApprovalCount();
      }
    } catch (_) {
      if (initializeHome && mounted) {
        setState(() {
          _identityError = 'Could not verify your account. Please try again.';
          _identityLoaded = true;
        });
      }
    }
  }

  @override
  void dispose() {
    for (final subscription in _liveSubscriptions) {
      subscription.cancel();
    }
    _feedRefresh.dispose();
    _notificationRefresh.dispose();
    _pendingRefresh.dispose();
    _roomUnreadTimer?.cancel();
    _notificationTimer?.cancel();
    _roomTabController
      ..removeListener(_handleRoomTabChanged)
      ..dispose();
    _homeScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadRooms() async {
    try {
      final rows = await _supabase
          .from('rooms')
          .select('id, name')
          .order('name');
      final rooms = List<Map<String, dynamic>>.from(rows)
          .map(
            (row) => _CampusRoom(
              id: row['id'] as String,
              name: row['name'] as String,
            ),
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _rooms = rooms;
        final initialRoom = widget.initialRoomId;
        _selectedRoomId = widget.roomPage && initialRoom != null
            ? initialRoom
            : initialRoom != null && rooms.any((room) => room.id == initialRoom)
            ? initialRoom
            : rooms.any((room) => room.id == 'general')
            ? 'general'
            : (rooms.isEmpty ? null : rooms.first.id);
      });
      if (widget.roomPage && _selectedRoomId != null) {
        await _checkRoomReviewAccess(_selectedRoomId!);
      }
      await _loadPosts();
      if (widget.roomPage) await _loadRoomUnreadCount();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load rooms. Please try again.';
      });
    }
  }

  Future<void> _checkRoomReviewAccess(String roomId) async {
    try {
      final result = await _supabase.rpc(
        'is_active_room_moderator',
        params: {'p_room': roomId, 'p_mode': _mode.name},
      );
      if (mounted) {
        setState(() => _canReviewRoomPosts = _isSuperAdmin || result == true);
      }
    } catch (_) {
      if (mounted) setState(() => _canReviewRoomPosts = _isSuperAdmin);
    }
  }

  Future<void> _openRoomPostReview() async {
    final roomId = _selectedRoomId;
    if (roomId == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RoomPostReviewPage(
          roomId: roomId,
          roomName: widget.initialRoomName ?? _selectedRoomName,
          mode: _mode.name,
        ),
      ),
    );
    if (mounted) await _loadPosts(showLoading: false);
  }

  Future<void> _openModeratorContact() async {
    final roomId = _selectedRoomId;
    if (roomId == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RoomModeratorContactPage(
          roomId: roomId,
          roomName: widget.initialRoomName ?? _selectedRoomName,
          mode: _mode.name,
        ),
      ),
    );
  }

  Future<void> _changeMode(_CampusMode mode) async {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _livePanelOpen = false;
      _chatJoined = false;
    });
    if (widget.roomPage) {
      final roomId = _selectedRoomId;
      if (roomId != null) await _checkRoomReviewAccess(roomId);
      return;
    }
    if (mode == _CampusMode.official) {
      await _loadOfficialPosts();
    } else {
      if (_rooms.isEmpty) {
        await _loadRooms();
      } else {
        await _loadPosts();
      }
    }
    await _loadPendingApprovalCount();
  }

  Future<void> _loadOfficialPosts({bool showLoading = true}) async {
    if (showLoading && mounted) {
      setState(() {
        _officialLoading = true;
        _officialError = null;
      });
    }
    try {
      final rows = await _supabase.rpc(
        'get_official_posts_with_activity',
        params: {
          'p_department_code': (_selectedRoomId ?? '').startsWith('dept-')
              ? (_selectedRoomId ?? '').substring(5)
              : null,
          'p_limit': 50,
          'p_room_id': _selectedRoomId ?? 'general',
        },
      );
      final posts = List<Map<String, dynamic>>.from(rows).map((row) {
        return _OfficialPost(
          id: row['post_id'] as String,
          departmentCode: row['department_code'] as String?,
          authorName: row['author_name'] as String,
          branch: row['author_branch'] as String,
          academicYear: (row['author_year'] as num?)?.toInt() ?? 0,
          content: row['content'] as String,
          createdAt: DateTime.parse(row['created_at'] as String),
          imagePath: row['image_path'] as String?,
          likeCount: (row['like_count'] as num).toInt(),
          likedByMe: row['liked_by_me'] as bool,
          replyCount: (row['comment_count'] as num).toInt(),
        );
      }).toList();
      // Reuse image URLs from the posts already on screen: a new signed URL on
      // every live refresh would make every image reload and flicker.
      final reuseUrls = _urlsStillFresh;
      final knownUrls = {
        if (reuseUrls)
          for (final old in _officialPosts)
            if (old.imagePath != null && old.imageUrl != null)
              old.imagePath!: old.imageUrl!,
      };
      final hydratedPosts = await Future.wait(
        posts.map((post) async {
          if (post.imagePath == null) return post;
          final known = knownUrls[post.imagePath!];
          if (known != null) return post.copyWith(imageUrl: known);
          try {
            final url = await _supabase.storage
                .from(_officialPostImageBucket)
                .createSignedUrl(post.imagePath!, 3600);
            return post.copyWith(imageUrl: url);
          } catch (_) {
            return post;
          }
        }),
      );
      if (!reuseUrls) _urlsSignedAt = DateTime.now();
      if (!mounted) return;
      setState(() {
        _officialPosts = hydratedPosts;
        _officialLoading = false;
        _officialError = null;
      });
    } catch (error) {
      debugPrint('OFFICIAL FEED ERROR: $error');
      if (!mounted) return;
      // A failed background refresh keeps the posts already shown.
      if (!showLoading && _officialPosts.isNotEmpty) return;
      setState(() {
        _officialLoading = false;
        _officialError = 'Could not load Official posts. Please try again.';
      });
    }
  }

  Future<void> _openOfficialDepartment(CampusDepartment department) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _OfficialDepartmentPage(
          department: department,
          onCreatePost: () => _openCreatePost(departmentCode: department.code),
          canAdminDelete: _isSuperAdmin,
          onAdminDelete: _deleteOfficialPost,
          onNavigateHome: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
          onOpenLiveChat: () {
            Navigator.of(context).popUntil((route) => route.isFirst);
            if (mounted) setState(() => _livePanelOpen = true);
          },
        ),
      ),
    );
    if (mounted) await _loadOfficialPosts(showLoading: false);
  }

  Future<void> _openDepartmentRooms() async {
    final selectedId = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => DepartmentRoomsPage(
          onNavigateHome: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
          onOpenLiveChat: () {
            Navigator.of(context).pop();
            if (!mounted) return;
            setState(() {
              _livePanelOpen = true;
              _chatJoined = false;
            });
          },
        ),
      ),
    );
    if (selectedId == null || !mounted) return;
    final room = _roomById(selectedId);
    if (room != null) await _openCampusRoom(room);
  }

  Future<void> _openMobileDepartments() async {
    if (_mode == _CampusMode.unofficial) {
      await _openDepartmentRooms();
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final department in campusDepartments)
              ListTile(
                leading: const Icon(Icons.school_outlined),
                title: Text(department.name),
                subtitle: Text(department.code.toUpperCase()),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openOfficialDepartment(department);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openCampusRoom(_CampusRoom room) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HomeFeedPage(
          initialRoomId: room.id,
          initialRoomName: room.name,
          roomPage: true,
        ),
      ),
    );
  }

  _CampusRoom? _roomById(String id) {
    for (final room in _rooms) {
      if (room.id == id) return room;
    }
    for (final department in campusDepartments) {
      if (department.roomId == id) {
        return _CampusRoom(id: id, name: department.name);
      }
    }
    return null;
  }

  Future<void> _loadPosts({bool showLoading = true}) async {
    if (showLoading && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final roomId = _selectedRoomId;
      if (roomId == null) {
        if (!mounted) return;
        setState(() {
          _posts = [];
          _loading = false;
          _error = null;
        });
        return;
      }
      final rows = await _supabase.rpc(
        'get_room_feed_with_media_v3',
        params: {'p_room_id': roomId},
      );
      final postRows = List<Map<String, dynamic>>.from(rows);
      final posts = postRows
          .map(
            (post) => _CampusPost(
              id: post['post_id'] as String,
              content: post['content'] as String,
              createdAt: DateTime.parse(post['created_at'] as String),
              authorUsername:
                  (post['author_username'] as String?) ?? 'Anonymous',
              avatarSeed: post['avatar_seed'] as String?,
              likeCount: (post['like_count'] as num).toInt(),
              likedByMe: post['liked_by_me'] as bool,
              imagePath: post['image_path'] as String?,
              replyCount: (post['reply_count'] as num).toInt(),
              isMine: post['is_mine'] as bool,
            ),
          )
          .toList();
      final reuseUrls = _urlsStillFresh;
      final knownUrls = {
        if (reuseUrls)
          for (final old in _posts)
            if (old.imagePath != null && old.imageUrl != null)
              old.imagePath!: old.imageUrl!,
      };
      final postsWithImageUrls = await Future.wait(
        posts.map((post) async {
          final path = post.imagePath;
          if (path == null) return post;
          final known = knownUrls[path];
          if (known != null) return post.copyWith(imageUrl: known);
          try {
            final url = await _supabase.storage
                .from(_postImageBucket)
                .createSignedUrl(path, 3600);
            return post.copyWith(imageUrl: url);
          } catch (_) {
            return post;
          }
        }),
      );

      if (!reuseUrls) _urlsSignedAt = DateTime.now();
      if (!mounted) return;
      setState(() {
        _posts = postsWithImageUrls;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      debugPrint('FEED ERROR: $error');
      if (!mounted) return;
      // A failed background refresh keeps the posts already shown.
      if (!showLoading && _posts.isNotEmpty) return;
      setState(() {
        _loading = false;
        _error = 'Could not load posts. Please try again.';
      });
    }
  }

  Future<void> _openCreatePost({String? departmentCode}) async {
    final modeAtOpen = _mode;
    final titleController = TextEditingController();
    final bodyController = TextEditingController();
    final selectedTags = <String>{};
    XFile? selectedImage;
    Uint8List? selectedImageBytes;
    String? imageError;
    String? validationError;
    bool pickingImage = false;

    final draft = await showDialog<_PostDraft>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return AlertDialog(
            title: const Text('Create a post'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: titleController,
                      autofocus: true,
                      maxLength: 120,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: 'Title *',
                        hintText: 'What is your post about?',
                        border: const OutlineInputBorder(),
                        errorText: validationError,
                      ),
                      onChanged: (_) {
                        if (validationError != null) {
                          setDialogState(() => validationError = null);
                        }
                      },
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Add tags',
                      style: Theme.of(dialogContext).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 7,
                      runSpacing: 0,
                      children: [
                        for (final tag in postTagOptions)
                          FilterChip(
                            label: Text(tag),
                            selected: selectedTags.contains(tag),
                            onSelected: (selected) => setDialogState(() {
                              if (selected) {
                                if (selectedTags.length < 3) {
                                  selectedTags.add(tag);
                                }
                              } else {
                                selectedTags.remove(tag);
                              }
                            }),
                          ),
                      ],
                    ),
                    TextField(
                      controller: bodyController,
                      minLines: 3,
                      maxLines: 6,
                      maxLength: 1500,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Body text (optional)',
                        hintText: 'Add more detail…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (selectedImageBytes != null) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          selectedImageBytes!,
                          height: 180,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () => setDialogState(() {
                            selectedImage = null;
                            selectedImageBytes = null;
                            imageError = null;
                          }),
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('Remove image'),
                        ),
                      ),
                    ],
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: pickingImage
                            ? null
                            : () async {
                                setDialogState(() {
                                  pickingImage = true;
                                  imageError = null;
                                });
                                try {
                                  final image = await ImagePicker().pickImage(
                                    source: ImageSource.gallery,
                                    maxWidth: 1800,
                                    maxHeight: 1800,
                                    imageQuality: 88,
                                  );
                                  if (image != null) {
                                    final bytes = await image.readAsBytes();
                                    final extension = _imageExtension(
                                      image.name,
                                    );
                                    if (bytes.length > _maxPostImageBytes) {
                                      setDialogState(() {
                                        imageError =
                                            'Choose an image under 5 MB.';
                                      });
                                    } else if (extension == null) {
                                      setDialogState(() {
                                        imageError =
                                            'Choose a JPG, PNG, or WebP image.';
                                      });
                                    } else {
                                      setDialogState(() {
                                        selectedImage = image;
                                        selectedImageBytes = bytes;
                                      });
                                    }
                                  }
                                } catch (_) {
                                  setDialogState(() {
                                    imageError = 'Could not open your photos.';
                                  });
                                } finally {
                                  setDialogState(() => pickingImage = false);
                                }
                              },
                        icon: pickingImage
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add_photo_alternate_outlined),
                        label: Text(
                          pickingImage ? 'Opening photos…' : 'Add image',
                        ),
                      ),
                    ),
                    if (imageError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          imageError!,
                          style: TextStyle(
                            color: Theme.of(dialogContext).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      'JPG, PNG, or WebP · up to 5 MB',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final title = titleController.text.trim();
                  if (title.isEmpty) {
                    setDialogState(
                      () => validationError = 'A title is required.',
                    );
                    return;
                  }
                  final payload = PostContent(
                    title: title,
                    tags: selectedTags.toList(growable: false),
                    body: bodyController.text.trim(),
                  ).encode();
                  if (payload.length > postContentLimit) {
                    setDialogState(
                      () => validationError =
                          'Shorten the title or body to fit the post limit.',
                    );
                    return;
                  }
                  Navigator.pop(
                    dialogContext,
                    _PostDraft(
                      title: title,
                      tags: selectedTags.toList(growable: false),
                      body: bodyController.text.trim(),
                      image: selectedImage,
                      imageBytes: selectedImageBytes,
                    ),
                  );
                },
                child: const Text('Post'),
              ),
            ],
          );
        },
      ),
    );
    titleController.dispose();
    bodyController.dispose();

    if (draft == null) return;
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    final roomId = _selectedRoomId;
    if (modeAtOpen == _CampusMode.unofficial && roomId == null) return;
    final officialRoomId = departmentCode != null
        ? 'dept-$departmentCode'
        : (roomId ?? 'general');

    setState(() => _posting = true);
    String? uploadedImagePath;
    try {
      final postId = _newPostId();
      if (draft.image != null && draft.imageBytes != null) {
        final extension = _imageExtension(draft.image!.name)!;
        final mimeType = switch (extension) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'png' => 'image/png',
          _ => 'image/webp',
        };
        uploadedImagePath = modeAtOpen == _CampusMode.official
            ? '${user.id}/$officialRoomId/posts/$postId/$postId.$extension'
            : 'posts/$postId/$postId.$extension';
        await _supabase.storage
            .from(
              modeAtOpen == _CampusMode.official
                  ? _officialPostImageBucket
                  : _postImageBucket,
            )
            .uploadBinary(
              uploadedImagePath,
              draft.imageBytes!,
              fileOptions: FileOptions(contentType: mimeType),
            );
      }
      if (modeAtOpen == _CampusMode.official) {
        await _supabase.rpc(
          'create_official_post',
          params: {
            'p_post_id': postId,
            'p_content': draft.encodedContent,
            'p_image_path': uploadedImagePath,
            'p_department_code': departmentCode,
            'p_room_id': officialRoomId,
          },
        );
        await _loadOfficialPosts(showLoading: false);
      } else {
        await _supabase.from('posts').insert({
          'id': postId,
          'content': draft.encodedContent,
          'room_id': roomId,
          'image_path': uploadedImagePath,
        });
        await _loadPosts(showLoading: false);
      }
      if (mounted) {
        var directPost =
            _isFaculty ||
            _isSuperAdmin ||
            (modeAtOpen == _CampusMode.unofficial && roomId == 'general');
        if (!directPost) {
          try {
            directPost =
                await _supabase.rpc(
                  'is_active_room_moderator',
                  params: {
                    'p_room': modeAtOpen == _CampusMode.official
                        ? officialRoomId
                        : roomId,
                    'p_mode': modeAtOpen.name,
                  },
                ) ==
                true;
          } catch (_) {}
        }
        if (mounted) {
          final isPending = !directPost;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isPending
                    ? 'Post submitted. It will appear after this room’s moderator approves it.'
                    : 'Post published.',
              ),
            ),
          );
        }
      }
    } catch (error) {
      debugPrint('Post publishing failed: $error');
      if (uploadedImagePath != null) {
        try {
          await _supabase.storage
              .from(
                modeAtOpen == _CampusMode.official
                    ? _officialPostImageBucket
                    : _postImageBucket,
              )
              .remove([uploadedImagePath]);
        } catch (_) {
          // Keep the original publish error visible; storage policy may block cleanup.
        }
      }
      if (mounted) {
        final message = switch (error) {
          StorageException(:final message, :final statusCode) =>
            'Image upload failed${statusCode == null ? '' : ' ($statusCode)'}: '
                '$message',
          PostgrestException(:final message, :final code) =>
            'Post save failed${code == null ? '' : ' ($code)'}: $message',
          _ =>
            'Could not publish (${error.runtimeType}). Check the terminal log.',
        };
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  String _newPostId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0'));
    final value = hex.join();
    return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }

  String? _imageExtension(String name) {
    final extension = name.split('.').last.toLowerCase();
    return const {'jpg', 'jpeg', 'png', 'webp'}.contains(extension)
        ? extension
        : null;
  }

  Future<void> _toggleLike(_CampusPost post) async {
    if (_likingPostIds.contains(post.id)) return;
    if (_supabase.auth.currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to like posts.')),
      );
      return;
    }

    setState(() => _likingPostIds.add(post.id));
    try {
      if (post.likedByMe) {
        await _supabase.from('post_likes').delete().eq('post_id', post.id);
      } else {
        await _supabase.from('post_likes').insert({'post_id': post.id});
      }

      if (!mounted) return;
      setState(() {
        final index = _posts.indexWhere((item) => item.id == post.id);
        if (index != -1) {
          final current = _posts[index];
          _posts[index] = current.copyWith(
            likedByMe: !post.likedByMe,
            likeCount: current.likeCount + (post.likedByMe ? -1 : 1),
          );
        }
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update your like.')),
        );
        await _loadPosts(showLoading: false);
      }
    } finally {
      if (mounted) setState(() => _likingPostIds.remove(post.id));
    }
  }

  Future<void> _openReplies(_CampusPost post) async {
    final replyCount = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PostRepliesSheet(postId: post.id),
    );
    if (replyCount == null || !mounted) return;
    final index = _posts.indexWhere((item) => item.id == post.id);
    if (index == -1) return;
    setState(() {
      _posts[index] = _posts[index].copyWith(replyCount: replyCount);
    });
  }

  Future<void> _toggleOfficialLike(_OfficialPost post) async {
    if (_likingPostIds.contains(post.id)) return;
    setState(() => _likingPostIds.add(post.id));
    try {
      final rows = await _supabase.rpc(
        'toggle_official_post_like',
        params: {'p_post_id': post.id},
      );
      final result = (rows as List).first as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        final index = _officialPosts.indexWhere((item) => item.id == post.id);
        if (index >= 0) {
          _officialPosts[index] = _officialPosts[index].copyWith(
            likeCount: (result['like_count'] as num).toInt(),
            likedByMe: result['liked_by_me'] as bool,
          );
        }
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not update like: ${friendlyError(error)}'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _likingPostIds.remove(post.id));
    }
  }

  Future<void> _openOfficialReplies(_OfficialPost post) async {
    final count = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PostRepliesSheet(postId: post.id, officialMode: true),
    );
    if (count == null || !mounted) return;
    setState(() {
      final index = _officialPosts.indexWhere((item) => item.id == post.id);
      if (index >= 0) {
        _officialPosts[index] = _officialPosts[index].copyWith(
          replyCount: count,
        );
      }
    });
  }

  Future<void> _deletePost(_CampusPost post) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this post?'),
        content: const Text(
          'The post and its replies will be permanently removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final imagePath = await _supabase.rpc(
        _isSuperAdmin ? 'admin_delete_post' : 'delete_my_post',
        params: _isSuperAdmin
            ? {'p_post_id': post.id, 'p_mode': 'unofficial'}
            : {'p_post_id': post.id},
      ) as String?;
      if (imagePath != null) {
        try {
          await _supabase.storage.from(_postImageBucket).remove([imagePath]);
        } catch (_) {
          // The post is already deleted; storage cleanup can be retried separately.
        }
      }
      if (!mounted) return;
      setState(() => _posts.removeWhere((item) => item.id == post.id));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Post deleted.')));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete this post.')),
        );
      }
    }
  }

  Future<void> _deleteOfficialPost(_OfficialPost post) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this post?'),
        content: const Text(
          'This will permanently remove the post and its replies.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final path = await _supabase.rpc(
        'admin_delete_post',
        params: {'p_post_id': post.id, 'p_mode': 'official'},
      ) as String?;
      if (path != null) {
        try {
          await _supabase.storage.from(_officialPostImageBucket).remove([path]);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _officialPosts.removeWhere((item) => item.id == post.id));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Post deleted.')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not delete post: ${friendlyError(error)}'),
          ),
        );
      }
    }
  }

  void _showFullImage(String imageUrl) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4,
                child: Center(
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: IconButton.filledTonal(
                  tooltip: 'Close image',
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFullCaption(String caption) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: SingleChildScrollView(child: SelectableText(caption)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _openProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfilePage(
          officialMode: _mode == _CampusMode.official,
          onCreatePost: () => _openCreatePost(),
          onNavigateHome: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
          onOpenLiveChat: () {
            Navigator.of(context).pop();
            if (!mounted) return;
            setState(() {
              _livePanelOpen = true;
              _chatJoined = false;
            });
          },
        ),
      ),
    );
    await _loadMyAvatarSeed();
    if (mounted && _mode == _CampusMode.unofficial) {
      await _loadPosts(showLoading: false);
    }
  }

  Future<void> _openFacultyModeratorPage() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FacultyModeratorPage(initialMode: _mode.name),
      ),
    );
  }

  Future<void> _openModeratorInbox() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ModeratorInboxPage()),
    );
  }

  Future<void> _loadPendingApprovalCount() async {
    if (widget.roomPage || !_hasModeratorInbox) return;
    try {
      final value = await _supabase.rpc(
        'get_pending_room_review_count',
        params: {'p_mode': _mode.name},
      );
      if (mounted) {
        setState(() => _pendingApprovalCount = (value as num?)?.toInt() ?? 0);
      }
    } catch (_) {
      // Keep the home feed usable if the review-inbox migration is not deployed.
    }
  }

  Future<void> _openReportQueue() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ReportQueuePage()),
    );
  }

  Future<void> _openHomePostReview() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HomePostReviewPage(mode: _mode.name),
      ),
    );
    await _loadPendingApprovalCount();
    if (_mode == _CampusMode.official) {
      await _loadOfficialPosts(showLoading: false);
    } else {
      await _loadPosts(showLoading: false);
    }
  }

  Future<void> _loadUnreadNotifications() async {
    try {
      final value = await _supabase.rpc('get_my_unread_notification_count');
      if (mounted) {
        setState(() => _unreadNotifications = (value as num?)?.toInt() ?? 0);
      }
    } catch (_) {
      // The app remains usable if the notification migration is not deployed.
    }
  }

  Future<void> _openNotifications() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const NotificationsPage()),
    );
    await _loadUnreadNotifications();
  }

  void _toggleLivePanel() {
    setState(() {
      _livePanelOpen = !_livePanelOpen;
      if (!_livePanelOpen) _chatJoined = false;
    });
  }

  bool get _canManageModerators =>
      _isSuperAdmin || (_mode == _CampusMode.official && _isFaculty);

  void _goHome() {
    if (widget.roomPage) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else if (_livePanelOpen) {
      _toggleLivePanel();
    } else if (_homeScrollController.hasClients) {
      _homeScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    }
  }

  List<Widget> _buildAppBarActions({required bool compact}) {
    final compactButtonStyle = compact
        ? IconButton.styleFrom(
            minimumSize: const Size(40, 40),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          )
        : null;
    final home = IconButton(
      tooltip: 'Home',
      onPressed: _goHome,
      icon: const Icon(Icons.home_outlined),
      style: compactButtonStyle,
    );
    final live = CampusLiveAction(
      active: _livePanelOpen,
      onPressed: _toggleLivePanel,
      compact: compact,
    );
    final moderators = _canManageModerators
        ? IconButton(
            tooltip: 'Manage room moderators',
            onPressed: _openFacultyModeratorPage,
            icon: const Icon(Icons.admin_panel_settings_outlined),
            style: compactButtonStyle,
          )
        : null;
    final profile = IconButton(
      tooltip: 'My profile',
      onPressed: _openProfile,
      icon: _mode == _CampusMode.unofficial
          ? StudentAvatar(seed: _myAvatarSeed, size: 32)
          : const Icon(Icons.school_rounded),
      style: compactButtonStyle,
    );

    final notifications = IconButton(
      tooltip: 'Activity notifications',
      onPressed: _openNotifications,
      icon: Badge(
        isLabelVisible: _unreadNotifications > 0,
        label: Text(
          _unreadNotifications > 99 ? '99+' : '$_unreadNotifications',
        ),
        child: const Icon(Icons.notifications_none_rounded),
      ),
      style: compactButtonStyle,
    );
    final pendingApprovals = !widget.roomPage && _hasModeratorInbox
        ? IconButton(
            tooltip: 'Pending post approvals',
            onPressed: _openHomePostReview,
            icon: Badge(
              isLabelVisible: _pendingApprovalCount > 0,
              label: Text(
                _pendingApprovalCount > 99 ? '99+' : '$_pendingApprovalCount',
              ),
              child: const Icon(Icons.fact_check_outlined),
            ),
            style: compactButtonStyle,
          )
        : null;
    final reports = _isSuperAdmin
        ? IconButton(
            tooltip: 'Reported content',
            onPressed: _openReportQueue,
            icon: const Icon(Icons.flag_outlined),
            style: compactButtonStyle,
          )
        : null;
    final theme = IconButton(
      tooltip: Theme.of(context).brightness == Brightness.dark
          ? 'Switch to light theme'
          : 'Switch to dark theme',
      onPressed: AppThemeScope.of(context).toggle,
      icon: Icon(
        Theme.of(context).brightness == Brightness.dark
            ? Icons.light_mode_outlined
            : Icons.dark_mode_outlined,
      ),
      style: compactButtonStyle,
    );

    if (compact) {
      if (!widget.roomPage) {
        return [
          notifications,
          ?pendingApprovals,
          ?reports,
          live,
          ?moderators,
          theme,
        ];
      }
      return [
        notifications,
        live,
        PopupMenuButton<String>(
          tooltip: 'More options',
          padding: EdgeInsets.zero,
          iconSize: 24,
          onSelected: (action) {
            switch (action) {
              case 'inbox':
                _openModeratorInbox();
                break;
              case 'rooms':
                _scaffoldKey.currentState?.openDrawer();
                break;
              case 'review':
                _openRoomPostReview();
                break;
              case 'contact':
                _openModeratorContact();
                break;
              case 'theme':
                AppThemeScope.of(context).toggle();
                break;
              case 'moderators':
                _openFacultyModeratorPage();
                break;
              case 'profile':
                _openProfile();
                break;
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'profile', child: Text('My profile')),
            if (_hasModeratorInbox)
              const PopupMenuItem(
                value: 'inbox',
                child: Text('Moderator inbox'),
              ),
            if (widget.roomPage)
              const PopupMenuItem(value: 'rooms', child: Text('Explore rooms')),
            if (widget.roomPage && _canReviewRoomPosts && !_isSuperAdmin)
              const PopupMenuItem(
                value: 'review',
                child: Text('Review pending posts'),
              ),
            if (widget.roomPage)
              const PopupMenuItem(
                value: 'contact',
                child: Text('Contact moderator'),
              ),
            if (widget.roomPage && moderators != null)
              const PopupMenuItem(
                value: 'moderators',
                child: Text('Manage moderators'),
              ),
            PopupMenuItem(
              value: 'theme',
              child: Text(
                Theme.of(context).brightness == Brightness.dark
                    ? 'Switch to light theme'
                    : 'Switch to dark theme',
              ),
            ),
          ],
        ),
      ];
    }

    return [
      home,
      notifications,
      if (!widget.roomPage && _hasModeratorInbox)
        IconButton(
          tooltip: 'Moderator inbox',
          onPressed: _openModeratorInbox,
          icon: const Icon(Icons.inbox_outlined),
        ),
      ?pendingApprovals,
      ?reports,
      if (widget.roomPage)
        IconButton(
          tooltip: 'Explore rooms',
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          icon: const Icon(Icons.menu_rounded),
        ),
      if (widget.roomPage && _canReviewRoomPosts && !_isSuperAdmin)
        IconButton(
          tooltip: 'Review pending posts',
          onPressed: _openRoomPostReview,
          icon: const Icon(Icons.fact_check_outlined),
        ),
      if (widget.roomPage)
        IconButton(
          tooltip: 'Contact moderator',
          onPressed: _openModeratorContact,
          icon: const Icon(Icons.support_agent_outlined),
        ),
      live,
      if (!widget.roomPage && moderators != null) moderators,
      theme,
      profile,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!_identityLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_identityError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_identityError!, textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final compactToolbar = MediaQuery.sizeOf(context).width < 560;
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        leading: widget.roomPage
            ? IconButton(
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_rounded),
              )
            : compactToolbar
            ? IconButton(
                tooltip: 'Explore rooms',
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                icon: const Icon(Icons.menu_rounded),
              )
            : null,
        leadingWidth: compactToolbar ? 48 : null,
        titleSpacing: compactToolbar ? 2 : null,
        title: widget.roomPage
            ? Text(widget.initialRoomName ?? 'Room')
            : WhisperBrand(
                centered: !compactToolbar,
                iconSize: compactToolbar ? 22 : 32,
                wordmarkSize: compactToolbar ? 12 : 17,
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                accentColor: Theme.of(context).colorScheme.primary,
                bubbleInteriorColor: Theme.of(context).colorScheme.surface,
              ),
        actions: _buildAppBarActions(compact: compactToolbar),
      ),
      onDrawerChanged: (isOpen) {
        if (mounted) setState(() => _drawerOpen = isOpen);
      },
      drawerScrimColor: Colors.transparent,
      drawer: Drawer(
        width: min(300.0, MediaQuery.sizeOf(context).width * 0.88).toDouble(),
        child: SafeArea(child: _buildExploreDrawer()),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final pushWidth = constraints.maxWidth >= 760
              ? 300.0
              : constraints.maxWidth >= 560
              ? constraints.maxWidth * 0.44
              : 0.0;
          return AnimatedPadding(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(left: _drawerOpen ? pushWidth : 0),
            child: _buildHomeWithLivePanel(),
          );
        },
      ),
      bottomNavigationBar: compactToolbar && !widget.roomPage
          ? MediaQuery.withClampedTextScaling(
              // Keep the five labels on one line even with large system text.
              maxScaleFactor: 1.1,
              child: NavigationBarTheme(
                // Smaller, tighter labels so "Departments" stays on one line on
                // narrow phones instead of wrapping its last letter.
                data: NavigationBarThemeData(
                  labelTextStyle: WidgetStateProperty.resolveWith((states) {
                    final selected = states.contains(WidgetState.selected);
                    return TextStyle(
                      fontSize: 10.5,
                      letterSpacing: 0,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    );
                  }),
                ),
                child: NavigationBar(
                  height: 66,
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                  selectedIndex: 0,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home_rounded),
                      label: 'Home',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.groups_outlined),
                      selectedIcon: Icon(Icons.groups_rounded),
                      label: 'Departments',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.add_circle_outline_rounded),
                      selectedIcon: Icon(Icons.add_circle_rounded),
                      label: 'Post',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.notifications_none_rounded),
                      selectedIcon: Icon(Icons.notifications_rounded),
                      label: 'Activity',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.person_outline_rounded),
                      selectedIcon: Icon(Icons.person_rounded),
                      label: 'Profile',
                    ),
                  ],
                  onDestinationSelected: (index) {
                    switch (index) {
                      case 0:
                        _goHome();
                        break;
                      case 1:
                        _openMobileDepartments();
                        break;
                      case 2:
                        if (!_posting) _openCreatePost();
                        break;
                      case 3:
                        _openNotifications();
                        break;
                      case 4:
                        _openProfile();
                        break;
                    }
                  },
                ),
              ),
            )
          : null,
      floatingActionButton: _livePanelOpen
          ? null
          : widget.roomPage && _roomChatSelected
          ? null
          : compactToolbar && !widget.roomPage
          ? null
          : FloatingActionButton.extended(
              onPressed: _posting ? null : _openCreatePost,
              icon: _posting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: Text(_posting ? 'Posting…' : 'Create post'),
            ),
    );
  }

  Widget _buildExploreDrawer() {
    final colors = Theme.of(context).colorScheme;
    final official = _mode == _CampusMode.official;
    final rooms = _rooms
        .where(
          (room) =>
              room.id != 'general' &&
              room.id != 'official-live' &&
              !room.id.startsWith('dept-'),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 16),
          child: Row(
            children: [
              Icon(
                official ? Icons.school_rounded : Icons.explore_rounded,
                color: colors.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      official ? 'Explore departments' : 'Explore rooms',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      official
                          ? 'Find your branch community'
                          : 'Find your campus community',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.outlineVariant),
        Expanded(
          child: official
              ? ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: campusDepartments.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final department = campusDepartments[index];
                    return _buildExploreRow(
                      title: department.name,
                      subtitle: department.code.toUpperCase(),
                      icon: Icons.school_outlined,
                      onTap: () {
                        Navigator.of(context).pop();
                        _openOfficialDepartment(department);
                      },
                    );
                  },
                )
              : rooms.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _loading ? 'Loading rooms…' : 'No rooms available yet.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: rooms.length + 1,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    if (index == rooms.length) {
                      return _buildExploreRow(
                        title: 'Department rooms',
                        subtitle: 'Browse every branch',
                        icon: Icons.account_tree_outlined,
                        onTap: () {
                          Navigator.of(context).pop();
                          _openDepartmentRooms();
                        },
                      );
                    }
                    final room = rooms[index];
                    return _buildExploreRow(
                      title: room.name,
                      subtitle: room.id == 'departments'
                          ? 'Browse every branch'
                          : 'Open conversation room',
                      icon: _roomIcon(room.id),
                      onTap: () {
                        Navigator.of(context).pop();
                        if (room.id == 'departments') {
                          _openDepartmentRooms();
                        } else {
                          _openCampusRoom(room);
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildExploreRow({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Icon(icon, size: 20, color: colors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _roomIcon(String roomId) => switch (roomId) {
    'events' => Icons.event_outlined,
    'clubs' => Icons.groups_outlined,
    'campus-life' => Icons.local_cafe_outlined,
    'academics' => Icons.menu_book_outlined,
    'sports' => Icons.sports_basketball_outlined,
    'departments' => Icons.school_outlined,
    _ => Icons.forum_outlined,
  };

  Widget _buildBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = constraints.maxWidth >= 1320
            ? (constraints.maxWidth - 1260) / 2
            : constraints.maxWidth >= 820
            ? 28.0
            : 16.0;
        return RefreshIndicator(
          onRefresh: () => _mode == _CampusMode.official
              ? _loadOfficialPosts()
              : _loadPosts(),
          child: ListView(
            controller: _homeScrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              16,
              horizontalPadding,
              104,
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: _buildModeSwitcher(),
              ),
              const SizedBox(height: 20),
              if (_mode == _CampusMode.official)
                _buildOfficialHome()
              else ...[
                _buildWelcomeCard(),
                const SizedBox(height: 16),
                _buildFeedSection(),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildHomeWithLivePanel() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelWidth = constraints.maxWidth >= 900
            ? constraints.maxWidth * 0.4
            : constraints.maxWidth;
        final keepFeedVisible = constraints.maxWidth >= 900;
        return Stack(
          children: [
            Positioned.fill(
              right: _livePanelOpen && keepFeedVisible ? panelWidth : 0,
              child: widget.roomPage ? _buildRoomPage() : _buildBody(),
            ),
            if (_livePanelOpen)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: panelWidth,
                child: _buildLivePanel(),
              ),
          ],
        );
      },
    );
  }

  Widget _buildLivePanel() {
    final colors = Theme.of(context).colorScheme;
    final official = _mode == _CampusMode.official;
    final roomId = official ? 'official-live' : 'general';
    final roomName = official ? 'Official Campus Live' : 'Campus-wide';
    return Material(
      elevation: 12,
      color: colors.surface,
      child: _chatJoined
          ? RoomChatPage(
              roomId: roomId,
              roomName: roomName,
              embedded: true,
              onClose: _toggleLivePanel,
            )
          : LiveRoomPreview(
              key: ValueKey('campus-live-side-panel-$roomId'),
              roomId: roomId,
              roomName: roomName,
              expanded: true,
              hideMessagesUntilJoined: official,
              onClose: _toggleLivePanel,
              onJoin: () => setState(() => _chatJoined = true),
            ),
    );
  }

  Widget _buildRoomPage() {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Anonymous conversations',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'Posts from ${widget.initialRoomName ?? _selectedRoomName}. Your identity stays anonymous.',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _roomTabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            const Tab(text: 'Posts'),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Chat'),
                  if (_roomUnreadCount > 0) ...[
                    const SizedBox(width: 7),
                    _UnreadMessageBadge(count: _roomUnreadCount),
                  ],
                ],
              ),
            ),
          ],
        ),
        Expanded(
          child: _roomChatSelected
              ? RoomChatPage(
                  key: ValueKey('unofficial-room-chat-$_selectedRoomId'),
                  roomId: _selectedRoomId ?? 'general',
                  roomName: widget.initialRoomName ?? _selectedRoomName,
                  embedded: true,
                  roomConversation: true,
                  roomMode: 'unofficial',
                  onRead: () {
                    if (mounted && _roomUnreadCount != 0) {
                      setState(() => _roomUnreadCount = 0);
                    }
                  },
                )
              : RefreshIndicator(
                  onRefresh: _loadPosts,
                  child: ListView(
                    controller: _homeScrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 104),
                    children: [_buildFeedSection()],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildFeedSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: 'Refresh feed',
            onPressed: () => _loadPosts(showLoading: false),
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  const Icon(Icons.cloud_off_outlined, size: 36),
                  const SizedBox(height: 8),
                  Text(_error!, textAlign: TextAlign.center),
                  TextButton(
                    onPressed: _rooms.isEmpty ? _loadRooms : _loadPosts,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          )
        else if (_posts.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
              child: Column(
                children: [
                  Icon(
                    Icons.forum_outlined,
                    size: 40,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 8),
                  const Text('No posts in this room yet.'),
                  TextButton.icon(
                    onPressed: _posting ? null : _openCreatePost,
                    icon: const Icon(Icons.add),
                    label: const Text('Start the conversation'),
                  ),
                ],
              ),
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 740),
              child: Column(
                children: [for (final post in _posts) _buildPostCard(post)],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildModeSwitcher() {
    return SegmentedButton<_CampusMode>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: _CampusMode.unofficial,
          label: Text('Unofficial'),
          icon: Icon(Icons.forum_outlined),
        ),
        ButtonSegment(
          value: _CampusMode.official,
          label: Text('Official'),
          icon: Icon(Icons.verified_outlined),
        ),
      ],
      selected: {_mode},
      onSelectionChanged: (selection) {
        _changeMode(selection.first);
      },
    );
  }

  Widget _buildOfficialHome() {
    final colors = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final departmentListHeight = (screenHeight * 0.40)
        .clamp(260.0, 430.0)
        .toDouble();
    final carouselHeight = (screenHeight * 0.35).clamp(230.0, 380.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: colors.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'OFFICIAL CAMPUS',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: colors.primary,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                            ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Your campus, together.',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Real names · MITS community',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.school_rounded, size: 36),
              ],
            ),
          ),
        ),
        if (_mode == _CampusMode.official && (_isFaculty || _isSuperAdmin)) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: colors.secondaryContainer,
                    foregroundColor: colors.onSecondaryContainer,
                    child: const Icon(Icons.admin_panel_settings_outlined),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Faculty dashboard',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 3),
                        const Text(
                          'Post to Official rooms and manage moderators.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _openFacultyModeratorPage,
                    icon: const Icon(Icons.manage_accounts_outlined),
                    label: const Text('Moderators'),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        _buildSectionHeading(
          'Explore the departments',
          'Find your branch community.',
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: departmentListHeight,
          child: ListView.separated(
            itemCount: campusDepartments.length,
            separatorBuilder: (context, index) => const SizedBox(height: 7),
            itemBuilder: (context, index) {
              final department = campusDepartments[index];
              return Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: colors.secondaryContainer,
                    foregroundColor: colors.onSecondaryContainer,
                    child: const Icon(Icons.school_outlined),
                  ),
                  title: Text(
                    department.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(department.code.toUpperCase()),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _openOfficialDepartment(department),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 20),
        _buildSectionHeading(
          'Official campus feed',
          'Posts shared with the MITS community.',
          trailing: IconButton(
            tooltip: 'Refresh Official feed',
            onPressed: () => _loadOfficialPosts(showLoading: false),
            icon: const Icon(Icons.refresh),
          ),
        ),
        const SizedBox(height: 8),
        if (_officialLoading)
          SizedBox(
            height: carouselHeight,
            child: const Center(child: CircularProgressIndicator()),
          )
        else if (_officialError != null)
          SizedBox(
            height: carouselHeight,
            child: Card(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_officialError!, textAlign: TextAlign.center),
                      TextButton(
                        onPressed: _loadOfficialPosts,
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        else if (_officialPosts.isEmpty)
          SizedBox(
            height: carouselHeight,
            child: Card(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.campaign_outlined, color: colors.primary),
                    const SizedBox(height: 8),
                    const Text('No Official posts yet.'),
                    TextButton.icon(
                      onPressed: _posting ? null : _openCreatePost,
                      icon: const Icon(Icons.add),
                      label: const Text('Create the first post'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 740),
              child: Column(
                children: [
                  for (final post in _officialPosts) ...[
                    _OfficialPostCard(
                      post: post,
                      onTap: post.imageUrl == null
                          ? null
                          : () => _showFullImage(post.imageUrl!),
                      onLike: () => _toggleOfficialLike(post),
                      onComments: () => _openOfficialReplies(post),
                      liking: _likingPostIds.contains(post.id),
                      canAdminDelete: _isSuperAdmin,
                      onAdminDelete: () => _deleteOfficialPost(post),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  String get _selectedRoomName {
    for (final room in _rooms) {
      if (room.id == _selectedRoomId) return room.name;
    }
    return 'campus';
  }

  Widget _buildWelcomeCard() {
    final colors = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 560;
    return Card(
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 24,
          vertical: compact ? 16 : 22,
        ),
        child: Row(
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      'UNOFFICIAL CAMPUS',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: colors.secondary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: compact ? 1 : 1.3,
                        fontSize: compact ? 13 : null,
                      ),
                    ),
                    SizedBox(height: compact ? 4 : 6),
                    Text(
                      'Your campus, your corner.',
                      textAlign: TextAlign.center,
                      style: compact
                          ? Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              height: 1.05,
                              fontSize: 23,
                            )
                          : Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  height: 1.05,
                                ),
                    ),
                    SizedBox(height: compact ? 3 : 4),
                    Text(
                      'Talk freely. Stay anonymous.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontSize: compact ? 14 : 17,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(width: compact ? 12 : 20),
            Container(
              width: compact ? 44 : 58,
              height: compact ? 44 : 58,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(compact ? 16 : 20),
              ),
              child: Icon(
                Icons.waving_hand_rounded,
                color: colors.onPrimaryContainer,
                size: compact ? 22 : 28,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeading(
    String title,
    String subtitle, {
    Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 3),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }

  Widget _buildPostCard(_CampusPost post) {
    final colors = Theme.of(context).colorScheme;
    final imageUrl = post.imageUrl;
    final formatted = PostContent.decode(post.content);
    final displayBody = formatted.body;
    final fullText = [
      if (formatted.title.isNotEmpty) formatted.title,
      if (formatted.tags.isNotEmpty) formatted.tags.join(' · '),
      if (displayBody.isNotEmpty) displayBody,
    ].join('\n\n');
    return LayoutBuilder(
      builder: (context, constraints) {
        // Posts size to their content, so short text posts stay compact.
        return _HoverablePostSurface(
          colors: colors,
          child: ConstrainedBox(
            constraints: const BoxConstraints(),
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: 0.65),
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        StudentAvatar(seed: post.avatarSeed, size: 36),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                post.authorUsername,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              Text(
                                '$_selectedRoomName · Unofficial',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          _formatDate(post.createdAt),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Post options',
                          onSelected: (value) {
                            if (value == 'delete') _deletePost(post);
                            if (value == 'report') {
                              reportContent(
                                context,
                                target: ReportTarget.post,
                                targetId: post.id,
                              );
                            }
                          },
                          itemBuilder: (context) => [
                            if (!post.isMine)
                              const PopupMenuItem(
                                value: 'report',
                                child: Row(
                                  children: [
                                    Icon(Icons.flag_outlined),
                                    SizedBox(width: 10),
                                    Text('Report post'),
                                  ],
                                ),
                              ),
                            if (post.isMine || _isSuperAdmin)
                              const PopupMenuItem(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete_outline),
                                    SizedBox(width: 10),
                                    Text('Delete post'),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (formatted.title.isNotEmpty)
                      Text(
                        formatted.title,
                        maxLines: imageUrl == null ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              height: 1.25,
                            ),
                      ),
                    if (formatted.tags.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final tag in formatted.tags) _postTag(tag),
                        ],
                      ),
                    ],
                    if (displayBody.isNotEmpty) ...[
                      if (formatted.title.isNotEmpty ||
                          formatted.tags.isNotEmpty)
                        const SizedBox(height: 6),
                      InkWell(
                        onTap: fullText.length > 220
                            ? () => _showFullCaption(fullText)
                            : null,
                        borderRadius: BorderRadius.circular(8),
                        hoverColor: Colors.transparent,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  displayBody,
                                  maxLines: imageUrl == null ? 3 : 5,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(height: 1.35),
                                ),
                                if (fullText.length > 220)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Text(
                                      'Tap to read more',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium
                                          ?.copyWith(
                                            color: colors.primary,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ] else if (formatted.title.isEmpty && imageUrl == null)
                      Text(
                        'Shared a post',
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    if (imageUrl != null) ...[
                      if (post.content.isNotEmpty) const SizedBox(height: 10),
                      PostMediaFrame(
                        imageUrl: imageUrl,
                        onTap: () => _showFullImage(imageUrl),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: post.likedByMe ? 'Unlike post' : 'Like post',
                          onPressed: _likingPostIds.contains(post.id)
                              ? null
                              : () => _toggleLike(post),
                          icon: _likingPostIds.contains(post.id)
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  post.likedByMe
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: post.likedByMe ? colors.error : null,
                                ),
                        ),
                        Text('${post.likeCount}'),
                        const SizedBox(width: 14),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: 'View or add replies',
                          onPressed: () => _openReplies(post),
                          icon: const Icon(Icons.mode_comment_outlined),
                        ),
                        Text('${post.replyCount}'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _postTag(String tag) {
    final colors = Theme.of(context).colorScheme;
    final urgent = tag.toLowerCase() == 'urgent';
    final doubt = tag.toLowerCase() == 'doubt/query';
    final background = urgent || doubt
        ? colors.errorContainer
        : colors.secondaryContainer;
    final foreground = urgent || doubt
        ? colors.onErrorContainer
        : colors.onSecondaryContainer;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(
          tag,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    return '$day/$month/${local.year}';
  }
}

class _OfficialPost {
  const _OfficialPost({
    required this.id,
    required this.departmentCode,
    required this.authorName,
    required this.branch,
    required this.academicYear,
    required this.content,
    required this.createdAt,
    required this.imagePath,
    this.likeCount = 0,
    this.likedByMe = false,
    this.replyCount = 0,
    this.imageUrl,
  });

  final String id;
  final String? departmentCode;
  final String authorName;
  final String branch;
  final int academicYear;
  final String content;
  final DateTime createdAt;
  final String? imagePath;
  final String? imageUrl;
  final int likeCount;
  final bool likedByMe;
  final int replyCount;

  _OfficialPost copyWith({
    String? imageUrl,
    int? likeCount,
    bool? likedByMe,
    int? replyCount,
  }) => _OfficialPost(
    id: id,
    departmentCode: departmentCode,
    authorName: authorName,
    branch: branch,
    academicYear: academicYear,
    content: content,
    createdAt: createdAt,
    imagePath: imagePath,
    imageUrl: imageUrl ?? this.imageUrl,
    likeCount: likeCount ?? this.likeCount,
    likedByMe: likedByMe ?? this.likedByMe,
    replyCount: replyCount ?? this.replyCount,
  );
}

class _OfficialPostCard extends StatelessWidget {
  const _OfficialPostCard({
    required this.post,
    required this.onTap,
    required this.onLike,
    required this.onComments,
    this.liking = false,
    this.canAdminDelete = false,
    this.onAdminDelete,
  });

  final _OfficialPost post;
  final VoidCallback? onTap;
  final VoidCallback onLike;
  final VoidCallback onComments;
  final bool liking;
  final bool canAdminDelete;
  final VoidCallback? onAdminDelete;

  String _dateLabel() {
    final date = post.createdAt.toLocal();
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    return '$day/$month/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final formatted = PostContent.decode(post.content);
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.65),
            ),
          ),
        ),
        child: InkWell(
          onTap: onTap,
          hoverColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: colors.primaryContainer,
                      foregroundColor: colors.onPrimaryContainer,
                      child: const Icon(Icons.school_rounded),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            post.authorName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          Text(
                            post.academicYear <= 0
                                ? (post.branch.isEmpty
                                      ? 'Faculty'
                                      : post.branch)
                                : '${post.branch} · Year ${post.academicYear}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Post options',
                      onSelected: (value) {
                        if (value == 'delete') onAdminDelete?.call();
                        if (value == 'report') {
                          reportContent(
                            context,
                            target: ReportTarget.officialPost,
                            targetId: post.id,
                          );
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'report',
                          child: Text('Report post'),
                        ),
                        if (canAdminDelete && onAdminDelete != null)
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete post'),
                          ),
                      ],
                    ),
                    Text(
                      _dateLabel(),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
                if (formatted.title.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    formatted.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ],
                if (formatted.tags.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 6,
                    children: formatted.tags
                        .map(
                          (tag) => Chip(
                            label: Text(tag),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
                if (formatted.body.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    formatted.body,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(height: 1.35),
                  ),
                ],
                if (post.imageUrl != null) ...[
                  const SizedBox(height: 10),
                  PostMediaFrame(
                    imageUrl: post.imageUrl!,
                    onTap: onTap,
                    aspectRatio: 1.45,
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: post.likedByMe ? 'Unlike post' : 'Like post',
                      onPressed: liking ? null : onLike,
                      icon: liking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              post.likedByMe
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: post.likedByMe ? colors.error : null,
                            ),
                    ),
                    Text('${post.likeCount}'),
                    const SizedBox(width: 10),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'View or add comments',
                      onPressed: onComments,
                      icon: const Icon(Icons.mode_comment_outlined),
                    ),
                    Text('${post.replyCount}'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OfficialDepartmentPage extends StatefulWidget {
  const _OfficialDepartmentPage({
    required this.department,
    required this.onCreatePost,
    required this.onNavigateHome,
    required this.onOpenLiveChat,
    required this.canAdminDelete,
    required this.onAdminDelete,
  });

  final CampusDepartment department;
  final Future<void> Function() onCreatePost;
  final VoidCallback onNavigateHome;
  final VoidCallback onOpenLiveChat;
  final bool canAdminDelete;
  final Future<void> Function(_OfficialPost post) onAdminDelete;

  @override
  State<_OfficialDepartmentPage> createState() =>
      _OfficialDepartmentPageState();
}

class _OfficialDepartmentPageState extends State<_OfficialDepartmentPage>
    with SingleTickerProviderStateMixin {
  final _supabase = Supabase.instance.client;
  final Set<String> _likingPostIds = {};
  List<_OfficialPost> _posts = [];
  bool _loading = true;
  String? _error;
  late final TabController _tabController;
  Timer? _unreadTimer;
  DateTime? _urlsSignedAt;
  bool get _urlsStillFresh =>
      _urlsSignedAt != null &&
      DateTime.now().difference(_urlsSignedAt!) < _signedUrlReuseWindow;
  LiveSubscription? _liveSubscription;
  final _liveRefresh = Debouncer();
  bool _chatSelected = false;
  int _unreadCount = 0;
  bool _canReviewPosts = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(_handleTabChanged);
    _unreadTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _loadUnreadCount(),
    );
    _loadPosts();
    _liveSubscription = LiveSignals.instance.listen('feed:official', (signal) {
      final room = signal['room_id'] as String?;
      final relevant =
          signal['kind'] == 'resync' ||
          room == null ||
          room == 'dept-${widget.department.code}';
      if (!relevant) return;
      _liveRefresh.run(() {
        if (mounted) _loadPosts(showLoading: false);
      });
    });
    _loadUnreadCount();
    _loadReviewAccess();
  }

  Future<void> _loadReviewAccess() async {
    final roomId = 'dept-${widget.department.code}';
    try {
      final moderator = await _supabase.rpc(
        'is_active_room_moderator',
        params: {'p_room': roomId, 'p_mode': 'official'},
      );
      final admin = await _supabase.rpc('is_super_admin');
      if (mounted) {
        setState(() => _canReviewPosts = moderator == true || admin == true);
      }
    } catch (_) {
      // Keep regular room browsing available if the optional review check fails.
    }
  }

  Future<void> _openReviewQueue() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RoomPostReviewPage(
          roomId: 'dept-${widget.department.code}',
          roomName: widget.department.name,
          mode: 'official',
        ),
      ),
    );
    if (mounted) await _loadPosts();
  }

  Future<void> _openModeratorContact() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RoomModeratorContactPage(
          roomId: 'dept-${widget.department.code}',
          roomName: widget.department.name,
          mode: 'official',
        ),
      ),
    );
  }

  void _handleTabChanged() {
    if (_tabController.indexIsChanging) return;
    final chatSelected = _tabController.index == 1;
    if (_chatSelected == chatSelected || !mounted) return;
    setState(() {
      _chatSelected = chatSelected;
      if (chatSelected) _unreadCount = 0;
    });
    if (!chatSelected) {
      Future<void>.delayed(const Duration(milliseconds: 250), _loadUnreadCount);
    }
  }

  Future<void> _loadUnreadCount() async {
    if (_chatSelected) return;
    try {
      final unread = await _supabase.rpc(
        'get_room_chat_unread',
        params: {
          'p_room_id': 'dept-${widget.department.code}',
          'p_mode': 'official',
        },
      );
      if (!mounted || _chatSelected) return;
      setState(() => _unreadCount = (unread as num?)?.toInt() ?? 0);
    } catch (_) {
      // The feed remains available while the optional unread count refreshes.
    }
  }

  Future<void> _loadPosts({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final rows = await _supabase.rpc(
        'get_official_posts_with_activity',
        params: {
          'p_department_code': widget.department.code,
          'p_limit': 100,
          'p_room_id': 'dept-${widget.department.code}',
        },
      );
      final posts = List<Map<String, dynamic>>.from(rows).map((row) {
        return _OfficialPost(
          id: row['post_id'] as String,
          departmentCode: row['department_code'] as String?,
          authorName: row['author_name'] as String,
          branch: row['author_branch'] as String,
          academicYear: (row['author_year'] as num?)?.toInt() ?? 0,
          content: row['content'] as String,
          createdAt: DateTime.parse(row['created_at'] as String),
          imagePath: row['image_path'] as String?,
          likeCount: (row['like_count'] as num).toInt(),
          likedByMe: row['liked_by_me'] as bool,
          replyCount: (row['comment_count'] as num).toInt(),
        );
      }).toList();
      final reuseUrls = _urlsStillFresh;
      final knownUrls = {
        if (reuseUrls)
          for (final old in _posts)
            if (old.imagePath != null && old.imageUrl != null)
              old.imagePath!: old.imageUrl!,
      };
      final hydrated = await Future.wait(
        posts.map((post) async {
          if (post.imagePath == null) return post;
          final known = knownUrls[post.imagePath!];
          if (known != null) return post.copyWith(imageUrl: known);
          try {
            final url = await _supabase.storage
                .from(_officialPostImageBucket)
                .createSignedUrl(post.imagePath!, 3600);
            return post.copyWith(imageUrl: url);
          } catch (_) {
            return post;
          }
        }),
      );
      if (!reuseUrls) _urlsSignedAt = DateTime.now();
      if (!mounted) return;
      setState(() {
        _posts = hydrated;
        _loading = false;
      });
    } catch (error) {
      debugPrint('OFFICIAL DEPARTMENT ERROR: $error');
      if (!mounted) return;
      if (!showLoading && _posts.isNotEmpty) return;
      setState(() {
        _error = 'Could not load this department. Please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _createPost() async {
    await widget.onCreatePost();
    if (mounted) await _loadPosts();
  }

  Future<void> _togglePostLike(_OfficialPost post) async {
    if (_likingPostIds.contains(post.id)) return;
    setState(() => _likingPostIds.add(post.id));
    try {
      final rows = await _supabase.rpc(
        'toggle_official_post_like',
        params: {'p_post_id': post.id},
      );
      final result = (rows as List).first as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        final index = _posts.indexWhere((item) => item.id == post.id);
        if (index >= 0) {
          _posts[index] = _posts[index].copyWith(
            likeCount: (result['like_count'] as num).toInt(),
            likedByMe: result['liked_by_me'] as bool,
          );
        }
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not update like: ${friendlyError(error)}'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _likingPostIds.remove(post.id));
    }
  }

  Future<void> _openPostComments(_OfficialPost post) async {
    final count = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PostRepliesSheet(postId: post.id, officialMode: true),
    );
    if (count == null || !mounted) return;
    setState(() {
      final index = _posts.indexWhere((item) => item.id == post.id);
      if (index >= 0) _posts[index] = _posts[index].copyWith(replyCount: count);
    });
  }

  @override
  void dispose() {
    _liveSubscription?.cancel();
    _liveRefresh.dispose();
    _unreadTimer?.cancel();
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.department.name),
        actions: [
          IconButton(
            tooltip: 'Home',
            onPressed: widget.onNavigateHome,
            icon: const Icon(Icons.home_outlined),
          ),
          if (_canReviewPosts)
            IconButton(
              tooltip: 'Review pending posts',
              onPressed: _openReviewQueue,
              icon: const Icon(Icons.fact_check_outlined),
            ),
          IconButton(
            tooltip: 'Contact moderator',
            onPressed: _openModeratorContact,
            icon: const Icon(Icons.support_agent_outlined),
          ),
          CampusLiveAction(active: false, onPressed: widget.onOpenLiveChat),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Department room · Real names visible',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              const Tab(text: 'Posts'),
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Chat'),
                    if (_unreadCount > 0) ...[
                      const SizedBox(width: 7),
                      _UnreadMessageBadge(count: _unreadCount),
                    ],
                  ],
                ),
              ),
            ],
          ),
          Expanded(
            child: _chatSelected
                ? RoomChatPage(
                    key: ValueKey(
                      'official-room-chat-${widget.department.code}',
                    ),
                    roomId: 'dept-${widget.department.code}',
                    roomName: widget.department.name,
                    embedded: true,
                    roomConversation: true,
                    roomMode: 'official',
                    onRead: () {
                      if (mounted && _unreadCount != 0) {
                        setState(() => _unreadCount = 0);
                      }
                    },
                  )
                : _buildPostTab(),
          ),
        ],
      ),
      floatingActionButton: _chatSelected
          ? null
          : FloatingActionButton.extended(
              onPressed: _createPost,
              icon: const Icon(Icons.add),
              label: const Text('Post to department'),
            ),
    );
  }

  Widget _buildPostTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            TextButton(onPressed: _loadPosts, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_posts.isEmpty) {
      return const Center(child: Text('No posts in this department yet.'));
    }
    return RefreshIndicator(
      onRefresh: _loadPosts,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        itemCount: _posts.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) => _OfficialPostCard(
          post: _posts[index],
          onTap: null,
          onLike: () => _togglePostLike(_posts[index]),
          onComments: () => _openPostComments(_posts[index]),
          liking: _likingPostIds.contains(_posts[index].id),
          canAdminDelete: widget.canAdminDelete,
          onAdminDelete: () async {
            await widget.onAdminDelete(_posts[index]);
            if (mounted) await _loadPosts();
          },
        ),
      ),
    );
  }
}

class _CampusPost {
  const _CampusPost({
    required this.id,
    required this.content,
    required this.createdAt,
    required this.authorUsername,
    this.avatarSeed,
    required this.likeCount,
    required this.likedByMe,
    required this.imagePath,
    this.imageUrl,
    required this.replyCount,
    required this.isMine,
  });

  final String id;
  final String content;
  final DateTime createdAt;
  final String authorUsername;
  final String? avatarSeed;
  final int likeCount;
  final bool likedByMe;
  final String? imagePath;
  final String? imageUrl;
  final int replyCount;
  final bool isMine;

  _CampusPost copyWith({
    int? likeCount,
    bool? likedByMe,
    int? replyCount,
    String? imageUrl,
  }) {
    return _CampusPost(
      id: id,
      content: content,
      createdAt: createdAt,
      authorUsername: authorUsername,
      avatarSeed: avatarSeed,
      likeCount: likeCount ?? this.likeCount,
      likedByMe: likedByMe ?? this.likedByMe,
      imagePath: imagePath,
      imageUrl: imageUrl ?? this.imageUrl,
      replyCount: replyCount ?? this.replyCount,
      isMine: isMine,
    );
  }
}

class _PostDraft {
  const _PostDraft({
    required this.title,
    required this.tags,
    required this.body,
    required this.image,
    required this.imageBytes,
  });

  final String title;
  final List<String> tags;
  final String body;
  final XFile? image;
  final Uint8List? imageBytes;

  String get encodedContent =>
      PostContent(title: title, tags: tags, body: body).encode();
}

class _PostRepliesSheet extends StatefulWidget {
  const _PostRepliesSheet({required this.postId, this.officialMode = false});

  final String postId;
  final bool officialMode;

  @override
  State<_PostRepliesSheet> createState() => _PostRepliesSheetState();
}

class _PostRepliesSheetState extends State<_PostRepliesSheet> {
  final _supabase = Supabase.instance.client;
  final _controller = TextEditingController();
  LiveSubscription? _liveSubscription;
  final _liveRefresh = Debouncer();
  List<Map<String, dynamic>> _replies = [];
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadReplies();
    _liveSubscription = LiveSignals.instance.listen(
      widget.officialMode ? 'feed:official' : 'feed:unofficial',
      (signal) {
        final kind = signal['kind'];
        final forThisPost = signal['post_id']?.toString() == widget.postId;
        if (kind == 'resync' || (kind == 'reply' && forThisPost)) {
          _liveRefresh.run(() {
            if (mounted) _loadReplies(showLoading: false);
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _liveSubscription?.cancel();
    _liveRefresh.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadReplies({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final rows = await _supabase.rpc(
        widget.officialMode
            ? 'get_official_post_replies'
            : 'get_post_replies_with_avatars',
        params: {'p_post_id': widget.postId},
      );
      if (!mounted) return;
      setState(() {
        _replies = List<Map<String, dynamic>>.from(rows);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load comments: ${friendlyError(error)}';
      });
    }
  }

  Future<void> _sendReply() async {
    final content = _controller.text.trim();
    if (content.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _supabase.rpc(
        'submit_post_reply',
        params: {
          'p_post_id': widget.postId,
          'p_content': content,
          'p_mode': widget.officialMode ? 'official' : 'unofficial',
        },
      );
      _controller.clear();
      await _loadReplies();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not send comment: ${friendlyError(error)}'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FractionallySizedBox(
      heightFactor: 0.78,
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text('Replies', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          TextButton(
                            onPressed: _loadReplies,
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
                    )
                  : _replies.isEmpty
                  ? const Center(
                      child: Text('No replies yet. Start the conversation.'),
                    )
                  : ListView.separated(
                      itemCount: _replies.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final reply = _replies[index];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          tileColor: colors.surfaceContainerLow,
                          leading: widget.officialMode
                              ? const CircleAvatar(
                                  child: Icon(Icons.account_circle_outlined),
                                )
                              : StudentAvatar(
                                  seed: reply['avatar_seed'] as String?,
                                  size: 34,
                                ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          title: Text(
                            (reply[widget.officialMode
                                        ? 'author_name'
                                        : 'author_username']
                                    as String?) ??
                                (widget.officialMode
                                    ? 'MITS member'
                                    : 'Anonymous'),
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(reply['content'] as String),
                          ),
                          trailing: Text(
                            _replyTime(
                              DateTime.parse(reply['created_at'] as String),
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                      hintText: 'Write a reply…',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                    onSubmitted: (_) => _sendReply(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send reply',
                  onPressed: _sending ? null : _sendReply,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context, _replies.length),
                child: Text('Done (${_replies.length})'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _replyTime(DateTime time) {
    final local = time.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _CampusRoom {
  const _CampusRoom({required this.id, required this.name});

  final String id;
  final String name;
}

class _UnreadMessageBadge extends StatelessWidget {
  const _UnreadMessageBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 19, minHeight: 19),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: colors.onPrimary, fontWeight: FontWeight.w800),
      ),
    );
  }
}

/// Wraps a post card. Posts have no hover highlight on purpose: a tint that
/// fades in and out as the pointer moves over the feed looked like flickering.
class _HoverablePostSurface extends StatelessWidget {
  const _HoverablePostSurface({required this.colors, required this.child});

  final ColorScheme colors;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
