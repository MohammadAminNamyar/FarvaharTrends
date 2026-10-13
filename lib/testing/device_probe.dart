import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// Local instrumentation for a separately installed, disposable test variant.
/// Disabled in distribution builds. No keys, IPs or subscriptions are exported.
class DeviceProbe {
  DeviceProbe(this.deviceState);
  static const enabled = bool.fromEnvironment('PERSIANTREND_E2E');
  final Future<Map<String, dynamic>> Function() deviceState;
  final String session = List.generate(
    12,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final Map<String, Map<String, dynamic>> _messages = {};
  Future<void> _queue = Future.value();
  Directory? _directory;

  void record(Map<String, dynamic> snapshot) {
    if (!enabled || !Platform.isAndroid) return;
    final messages = (snapshot['bulletins'] as List? ?? const [])
        .whereType<Map>()
        .where(
          (news) =>
              news['text'] is String &&
              (news['text'] as String).startsWith('PT-HS-'),
        )
        .map((news) => Map<String, dynamic>.from(news))
        .take(50)
        .toList();
    final summary = <String, dynamic>{
      'session': session,
      'running': snapshot['running'],
      'deliveryMode': snapshot['deliveryMode'],
      'connectedCount': snapshot['connectedCount'],
      'activeTransportCounts': snapshot['activeTransportCounts'],
      'helperContactCount': snapshot['helperContactCount'],
      'helperReconnectCount': snapshot['helperReconnectCount'],
      'advertisingHelper': snapshot['advertisingHelper'],
    };
    _queue = _queue
        .then((_) async {
          final device = await deviceState();
          if (device['packageName'] is! String ||
              !(device['packageName'] as String).endsWith('.e2e'))
            return;
          _directory ??= await getExternalStorageDirectory();
          if (_directory == null) return;
          Map<String, dynamic>? state = device;
          for (final news in messages) {
            final id = news['id'];
            if (id is! String || _messages.containsKey(id)) continue;
            state ??= await deviceState();
            final text = news['text'] as String;
            _messages[id] = {
              'id': id,
              'text': text.length > 128 ? text.substring(0, 128) : text,
              'createdAtMs': news['createdAtMs'],
              'receivedAtWallMs': news['receivedAtWallMs'],
              'receivedVia': news['receivedVia'],
              'receivedNetwork': news['receivedNetwork'],
              'deviceLockedAtObservation': state['isLocked'],
              'screenOnAtObservation': state['screenOn'],
              'observedAtMs': DateTime.now().millisecondsSinceEpoch,
            };
            while (_messages.length > 50) {
              _messages.remove(_messages.keys.first);
            }
          }
          final pending = File(
            '${_directory!.path}/persiantrend-e2e-status.json.next',
          );
          await pending.writeAsString(
            jsonEncode({...summary, 'messages': _messages.values.toList()}),
            flush: true,
          );
          await pending.rename(
            '${_directory!.path}/persiantrend-e2e-status.json',
          );
        })
        .catchError((Object _) {
          /* Instrumentation must not affect receiving. */
        });
  }
}
