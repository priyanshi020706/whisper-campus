import 'package:flutter/material.dart';

import '../../models/campus_department.dart';
import '../../models/campus_updates.dart';
import '../../services/campus_updates_controller.dart';
import 'events_page.dart';

/// Notices from faculty, admins and room moderators.
class AnnouncementsPage extends StatefulWidget {
  const AnnouncementsPage({
    super.key,
    required this.updates,
    required this.canCreate,
    required this.isStaff,
  });

  final CampusUpdatesController updates;
  final bool canCreate;
  final bool isStaff;

  @override
  State<AnnouncementsPage> createState() => _AnnouncementsPageState();
}

class _AnnouncementsPageState extends State<AnnouncementsPage> {
  @override
  void initState() {
    super.initState();
    widget.updates.refresh();
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _delete(Announcement item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this announcement?'),
        content: const Text('It will disappear for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final message = await widget.updates.deleteAnnouncement(item.id);
    if (message != null && mounted) _say(message);
  }

  Future<void> _create() async {
    final rooms = await widget.updates.publishRooms();
    if (!mounted) return;
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => CreateAnnouncementSheet(
        updates: widget.updates,
        rooms: rooms,
        isStaff: widget.isStaff,
      ),
    );
    if (created == true && mounted) _say('Announcement posted.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Announcements')),
      floatingActionButton: widget.canCreate
          ? FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.campaign_outlined),
              label: const Text('Post'),
            )
          : null,
      body: ListenableBuilder(
        listenable: widget.updates,
        builder: (context, _) {
          final updates = widget.updates;
          if (!updates.loaded && updates.error == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!updates.loaded && updates.error != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(updates.error!, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: updates.refresh,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          final items = updates.announcements;
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.campaign_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'No announcements',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              final message = await updates.refresh();
              if (message != null && mounted) _say(message);
            },
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) => AnnouncementCard(
                item: items[index],
                onDelete: items[index].canManage
                    ? () => _delete(items[index])
                    : null,
              ),
            ),
          );
        },
      ),
    );
  }
}

class AnnouncementCard extends StatelessWidget {
  const AnnouncementCard({super.key, required this.item, this.onDelete});

  final Announcement item;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final created = item.createdAt.toLocal();
    final meta = [
      item.organizerLabel,
      if (item.roomId != null) roomDisplayName(item.roomId),
      '${created.day.toString().padLeft(2, '0')}/${created.month.toString().padLeft(2, '0')}/${created.year}',
    ].join(' · ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  item.pinned ? Icons.push_pin : Icons.campaign_outlined,
                  size: 20,
                  color: colors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (onDelete != null)
                  PopupMenuButton<String>(
                    tooltip: 'Announcement options',
                    padding: EdgeInsets.zero,
                    onSelected: (_) => onDelete!(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('Remove')),
                    ],
                  ),
              ],
            ),
            if (item.body.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(item.body, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 8),
            Text(
              meta,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How long an announcement stays up.
enum AnnouncementLength {
  forever('No end', null),
  day('1 day', Duration(days: 1)),
  week('1 week', Duration(days: 7)),
  month('1 month', Duration(days: 30));

  const AnnouncementLength(this.label, this.length);

  final String label;
  final Duration? length;
}

/// Form for a new announcement. Pops `true` once it is posted.
class CreateAnnouncementSheet extends StatefulWidget {
  const CreateAnnouncementSheet({
    super.key,
    required this.updates,
    required this.rooms,
    required this.isStaff,
  });

  final CampusUpdatesController updates;
  final List<PublishRoom> rooms;

  /// Faculty and admins: may post campus-wide and pin.
  final bool isStaff;

  @override
  State<CreateAnnouncementSheet> createState() =>
      _CreateAnnouncementSheetState();
}

class _CreateAnnouncementSheetState extends State<CreateAnnouncementSheet> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  late String? _room = widget.isStaff
      ? null
      : (widget.rooms.isEmpty ? null : widget.rooms.first.id);
  bool _pinned = false;
  AnnouncementLength _length = AnnouncementLength.forever;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final problem = validateAnnouncementDraft(
      title: _title.text,
      body: _body.text,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (!widget.isStaff && _room == null) {
      setState(() => _error = 'Choose a room for this announcement.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final length = _length.length;
    final message = await widget.updates.createAnnouncement(
      title: _title.text.trim(),
      body: _body.text.trim(),
      roomId: _room,
      pinned: widget.isStaff && _pinned,
      expiresAt: length == null ? null : DateTime.now().add(length),
    );
    if (!mounted) return;
    if (message == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'New announcement',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _body,
              maxLength: 2000,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Details (optional)',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            ScopeDropdown(
              value: _room,
              rooms: widget.rooms,
              allowCampusWide: widget.isStaff,
              onChanged: (value) => setState(() => _room = value),
            ),
            if (widget.isStaff)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Pin to the top'),
                value: _pinned,
                onChanged: (v) => setState(() => _pinned = v),
              ),
            const SizedBox(height: 8),
            Text('Stays up for', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final option in AnnouncementLength.values)
                  ChoiceChip(
                    label: Text(option.label),
                    selected: _length == option,
                    onSelected: (_) => setState(() => _length = option),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _saving ? null : _submit,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.campaign_outlined),
              label: const Text('Post announcement'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A slim banner for the home feed showing the newest or pinned announcement.
class AnnouncementBanner extends StatelessWidget {
  const AnnouncementBanner({
    super.key,
    required this.item,
    required this.onTap,
    required this.onDismiss,
  });

  final Announcement item;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.primaryContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        hoverColor: Colors.transparent,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              Icon(
                item.pinned ? Icons.push_pin : Icons.campaign_outlined,
                color: colors.onPrimaryContainer,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                icon: Icon(
                  Icons.close_rounded,
                  size: 20,
                  color: colors.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
