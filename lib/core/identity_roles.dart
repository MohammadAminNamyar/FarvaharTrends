import 'dart:async';
import 'dart:convert';

import 'identity.dart';

/// Keys have separate jobs. Publishing retains the historical key so that
/// previously created channels remain owned and their signatures stay valid.
/// Connections use an independently generated key and advertise only that key.
class IdentityRoles {
  IdentityRoles({required this.publisher, required this.connection}) {
    if (publisher.id == connection.id) {
      throw StateError(
        'Publisher and connection identities must be different.',
      );
    }
  }

  final Identity publisher;
  final Identity connection;
}

/// A native process-wide lease serializes Android UI/service engine creation.
/// Storage is re-read inside that lease before creating any missing identity.
class IdentityBootstrap {
  IdentityBootstrap({
    required this.read,
    required this.write,
    required this.generate,
    this.acquire,
    this.release,
    this.validate,
    this.role = 'signing',
  }) : assert((acquire == null) == (release == null));

  final Future<String?> Function() read;
  final Future<void> Function(String) write;
  final Future<Map<String, dynamic>> Function() generate;
  final Future<String> Function()? acquire;
  final Future<void> Function(String)? release;
  final void Function(Identity)? validate;
  final String role;
  Future<Identity>? _inFlight;

  Future<Identity> load() {
    if (_inFlight != null) return _inFlight!;
    final result = _load();
    _inFlight = result;
    unawaited(
      result.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_inFlight, result)) _inFlight = null;
        },
      ),
    );
    return result;
  }

  Future<Identity> _load() async {
    final token = await acquire?.call();
    try {
      final saved = await read();
      if (saved != null) {
        Identity identity;
        try {
          if (saved.length > 32768) throw const FormatException();
          final decoded = jsonDecode(saved);
          if (decoded is! Map<String, dynamic>) throw const FormatException();
          identity = Identity.fromJson(decoded);
        } catch (_) {
          // Parser failures may contain private input. Keep the error generic.
          throw FormatException(
            'Saved $role identity could not be read. No replacement key was created.',
          );
        }
        validate?.call(identity);
        return identity;
      }
      final json = await generate();
      final identity = Identity.fromJson(json);
      validate?.call(identity);
      await write(jsonEncode(json));
      return identity;
    } finally {
      if (token != null) await release!(token);
    }
  }
}

/// Single-flight migration shared by foreground and background startup code.
/// Each role is loaded under the same native lease. A partial first run is safe:
/// a later engine preserves the committed publisher and finishes its connection.
class IdentityRolesBootstrap {
  IdentityRolesBootstrap({
    required Future<String?> Function(String) read,
    required Future<void> Function(String, String) write,
    required Future<Map<String, dynamic>> Function() generate,
    Future<String> Function()? acquire,
    Future<void> Function(String)? release,
  }) : _read = read,
       _write = write,
       _generate = generate,
       _acquire = acquire,
       _release = release,
       _publisher = IdentityBootstrap(
         read: () async {
           final publisher = await read(publisherStorageKey);
           if (publisher == null && await read(connectionStorageKey) != null) {
             throw StateError(
               'Saved publisher identity is missing while a connection identity exists. No replacement key was created.',
             );
           }
           return publisher;
         },
         write: (value) => write(publisherStorageKey, value),
         generate: generate,
         acquire: acquire,
         release: release,
         role: 'publisher',
       );

  // Never rename the historical key: it owns existing signed channels.
  static const publisherStorageKey = 'farvahartrends.pilot.identity.v1';
  static const connectionStorageKey = 'farvahartrends.connection.identity.v1';
  final Future<String?> Function(String) _read;
  final Future<void> Function(String, String) _write;
  final Future<Map<String, dynamic>> Function() _generate;
  final Future<String> Function()? _acquire;
  final Future<void> Function(String)? _release;
  final IdentityBootstrap _publisher;
  Future<IdentityRoles>? _inFlight;

  Future<IdentityRoles> load() {
    if (_inFlight != null) return _inFlight!;
    final result = _load();
    _inFlight = result;
    unawaited(
      result.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_inFlight, result)) _inFlight = null;
        },
      ),
    );
    return result;
  }

  Future<IdentityRoles> _load() async {
    final publisher = await _publisher.load();
    final connection = await IdentityBootstrap(
      read: () => _read(connectionStorageKey),
      write: (value) => _write(connectionStorageKey, value),
      generate: _generate,
      acquire: _acquire,
      release: _release,
      role: 'connection',
      validate: (identity) {
        if (identity.id == publisher.id) {
          throw StateError(
            'Saved connection identity duplicates the publisher identity. Receiving was not started and no key was replaced.',
          );
        }
      },
    ).load();
    return IdentityRoles(publisher: publisher, connection: connection);
  }
}
