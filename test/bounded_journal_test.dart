import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/bounded_journal.dart';

void main() {
  late Directory root;
  setUp(() async {
    await Directory('.tooling/test-tmp').create(recursive: true);
    root = await Directory('.tooling/test-tmp').createTemp('bounded-journal-');
  });
  tearDown(() async => root.delete(recursive: true));
  BoundedJournal journal() => BoundedJournal(
    File('${root.path}/state.jsonl'),
    maxEntries: 3,
    maxStateBytes: 1024,
    maxJournalBytes: 4096,
  );
  test('serial concurrent writes, compaction and reload preserve acknowledged state', () async {
    final store = journal();
    await store.load();
    await Future.wait([
      for (var i = 0; i < 100; i++) store.put('${i % 3}', {'revision': i}),
    ]);
    expect(await store.file.length(), lessThanOrEqualTo(4096));
    final loaded = journal();
    await loaded.load();
    expect(loaded.rows, store.rows);
    await expectLater(loaded.put('fourth', {'n': 4}), throwsStateError);
    await expectLater(loaded.put('0', {'value': 'a' * 1024}), throwsStateError);
    await loaded.remove('0');
    await loaded.put('fourth', {'n': 4});
    final again = journal();
    await again.load();
    expect(again.rows, loaded.rows);
  });
  test(
    'only an uncommitted tail is discarded; committed corruption fails closed',
    () async {
      final store = journal();
      await store.load();
      await store.put('a', {'state': 'acked'});
      await store.file.writeAsString(
        '{incomplete',
        mode: FileMode.append,
        flush: true,
      );
      final loaded = journal();
      await loaded.load();
      expect(loaded.rows['a']!['state'], 'acked');
      await loaded.put('b', {'state': 'sealed'});
      final text = await loaded.file.readAsString();
      await loaded.file.writeAsString(
        text.replaceFirst('acked', 'broken'),
        flush: true,
      );
      await expectLater(journal().load(), throwsA(isA<FormatException>()));
    },
  );
  test(
    'interrupted snapshot rename recovers the previous committed journal',
    () async {
      final store = journal();
      await store.load();
      await store.put('a', {'state': 'sealed'});
      await store.file.rename('${store.file.path}.bak');
      await File('${store.file.path}.next').writeAsString('torn snapshot');
      final loaded = journal();
      await loaded.load();
      expect(loaded.rows['a']!['state'], 'sealed');
    },
  );
  test(
    'failed compaction blocks writes until committed state is reloaded',
    () async {
      final store = BoundedJournal(
        File('${root.path}/blocked.jsonl'),
        maxEntries: 3,
        maxStateBytes: 256,
        maxJournalBytes: 512,
      );
      await store.load();
      await store.put('a', {'revision': 0});
      final obstacle = Directory('${store.file.path}.next');
      await obstacle.create();
      var lastAcknowledged = 0;
      var failed = false;
      for (var revision = 1; revision < 20; revision++) {
        try {
          await store.put('a', {'revision': revision});
          lastAcknowledged = revision;
        } on FileSystemException {
          failed = true;
          break;
        }
      }
      expect(failed, isTrue, reason: 'The workload must attempt compaction.');
      expect(store.rows['a']!['revision'], lastAcknowledged);
      await expectLater(store.put('b', {'revision': 1}), throwsStateError);
      await obstacle.delete();
      await store.load();
      expect(store.rows['a']!['revision'], lastAcknowledged);
      await store.put('b', {'revision': 1});
    },
  );
}
