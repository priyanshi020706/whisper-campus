import 'package:flutter/material.dart';

import '../../core/widgets/campus_live_action.dart';
import '../../models/campus_department.dart';

class DepartmentRoomsPage extends StatelessWidget {
  const DepartmentRoomsPage({
    super.key,
    this.onNavigateHome,
    this.onOpenLiveChat,
  });

  final VoidCallback? onNavigateHome;
  final VoidCallback? onOpenLiveChat;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Department rooms'),
        actions: [
          IconButton(
            tooltip: 'Back to home',
            onPressed: onNavigateHome,
            icon: const Icon(Icons.home_outlined),
          ),
          CampusLiveAction(
            active: false,
            onPressed: () => onOpenLiveChat?.call(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Text(
            'Find your branch community',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          Text(
            'Join the conversation anonymously with students in your department.',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          for (final department in campusDepartments) ...[
            Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                minVerticalPadding: 10,
                leading: CircleAvatar(
                  backgroundColor: colors.primaryContainer,
                  foregroundColor: colors.onPrimaryContainer,
                  child: const Icon(Icons.school_outlined),
                ),
                title: Text(
                  department.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(department.code.toUpperCase()),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).pop(department.roomId),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
