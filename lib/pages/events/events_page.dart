import 'package:flutter/material.dart';

import '../../models/campus_department.dart';
import '../../models/campus_updates.dart';
import '../../services/campus_updates_controller.dart';

/// Upcoming campus events with Going / Interested answers.
class EventsPage extends StatefulWidget {
  const EventsPage({
    super.key,
    required this.updates,
    required this.canCreate,
    required this.isStaff,
  });

  final CampusUpdatesController updates;

  /// Faculty, admins and room moderators may add events.
  final bool canCreate;

  /// Faculty and admins may also publish for the whole campus.
  final bool isStaff;

  @override
  State<EventsPage> createState() => _EventsPageState();
}

class _EventsPageState extends State<EventsPage> {
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

  Future<void> _rsvp(CampusEvent event, String status) async {
    final message = await widget.updates.rsvp(event.id, status);
    if (message != null && mounted) _say(message);
  }

  Future<void> _cancel(CampusEvent event) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this event?'),
        content: const Text(
          'People who said they are going will see it as cancelled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Cancel event'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final message = await widget.updates.cancelEvent(event.id);
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
      builder: (_) => CreateEventSheet(
        updates: widget.updates,
        rooms: rooms,
        allowCampusWide: widget.isStaff,
      ),
    );
    if (created == true && mounted) _say('Event created.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Events')),
      floatingActionButton: widget.canCreate
          ? FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('Add event'),
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
          final events = updates.events;
          return RefreshIndicator(
            onRefresh: () async {
              final message = await updates.refresh();
              if (message != null && mounted) _say(message);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show past events'),
                  value: updates.includePast,
                  onChanged: updates.setIncludePast,
                ),
                if (events.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Column(
                      children: [
                        Icon(
                          Icons.event_busy_outlined,
                          size: 48,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          updates.includePast
                              ? 'No events yet'
                              : 'No upcoming events',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.canCreate
                              ? 'Tap "Add event" to create one.'
                              : 'Check back soon.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  )
                else
                  for (final event in events) ...[
                    EventCard(
                      event: event,
                      onRsvp: (status) => _rsvp(event, status),
                      onCancel:
                          event.canManage && !event.cancelled && !event.isOver()
                          ? () => _cancel(event)
                          : null,
                    ),
                    const SizedBox(height: 12),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One event: when and where, who runs it, and the Going / Interested buttons.
class EventCard extends StatefulWidget {
  const EventCard({
    super.key,
    required this.event,
    required this.onRsvp,
    this.onCancel,
  });

  final CampusEvent event;
  final void Function(String status) onRsvp;
  final VoidCallback? onCancel;

  @override
  State<EventCard> createState() => _EventCardState();
}

class _EventCardState extends State<EventCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final event = widget.event;
    final over = event.isOver();
    final closed = over || event.cancelled;
    final countdown = eventCountdown(event);
    final meta = [
      event.organizerLabel,
      if (event.roomId != null) roomDisplayName(event.roomId),
    ].join(' · ');
    final tag = event.cancelled
        ? colors.error
        : event.isHappeningNow()
        ? colors.tertiary
        : colors.primary;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: closed ? 0.75 : 1,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: tag.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      child: Text(
                        countdown,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: tag,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (widget.onCancel != null)
                    PopupMenuButton<String>(
                      tooltip: 'Event options',
                      padding: EdgeInsets.zero,
                      onSelected: (_) => widget.onCancel!(),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'cancel',
                          child: Text('Cancel event'),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                event.title,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  decoration: event.cancelled
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              _InfoLine(
                icon: Icons.schedule_rounded,
                text: formatEventWhen(event.startsAt, event.endsAt),
              ),
              if (event.location.isNotEmpty)
                _InfoLine(icon: Icons.place_outlined, text: event.location),
              if (event.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  event.description,
                  maxLines: _expanded ? null : 3,
                  overflow: _expanded ? null : TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                if (event.description.length > 120)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _expanded = !_expanded),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(_expanded ? 'Show less' : 'Show more'),
                    ),
                  ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilterChip(
                    avatar: Icon(
                      event.myStatus == 'going'
                          ? Icons.check_circle
                          : Icons.check_circle_outline,
                      size: 18,
                    ),
                    label: Text('Going · ${event.goingCount}'),
                    selected: event.myStatus == 'going',
                    onSelected: closed ? null : (_) => widget.onRsvp('going'),
                  ),
                  FilterChip(
                    avatar: Icon(
                      event.myStatus == 'interested'
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      size: 18,
                    ),
                    label: Text('Interested · ${event.interestedCount}'),
                    selected: event.myStatus == 'interested',
                    onSelected: closed
                        ? null
                        : (_) => widget.onRsvp('interested'),
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

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// Where an event or announcement is published: the whole campus, or one room.
class ScopeDropdown extends StatelessWidget {
  const ScopeDropdown({
    super.key,
    required this.value,
    required this.rooms,
    required this.allowCampusWide,
    required this.onChanged,
  });

  /// Null means campus-wide.
  final String? value;
  final List<PublishRoom> rooms;
  final bool allowCampusWide;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Show in',
        border: OutlineInputBorder(),
      ),
      items: [
        if (allowCampusWide)
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('Whole campus'),
          ),
        for (final room in rooms)
          DropdownMenuItem<String?>(
            value: room.id,
            child: Text(
              room.name.isEmpty ? roomDisplayName(room.id) : room.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// Form for a new event. Pops `true` once it is created.
class CreateEventSheet extends StatefulWidget {
  const CreateEventSheet({
    super.key,
    required this.updates,
    required this.rooms,
    required this.allowCampusWide,
  });

  final CampusUpdatesController updates;
  final List<PublishRoom> rooms;
  final bool allowCampusWide;

  @override
  State<CreateEventSheet> createState() => _CreateEventSheetState();
}

class _CreateEventSheetState extends State<CreateEventSheet> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _location = TextEditingController();
  DateTime? _start;
  DateTime? _end;
  late String? _room = widget.allowCampusWide
      ? null
      : (widget.rooms.isEmpty ? null : widget.rooms.first.id);
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _location.dispose();
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime? current) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: current ?? now.add(const Duration(days: 1)),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        current ?? now.add(const Duration(hours: 2)),
      ),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _submit() async {
    final problem = validateEventDraft(
      title: _title.text,
      description: _description.text,
      location: _location.text,
      startsAt: _start,
      endsAt: _end,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (!widget.allowCampusWide && _room == null) {
      setState(() => _error = 'Choose a room for this event.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final message = await widget.updates.createEvent(
      title: _title.text.trim(),
      description: _description.text.trim(),
      location: _location.text.trim(),
      startsAt: _start!,
      endsAt: _end,
      roomId: _room,
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
              'New event',
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
              controller: _location,
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Place (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _description,
              maxLength: 1000,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Details (optional)',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await _pick(_start);
                    if (picked != null) setState(() => _start = picked);
                  },
                  icon: const Icon(Icons.event_outlined),
                  label: Text(
                    _start == null
                        ? 'Starts'
                        : 'Starts ${formatEventDay(_start!)} ${formatEventTime(_start!)}',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await _pick(_end ?? _start);
                    if (picked != null) setState(() => _end = picked);
                  },
                  icon: const Icon(Icons.schedule_rounded),
                  label: Text(
                    _end == null
                        ? 'Ends (optional)'
                        : 'Ends ${formatEventDay(_end!)} ${formatEventTime(_end!)}',
                  ),
                ),
                if (_end != null)
                  TextButton(
                    onPressed: () => setState(() => _end = null),
                    child: const Text('Remove end'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ScopeDropdown(
              value: _room,
              rooms: widget.rooms,
              allowCampusWide: widget.allowCampusWide,
              onChanged: (value) => setState(() => _room = value),
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
                  : const Icon(Icons.event_available_outlined),
              label: const Text('Create event'),
            ),
          ],
        ),
      ),
    );
  }
}
