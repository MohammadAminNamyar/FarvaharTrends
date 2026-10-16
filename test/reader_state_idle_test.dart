import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/reader_state.dart';

void main() {
  late Directory directory;
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    directory = await parent.createTemp('reader-idle-');
  });
  tearDown(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp')
        .absolute
        .path;
    if (!directory.absolute.path.startsWith(
      '$parent${Platform.pathSeparator}',
    )) {
      throw StateError('Test path escaped workspace');
    }
    await directory.delete(recursive: true);
  });

  final channel = 'c' * 64;
  Map<String, dynamic> news(String id) => {
    'id': id * 64,
    'channelId': channel,
    'receivedVia': 'overlay',
  };

  test(
    'idle observations do not rewrite state or repeat arrival alerts',
    () async {
      final reader = ReaderState(directory);
      await reader.observe([news('1')], {channel}, {});
      expect(await reader.observe([news('1'), news('2')], {channel}, {}), [
        news('2'),
      ]);
      final file = File('${directory.path}/reader-state.json');
      final content = await file.readAsString();
      await file.setLastModified(DateTime.utc(2020));
      final stamp = await file.lastModified();
      for (var n = 0; n < 20; n++) {
        expect(
          await reader.observe([news('1'), news('2')], {channel}, {}),
          isEmpty,
        );
      }
      expect(await file.readAsString(), content);
      expect(await file.lastModified(), stamp);
      expect(await File('${file.path}.bak').exists(), false);
      expect(await File('${file.path}.next').exists(), false);
    },
  );

  test(
    'receiver still reloads read and notification changes made by UI',
    () async {
      final receiver = ReaderState(directory), ui = ReaderState(directory);
      await receiver.observe([news('1')], {channel}, {});
      await receiver.observe([news('1'), news('2')], {channel}, {});
      await ui.markRead(['2' * 64]);
      await ui.setNotifications(false);
      expect(
        await receiver.observe(
          [news('1'), news('2'), news('3')],
          {channel},
          {},
        ),
        isEmpty,
      );
      expect(receiver.readIds, contains('2' * 64));
      expect(receiver.notifications, false);
      await ui.setNotifications(true);
      expect(
        await receiver.observe(
          [news('1'), news('2'), news('3'), news('4')],
          {channel},
          {},
        ),
        [news('4')],
      );
      final restarted = ReaderState(directory);
      await restarted.load();
      expect(restarted.readIds, contains('2' * 64));
      expect(restarted.seenIds, contains('4' * 64));
    },
  );

  test(
    'unchanged default preference still creates a durable first file',
    () async {
      final reader = ReaderState(directory);
      await reader.setImages('wifiOnly');
      expect(await File('${directory.path}/reader-state.json').exists(), true);
      final file = File('${directory.path}/reader-state.json');
      await file.rename('${file.path}.bak');
      await reader.setImages('wifiOnly');
      expect(await file.exists(), true);
      expect(await File('${file.path}.bak').exists(), false);
    },
  );
}
