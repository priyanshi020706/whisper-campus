import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Broadcast callbacks deliver `{event, payload, type}`; the message itself is
/// the nested `payload`. Older shapes without nesting are still accepted.
Map<String, dynamic> unwrapBroadcast(Map<String, dynamic> raw) {
  final inner = raw['payload'];
  if (inner is Map) return Map<String, dynamic>.from(inner);
  return raw;
}

/// A subscribed channel that can be closed. Wraps the Supabase channel so the
/// listener logic can be tested without a network.
abstract class LiveChannelHandle {
  Future<void> close();
}

typedef LiveChannelOpener =
    LiveChannelHandle Function(
      String topic,
      void Function(Map<String, dynamic> broadcast) onBroadcast,
      void Function(bool connected) onStatus,
    );

LiveChannelHandle _openSupabaseChannel(
  String topic,
  void Function(Map<String, dynamic> broadcast) onBroadcast,
  void Function(bool connected) onStatus,
) {
  final client = Supabase.instance.client;
  final channel = client
      .channel(topic, opts: const RealtimeChannelConfig(private: true))
      .onBroadcast(event: 'activity', callback: onBroadcast)
      .subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          onStatus(true);
        } else if (status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          debugPrint('LIVE SIGNALS $topic: $status $error');
          onStatus(false);
        } else if (status == RealtimeSubscribeStatus.closed) {
          onStatus(false);
        }
      });
  return _SupabaseChannelHandle(client, channel);
}

class _SupabaseChannelHandle implements LiveChannelHandle {
  _SupabaseChannelHandle(this._client, this._channel);

  final SupabaseClient _client;
  final RealtimeChannel _channel;

  @override
  Future<void> close() async {
    await _client.removeChannel(_channel);
  }
}

/// Receives small "something changed" signals from the database over private
/// Realtime channels (see `20261117050000_live_activity_signals.sql`).
///
/// A signal never carries content. Screens react by re-running their normal
/// loader, so access rules stay exactly the same as a manual refresh.
///
/// Topics:
/// - `feed:unofficial` and `feed:official`: post, like and reply activity.
///   Signal fields: `kind` (post, like, reply), `op`, `post_id`, `room_id`.
/// - `user:<user id>`: `kind` is `notification`.
///
/// After a dropped connection comes back, listeners receive one extra signal
/// with `kind: 'resync'` so they can fetch anything they missed.
///
/// Several screens can listen to the same topic. A topic uses one channel, which
/// is closed when the last listener cancels (two channels on one topic would
/// replace each other on the server).
class LiveSignals {
  LiveSignals._(this._opener);

  static final LiveSignals instance = LiveSignals._(_openSupabaseChannel);

  @visibleForTesting
  factory LiveSignals.forTesting(LiveChannelOpener opener) =>
      LiveSignals._(opener);

  final LiveChannelOpener _opener;
  final Map<String, _TopicState> _topics = {};

  /// Number of topics that currently have an open channel.
  @visibleForTesting
  int get openTopicCount => _topics.length;

  /// Starts listening. Call [LiveSubscription.cancel] in `dispose`.
  LiveSubscription listen(
    String topic,
    void Function(Map<String, dynamic> signal) onSignal,
  ) {
    final state = _topics.putIfAbsent(topic, () {
      final created = _TopicState();
      created.handle = _opener(
        topic,
        (raw) => created.dispatch(unwrapBroadcast(raw)),
        (connected) {
          if (!connected) return;
          if (created.connectedBefore) {
            created.dispatch({'kind': 'resync'});
          }
          created.connectedBefore = true;
        },
      );
      return created;
    });
    state.listeners.add(onSignal);
    return LiveSubscription._(() => _remove(topic, onSignal));
  }

  void _remove(String topic, void Function(Map<String, dynamic>) onSignal) {
    final state = _topics[topic];
    if (state == null) return;
    state.listeners.remove(onSignal);
    if (state.listeners.isEmpty) {
      _topics.remove(topic);
      final handle = state.handle;
      if (handle != null) unawaited(handle.close());
    }
  }
}

class _TopicState {
  LiveChannelHandle? handle;
  bool connectedBefore = false;
  final List<void Function(Map<String, dynamic>)> listeners = [];

  void dispatch(Map<String, dynamic> signal) {
    for (final listener in List.of(listeners)) {
      try {
        listener(signal);
      } catch (error) {
        debugPrint('LIVE SIGNAL LISTENER ERROR: $error');
      }
    }
  }
}

class LiveSubscription {
  LiveSubscription._(this._cancel);

  final VoidCallback _cancel;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancel();
  }
}

/// Runs the latest requested action once things go quiet, so a burst of
/// signals (for example many likes at once) causes a single refresh.
class Debouncer {
  Debouncer([this.delay = const Duration(milliseconds: 400)]);

  final Duration delay;
  Timer? _timer;

  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void dispose() => _timer?.cancel();
}
