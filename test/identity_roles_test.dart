import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/identity_roles.dart';

void main() {
  late Identity publisher;
  late Identity connection;
  setUpAll(() {
    publisher = Identity.generate();
    connection = Identity.generate();
  });

  test('Upgrade preserves the exact publisher key and creates a separate connection', () async {
    final savedPublisher = jsonEncode(publisher.toJson());
    final vault = <String, String>{
      IdentityRolesBootstrap.publisherStorageKey: savedPublisher,
    };
    final writes = <String>[];
    var generated = 0;
    IdentityRolesBootstrap bootstrap() => IdentityRolesBootstrap(
      read: (key) async => vault[key],
      write: (key, value) async {
        writes.add(key);
        vault[key] = value;
      },
      generate: () async {
        generated++;
        return connection.toJson();
      },
    );
    final roles = await bootstrap().load();
    expect(roles.publisher.id, publisher.id);
    expect(roles.connection.id, connection.id);
    expect(roles.connection.id, isNot(roles.publisher.id));
    expect(vault[IdentityRolesBootstrap.publisherStorageKey], savedPublisher);
    expect(writes, [IdentityRolesBootstrap.connectionStorageKey]);
    final restarted = await bootstrap().load();
    expect(restarted.publisher.id, roles.publisher.id);
    expect(restarted.connection.id, roles.connection.id);
    expect(generated, 1);
    expect(writes.length, 1);
  });

  test('Independent foreground and service startups converge under the native lease', () async {
    final lease = _Lease();
    final vault = <String, String>{};
    var generated = 0;
    IdentityRolesBootstrap bootstrap() => IdentityRolesBootstrap(
      read: (key) async => vault[key],
      write: (key, value) async {
        vault[key] = value;
      },
      generate: () async {
        generated++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return (generated == 1 ? publisher : connection).toJson();
      },
      acquire: lease.acquire,
      release: lease.release,
    );
    final a = bootstrap();
    final b = bootstrap();
    final pairs = await Future.wait([a.load(), a.load(), b.load()]);
    expect(pairs.map((roles) => roles.publisher.id).toSet(), {publisher.id});
    expect(pairs.map((roles) => roles.connection.id).toSet(), {connection.id});
    expect(generated, 2);
    expect(lease.acquisitions, 4);
    expect(lease.releases, 4);
    expect(vault.keys.toSet(), {
      IdentityRolesBootstrap.publisherStorageKey,
      IdentityRolesBootstrap.connectionStorageKey,
    });
  });

  for (final corruptRole in ['publisher', 'connection']) {
    test(
      'Corrupt $corruptRole fails closed without replacing either stored key',
      () async {
        final vault = <String, String>{
          IdentityRolesBootstrap.publisherStorageKey: jsonEncode(
            publisher.toJson(),
          ),
          IdentityRolesBootstrap.connectionStorageKey: jsonEncode(
            connection.toJson(),
          ),
        };
        final key = corruptRole == 'publisher'
            ? IdentityRolesBootstrap.publisherStorageKey
            : IdentityRolesBootstrap.connectionStorageKey;
        vault[key] = '{"keyPem":"SECRET-MUST-NOT-APPEAR';
        final before = Map<String, String>.from(vault);
        var generated = 0;
        var writes = 0;
        final roles = IdentityRolesBootstrap(
          read: (key) async => vault[key],
          write: (_, _) async {
            writes++;
          },
          generate: () async {
            generated++;
            return connection.toJson();
          },
        );
        await expectLater(
          roles.load(),
          throwsA(
            predicate(
              (error) =>
                  error is FormatException &&
                  error.toString().contains(corruptRole) &&
                  !error.toString().contains('SECRET-MUST-NOT-APPEAR'),
            ),
          ),
        );
        expect(vault, before);
        expect(generated, 0);
        expect(writes, 0);
      },
    );
  }

  test(
    'A duplicated stored connection key is rejected without migration fallback',
    () async {
      var writes = 0;
      var generated = 0;
      final roles = IdentityRolesBootstrap(
        read: (_) async => jsonEncode(publisher.toJson()),
        write: (_, _) async {
          writes++;
        },
        generate: () async {
          generated++;
          return connection.toJson();
        },
      );
      await expectLater(roles.load(), throwsStateError);
      expect(writes, 0);
      expect(generated, 0);
    },
  );

  test(
    'Generated connection cannot accidentally reuse publisher key',
    () async {
      final vault = <String, String>{
        IdentityRolesBootstrap.publisherStorageKey: jsonEncode(
          publisher.toJson(),
        ),
      };
      var writes = 0;
      final roles = IdentityRolesBootstrap(
        read: (key) async => vault[key],
        write: (_, _) async {
          writes++;
        },
        generate: () async => publisher.toJson(),
      );
      await expectLater(roles.load(), throwsStateError);
      expect(writes, 0);
      expect(
        vault.containsKey(IdentityRolesBootstrap.connectionStorageKey),
        isFalse,
      );
    },
  );

  test('A missing publisher with an existing connection never creates a replacement publisher', () async {
    final vault = <String, String>{
      IdentityRolesBootstrap.connectionStorageKey: jsonEncode(
        connection.toJson(),
      ),
    };
    var generated = 0;
    var writes = 0;
    final roles = IdentityRolesBootstrap(
      read: (key) async => vault[key],
      write: (_, _) async {
        writes++;
      },
      generate: () async {
        generated++;
        return publisher.toJson();
      },
    );
    await expectLater(roles.load(), throwsStateError);
    expect(generated, 0);
    expect(writes, 0);
    expect(
      vault.containsKey(IdentityRolesBootstrap.publisherStorageKey),
      isFalse,
    );
  });

  test('A connection commit failure can safely retry without changing publisher ownership', () async {
    final lease = _Lease();
    final savedPublisher = jsonEncode(publisher.toJson());
    final vault = <String, String>{
      IdentityRolesBootstrap.publisherStorageKey: savedPublisher,
    };
    var writes = 0;
    final roles = IdentityRolesBootstrap(
      read: (key) async => vault[key],
      write: (key, value) async {
        if (++writes == 1) throw StateError('Storage unavailable');
        vault[key] = value;
      },
      generate: () async => connection.toJson(),
      acquire: lease.acquire,
      release: lease.release,
    );
    await expectLater(roles.load(), throwsStateError);
    final retried = await roles.load();
    expect(retried.publisher.id, publisher.id);
    expect(retried.connection.id, connection.id);
    expect(vault[IdentityRolesBootstrap.publisherStorageKey], savedPublisher);
    expect(lease.acquisitions, 3);
    expect(lease.releases, 3);
  });
}

class _Lease {
  Future<void> _tail = Future<void>.value();
  final Map<String, Completer<void>> _releases = {};
  int acquisitions = 0;
  int releases = 0;

  Future<String> acquire() async {
    final previous = _tail;
    final gate = Completer<void>();
    final token = '${++acquisitions}';
    _tail = gate.future;
    _releases[token] = gate;
    await previous;
    return token;
  }

  Future<void> release(String token) async {
    releases++;
    _releases.remove(token)!.complete();
  }
}
