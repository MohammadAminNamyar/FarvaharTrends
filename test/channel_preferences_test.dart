import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channel_preferences.dart';

void main() {
  late Directory scratch;
  String id(int value) => value.toRadixString(16).padLeft(64, '0');
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('channel-preferences-');
  });
  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  test(
    'preferences start empty and persist only explicit local choices',
    () async {
      final value = ChannelPreferences(scratch);
      await value.load();
      expect(value.followed, isEmpty);
      expect(value.blocked, isEmpty);
      expect(value.trusted, isEmpty);
      await value.follow(id(1));
      await value.block(id(2));
      final reopened = ChannelPreferences(scratch);
      await reopened.load();
      expect(reopened.followed, {id(1)});
      expect(reopened.blocked, {id(2)});
      expect(() => reopened.followed.add(id(3)), throwsUnsupportedError);
      final files = await scratch.list().toList();
      expect(files.map((file) => file.uri.pathSegments.last), [
        'channel-preferences.json',
      ]);
      final json = jsonDecode(
        await File('${scratch.path}/channel-preferences.json').readAsString(),
      ) as Map;
      expect(json.keys.toSet(), {'version', 'followed', 'blocked', 'trusted'});
      expect(json['version'], 2);
    },
  );

  test(
    'hide removes following, unblock stays unfollowed, explicit follow resumes',
    () async {
      final value = ChannelPreferences(scratch);
      await value.follow(id(1));
      await value.block(id(1));
      expect(value.isFollowed(id(1)), false);
      expect(value.isBlocked(id(1)), true);
      await value.unblock(id(1));
      expect(value.isFollowed(id(1)), false);
      await value.block(id(1));
      await value.follow(id(1));
      expect(value.isFollowed(id(1)), true);
      expect(value.isBlocked(id(1)), false);
      await value.unfollow(id(1));
      expect(value.isFollowed(id(1)), false);
    },
  );

  test('concurrent mutations serialize without lost choices', () async {
    final value = ChannelPreferences(scratch);
    await Future.wait([
      value.follow(id(1)),
      value.follow(id(2)),
      value.block(id(3)),
      value.trust(id(4)),
    ]);
    final reopened = ChannelPreferences(scratch);
    await reopened.load();
    expect(reopened.followed, {id(1), id(2)});
    expect(reopened.blocked, {id(3)});
    expect(reopened.trusted, {id(4)});
  });

  test(
    'invalid identifiers and oversized sets do not commit partial state',
    () async {
      final value = ChannelPreferences(scratch);
      for (final invalid in ['', 'abc', 'g' * 64, 'A' * 64, '0' * 65]) {
        await expectLater(value.follow(invalid), throwsArgumentError);
      }
      for (var i = 0; i < ChannelPreferences.maxEntries; i++) {
        await value.follow(id(i));
      }
      await expectLater(value.follow(id(129)), throwsStateError);
      expect(value.followed.length, ChannelPreferences.maxEntries);
      final reopened = ChannelPreferences(scratch);
      await reopened.load();
      expect(reopened.followed, value.followed);
    },
  );

  test(
    'failed replacement leaves in-memory and committed choices intact',
    () async {
      final value = ChannelPreferences(scratch);
      await value.follow(id(1));
      await value.trust(id(1));
      final obstruction = Directory(
        '${scratch.path}/channel-preferences.json.next',
      );
      await obstruction.create();
      await expectLater(
        value.follow(id(2)),
        throwsA(isA<FileSystemException>()),
      );
      expect(value.followed, {id(1)});
      await expectLater(
        value.trust(id(2)),
        throwsA(isA<FileSystemException>()),
      );
      expect(value.trusted, {id(1)});
      final reopened = ChannelPreferences(scratch);
      await reopened.load();
      expect(reopened.followed, {id(1)});
      expect(reopened.trusted, {id(1)});
      await obstruction.delete();
      await value.follow(id(2));
      expect(value.followed, {id(1), id(2)});
    },
  );

  test(
    'interrupted replacement recovers the previous complete backup',
    () async {
      final value = ChannelPreferences(scratch);
      await value.block(id(7));
      final file = File('${scratch.path}/channel-preferences.json');
      await file.rename('${file.path}.bak');
      await File('${file.path}.next').writeAsString('{partial', flush: true);
      final reopened = ChannelPreferences(scratch);
      await reopened.load();
      expect(reopened.blocked, {id(7)});
      expect(await file.exists(), true);
    },
  );

  test(
    'malformed local data does not silently follow received channels',
    () async {
      final invalidBytes = utf8.encode(
        jsonEncode({
          'version': 1,
          'followed': ['bad'],
          'blocked': [],
        }),
      );
      await File('${scratch.path}/channel-preferences.json')
          .writeAsBytes(invalidBytes);
      final value = ChannelPreferences(scratch);
      await value.load();
      expect(value.followed, isEmpty);
      expect(value.blocked, isEmpty);
      expect(value.trusted, isEmpty);
      expect(value.recoveryWarning, isNotNull);
      final quarantined = await scratch
          .list()
          .where((file) => file.path.contains('.corrupt.'))
          .toList();
      expect(quarantined, hasLength(1));
      expect(await File(quarantined.single.path).readAsBytes(), invalidBytes);
      await value.follow(id(4));
      final reopened = ChannelPreferences(scratch);
      await reopened.load();
      expect(reopened.followed, {id(4)});
      expect(reopened.blocked, isEmpty);
      expect(reopened.trusted, isEmpty);
      expect(reopened.recoveryWarning, isNull);
    },
  );

  test('invalid UTF8 and oversized files are preserved without blocking empty startup', () async {
    final file = File('${scratch.path}/channel-preferences.json');
    for (final bytes in [
      [0xff, 0xfe, 0x00, 0x80],
      List<int>.filled(ChannelPreferences.maxFileBytes + 1, 0x20),
    ]) {
      await file.writeAsBytes(bytes, flush: true);
      final value = ChannelPreferences(scratch);
      await value.load();
      expect(value.followed, isEmpty);
      expect(value.blocked, isEmpty);
      expect(value.trusted, isEmpty);
      expect(value.recoveryWarning, isNotNull);
      final preserved = await scratch
          .list()
          .where((entry) => entry.path.contains('.corrupt.'))
          .asyncMap((entry) => File(entry.path).readAsBytes())
          .toList();
      expect(
        preserved.any(
          (saved) =>
              saved.length == bytes.length &&
              bytes.asMap().entries.every(
                (entry) => saved[entry.key] == entry.value,
              ),
        ),
        true,
      );
    }
    expect(
      await scratch
          .list()
          .where((entry) => entry.path.contains('.corrupt.'))
          .length,
      2,
    );
  });

  test('local trust is independent of following and untrust is not a negative vote', () async {
    final value = ChannelPreferences(scratch);
    await value.trust(id(1));
    expect(value.isTrusted(id(1)), true);
    expect(value.isFollowed(id(1)), false);
    expect(() => value.trusted.add(id(2)), throwsUnsupportedError);
    await value.follow(id(1));
    await value.untrust(id(1));
    expect(value.isTrusted(id(1)), false);
    expect(value.isFollowed(id(1)), true);
    expect(value.isBlocked(id(1)), false);
    await value.trust(id(1));
    await value.block(id(1));
    expect(value.followed, isEmpty);
    expect(value.trusted, isEmpty);
    await expectLater(value.trust(id(1)), throwsStateError);
    expect(value.blocked, {id(1)});
    await value.unblock(id(1));
    expect(value.followed, isEmpty);
    expect(value.trusted, isEmpty);
    final reopened = ChannelPreferences(scratch);
    await reopened.load();
    expect(reopened.followed, isEmpty);
    expect(reopened.trusted, isEmpty);
    expect(reopened.blocked, isEmpty);
  });

  test(
    'v1 choices migrate without granting trust or following more channels',
    () async {
      final file = File('${scratch.path}/channel-preferences.json');
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'followed': [id(1)],
          'blocked': [id(2)],
        }),
        flush: true,
      );
      final value = ChannelPreferences(scratch);
      await value.load();
      expect(value.followed, {id(1)});
      expect(value.blocked, {id(2)});
      expect(value.trusted, isEmpty);
      expect(value.recoveryWarning, isNull);
      await value.trust(id(3));
      final saved = jsonDecode(await file.readAsString()) as Map;
      expect(saved['version'], 2);
      final reopened = ChannelPreferences(scratch);
      await reopened.load();
      expect(reopened.followed, {id(1)});
      expect(reopened.blocked, {id(2)});
      expect(reopened.trusted, {id(3)});
    },
  );

  test(
    'trust validates identifiers and bounds mutations without partial commits',
    () async {
      final file = File('${scratch.path}/channel-preferences.json');
      await file.writeAsString(
        jsonEncode({
          'version': 2,
          'followed': <String>[],
          'blocked': <String>[],
          'trusted': [
            for (var i = 0; i < ChannelPreferences.maxEntries; i++) id(i),
          ],
        }),
        flush: true,
      );
      final value = ChannelPreferences(scratch);
      await value.load();
      for (final invalid in ['', 'g' * 64, 'A' * 64, '0' * 65]) {
        await expectLater(value.trust(invalid), throwsArgumentError);
        await expectLater(value.untrust(invalid), throwsArgumentError);
      }
      await expectLater(value.trust(id(128)), throwsStateError);
      expect(value.trusted.length, ChannelPreferences.maxEntries);
      await value.untrust(id(0));
      await value.trust(id(128));
      final reopened = ChannelPreferences(scratch);
      await reopened.load();
      expect(reopened.trusted, value.trusted);
      expect(reopened.trusted.contains(id(0)), false);
      expect(reopened.trusted.contains(id(128)), true);
    },
  );

  test(
    'invalid v2 trust data is quarantined without keeping partial choices',
    () async {
      final file = File('${scratch.path}/channel-preferences.json');
      final bytes = utf8.encode(
        jsonEncode({
          'version': 2,
          'followed': [id(1)],
          'blocked': [id(2)],
          'trusted': ['invalid'],
        }),
      );
      await file.writeAsBytes(bytes, flush: true);
      final value = ChannelPreferences(scratch);
      await value.load();
      expect(value.followed, isEmpty);
      expect(value.blocked, isEmpty);
      expect(value.trusted, isEmpty);
      expect(value.recoveryWarning, isNotNull);
      final quarantine = await scratch
          .list()
          .where((entry) => entry.path.contains('.corrupt.'))
          .single;
      expect(await File(quarantine.path).readAsBytes(), bytes);
    },
  );
}
