import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/core/theme/app_theme.dart';
import 'package:whisper_campus/models/room_activity.dart';
import 'package:whisper_campus/pages/rooms/department_rooms_page.dart';
import 'package:whisper_campus/services/room_activity_controller.dart';
import 'package:whisper_campus/services/room_activity_service.dart';

class _FakeSource implements RoomActivitySource {
  _FakeSource(this.data);

  Map<String, RoomActivity> data;

  @override
  Future<Map<String, RoomActivity>> fetch(String mode) async => data;

  @override
  Future<void> setPinned(String roomId, String mode, bool pinned) async {
    final base = data[roomId] ?? RoomActivity(roomId: roomId);
    data = {...data, roomId: base.copyWith(pinned: pinned, pinnedAt: DateTime.now())};
  }

  @override
  Future<void> setMuted(String roomId, String mode, bool muted, {int? minutes}) async {
    final base = data[roomId] ?? RoomActivity(roomId: roomId);
    data = {
      ...data,
      roomId: base.copyWith(
        muted: muted,
        mutedUntil: minutes == null ? null : DateTime.now().add(Duration(minutes: minutes)),
      ),
    };
  }
}

final _sources = Expando<_FakeSource>();

_FakeSource _sourceOf(RoomActivityController controller) =>
    _sources[controller]!;

void main() {
  final now = DateTime.now();

  Future<RoomActivityController> pumpPage(
    WidgetTester tester,
    Map<String, RoomActivity> data,
  ) async {
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _FakeSource(data);
    final controller = RoomActivityController(
      source: source,
      refreshEvery: const Duration(hours: 1),
    );
    _sources[controller] = source;
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: DepartmentRoomsPage(activity: controller),
      ),
    );
    await tester.pump();
    return controller;
  }

  // Titles of the department tiles, top to bottom.
  List<String> tileOrder(WidgetTester tester) {
    final titles = <(double, String)>[];
    for (final element in find.byType(ListTile).evaluate()) {
      final tile = element.widget as ListTile;
      final title = (tile.title as Text).data!;
      titles.add((tester.getTopLeft(find.byWidget(tile)).dy, title));
    }
    titles.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final t in titles) t.$2];
  }

  testWidgets('without any chat activity the usual order is kept', (
    tester,
  ) async {
    await pumpPage(tester, {});

    final order = tileOrder(tester);
    expect(order.first, 'AI & Data Science');
    expect(find.text('All departments'), findsOneWidget);
    expect(find.text('Pinned'), findsNothing);
    expect(find.text('Recent chats'), findsNothing);
  });

  testWidgets('pinned first, then newest chat, then the rest', (tester) async {
    await pumpPage(tester, {
      'dept-ar': RoomActivity(
        roomId: 'dept-ar',
        pinned: true,
        pinnedAt: now.subtract(const Duration(days: 1)),
      ),
      'dept-it': RoomActivity(
        roomId: 'dept-it',
        lastMessageAt: now.subtract(const Duration(hours: 5)),
      ),
      'dept-me': RoomActivity(
        roomId: 'dept-me',
        lastMessageAt: now.subtract(const Duration(minutes: 2)),
        lastMessageMine: true,
        unreadCount: 3,
      ),
    });

    final order = tileOrder(tester);
    expect(order.take(3), [
      'Architecture (B.Arch)', // pinned
      'Mechanical Engineering', // newest message
      'Information Technology', // older message
    ]);
    expect(order[3], 'AI & Data Science'); // everything else, usual order
    expect(find.text('Pinned'), findsOneWidget);
    expect(find.text('Recent chats'), findsOneWidget);
    expect(find.text('Other departments'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // unread badge
    expect(find.textContaining('You · 2m ago'), findsOneWidget);
  });

  testWidgets('pinning a room moves it to the top at once', (tester) async {
    await pumpPage(tester, {});

    final pinOnLast = find.byTooltip('Pin room').last;
    await tester.tap(pinOnLast);
    await tester.pump();
    await tester.pump();

    expect(tileOrder(tester).first, 'Architecture (B.Arch)');
    expect(find.byTooltip('Unpin room'), findsOneWidget);
  });

  testWidgets('a fourth pin shows the limit message', (tester) async {
    await pumpPage(tester, {
      for (final id in ['dept-ar', 'dept-ce', 'dept-cs'])
        id: RoomActivity(roomId: id, pinned: true, pinnedAt: now),
    });

    await tester.tap(find.byTooltip('Pin room').first);
    await tester.pump();

    expect(find.text('You can pin up to 3 rooms. Unpin one first.'), findsOneWidget);
    expect(find.byTooltip('Unpin room'), findsNWidgets(3));
  });

  testWidgets('a new message reorders the list after a refresh', (tester) async {
    final controller = await pumpPage(tester, {
      'dept-it': RoomActivity(
        roomId: 'dept-it',
        lastMessageAt: now.subtract(const Duration(minutes: 30)),
      ),
    });
    expect(tileOrder(tester).first, 'Information Technology');

    final source = _sourceOf(controller);
    source.data = {
      ...source.data,
      'dept-ee': RoomActivity(roomId: 'dept-ee', lastMessageAt: now),
    };
    await controller.refresh();
    await tester.pump();

    expect(tileOrder(tester).first, 'Electrical Engineering');
    expect(tileOrder(tester)[1], 'Information Technology');
  });

  testWidgets('tapping a department returns its room id', (tester) async {
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = RoomActivityController(
      source: _FakeSource({}),
      refreshEvery: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) => DepartmentRoomsPage(activity: controller),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextButton));
    // The live-chat icon animates forever, so settle by time, not by idle.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.text('Civil Engineering'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(picked, 'dept-ce');
  });
}


