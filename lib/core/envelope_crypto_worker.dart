import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'hpke.dart';

enum EnvelopeCryptoMode { hpke, stub }

/// Bounded, persistent crypto isolate. Both benchmark arms use this same worker,
/// nested layout and IPC path. The stub is deliberately insecure laboratory code.
class EnvelopeCryptoWorker {
  EnvelopeCryptoWorker._(
    this._isolate,
    this._port,
    this._receive,
    this.publicKey,
    this.mode,
  ) {
    _subscription = _receive.listen((dynamic response) {
      final value = response as List;
      final future = _pending.remove(value[0]);
      if (future == null) return;
      if (value[1] == true) {
        future.complete(value[2]);
      } else {
        future.completeError(
          const FormatException('Envelope cryptography failed'),
        );
      }
    });
  }
  static const outerSize = 8192;
  static const innerSize = outerSize - 48 - 32;
  static const payloadCapacity = innerSize - 48 - 4;
  static const chunkBytes = 5600;
  static const maxPending = 16;
  final Isolate _isolate;
  final SendPort _port;
  final ReceivePort _receive;
  late final StreamSubscription<dynamic> _subscription;
  final Uint8List publicKey;
  final EnvelopeCryptoMode mode;
  final Map<int, Completer<dynamic>> _pending = {};
  int _sequence = 0;
  bool _closed = false;

  static Future<EnvelopeCryptoWorker> start(
    Directory directory, {
    required EnvelopeCryptoMode mode,
  }) async {
    final ready = ReceivePort();
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(_worker, [
      directory.path,
      mode.name,
      ready.sendPort,
      receive.sendPort,
    ]);
    try {
      final message =
          await ready.first.timeout(const Duration(seconds: 15)) as List;
      if (message[0] != true) throw StateError('Cannot open envelope key');
      return EnvelopeCryptoWorker._(
        isolate,
        message[1] as SendPort,
        receive,
        message[2] as Uint8List,
        mode,
      );
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      receive.close();
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<dynamic> _request(String op, Map<String, dynamic> args) async {
    if (_closed) throw StateError('Envelope worker closed');
    if (_pending.length >= maxPending) {
      throw StateError('Envelope worker queue full');
    }
    final id = ++_sequence;
    final future = Completer<dynamic>();
    _pending[id] = future;
    _port.send([id, op, args]);
    try {
      return await future.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      // A stalled worker cannot retain an unbounded sequence of expired jobs.
      await close();
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  Future<Uint8List> seal(
    Map<String, dynamic> inner, {
    required String exitId,
    required List<int> exitKey,
    required List<int> guardKey,
  }) async {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(inner)));
    if (payload.length > payloadCapacity ||
        exitKey.length != 32 ||
        guardKey.length != 32 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(exitId)) {
      throw const FormatException('Envelope dimensions invalid');
    }
    return await _request('seal', {
      'payload': payload,
      'exitId': exitId,
      'exitKey': Uint8List.fromList(exitKey),
      'guardKey': Uint8List.fromList(guardKey),
    }) as Uint8List;
  }

  Future<Map<String, dynamic>> openEntry(Uint8List cell) async {
    if (cell.length != outerSize) {
      throw const FormatException('Outer cell size');
    }
    return Map<String, dynamic>.from(
      await _request('entry', {'cell': cell}) as Map,
    );
  }

  Future<Map<String, dynamic>> openExit(Uint8List cell) async {
    if (cell.length != innerSize) {
      throw const FormatException('Inner cell size');
    }
    final bytes = await _request('exit', {'cell': cell}) as Uint8List;
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Cell payload');
    }
    return decoded;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    for (final future in _pending.values) {
      if (!future.isCompleted) {
        future.completeError(StateError('Envelope worker closed'));
      }
    }
    _pending.clear();
    await _subscription.cancel();
    _receive.close();
  }

  static Future<void> _worker(List<dynamic> args) async {
    final ready = args[2] as SendPort, reply = args[3] as SendPort;
    final port = ReceivePort();
    final hpke = args[1] == EnvelopeCryptoMode.hpke.name;
    late Uint8List privateKey;
    try {
      final directory = Directory(args[0] as String);
      await directory.create(recursive: true);
      final file = File('${directory.path}/envelope-x2-key.bin');
      if (await file.exists()) {
        privateKey = await file.readAsBytes();
        if (privateKey.length != 32) throw const FormatException('Key size');
      } else {
        privateKey = Uint8List.fromList(
          List.generate(32, (_) => Random.secure().nextInt(256)),
        );
        await file.writeAsBytes(privateKey, flush: true);
      }
      ready.send([true, port.sendPort, await Hpke.publicKey(privateKey)]);
    } catch (_) {
      ready.send([false]);
      port.close();
      return;
    }
    final entryInfo = utf8.encode('farvahartrends/envelope-x2/entry');
    final exitInfo = utf8.encode('farvahartrends/envelope-x2/exit');
    Future<Uint8List> seal(List<int> key, Uint8List bytes, List<int> info) =>
        hpke
        ? Hpke.seal(recipient: key, plaintext: bytes, info: info, aad: info)
        : Future.value(_stubSeal(bytes));
    Future<Uint8List> open(Uint8List bytes, List<int> info) => hpke
        ? Hpke.open(
            privateKey: privateKey,
            sealed: bytes,
            info: info,
            aad: info,
          )
        : Future.value(_stubOpen(bytes));
    await for (final dynamic message in port) {
      final job = message as List, id = job[0];
      final value = job[2] as Map;
      try {
        switch (job[1]) {
          case 'seal':
            final payload = value['payload'] as Uint8List;
            final padded = Uint8List(innerSize - 48);
            ByteData.sublistView(padded).setUint32(0, payload.length);
            padded.setRange(4, 4 + payload.length, payload);
            final inner = await seal(
              value['exitKey'] as Uint8List,
              padded,
              exitInfo,
            );
            final route = value['exitId'] as String;
            final outer = Uint8List(outerSize - 48);
            for (var i = 0; i < 32; i++) {
              outer[i] = int.parse(
                route.substring(i * 2, i * 2 + 2),
                radix: 16,
              );
            }
            outer.setRange(32, outer.length, inner);
            reply.send([
              id,
              true,
              await seal(value['guardKey'] as Uint8List, outer, entryInfo),
            ]);
          case 'entry':
            final plain = await open(value['cell'] as Uint8List, entryInfo);
            if (plain.length != outerSize - 48) throw const FormatException();
            reply.send([
              id,
              true,
              {
                'exitId': plain
                    .sublist(0, 32)
                    .map((b) => b.toRadixString(16).padLeft(2, '0'))
                    .join(),
                'cell': Uint8List.sublistView(plain, 32),
              },
            ]);
          case 'exit':
            final plain = await open(value['cell'] as Uint8List, exitInfo);
            if (plain.length != innerSize - 48) throw const FormatException();
            final length = ByteData.sublistView(plain).getUint32(0);
            if (length > payloadCapacity) throw const FormatException();
            for (var i = 4 + length; i < plain.length; i++) {
              if (plain[i] != 0) throw const FormatException();
            }
            reply.send([id, true, Uint8List.sublistView(plain, 4, 4 + length)]);
          default:
            throw const FormatException();
        }
      } catch (_) {
        reply.send([id, false]);
      }
    }
  }

  static Uint8List _stubSeal(Uint8List body) {
    final box = Uint8List(body.length + 48);
    final random = Random.secure();
    for (var i = 0; i < 32; i++) {
      box[i] = random.nextInt(256);
    }
    box.setRange(32, 32 + body.length, body);
    _mask(box);
    return box;
  }

  static Uint8List _stubOpen(Uint8List box) {
    final copy = Uint8List.fromList(box);
    _mask(copy);
    return Uint8List.sublistView(copy, 32, copy.length - 16);
  }

  static void _mask(Uint8List bytes) {
    final nonce = bytes.sublist(0, 32);
    var at = 32, counter = 0;
    while (at < bytes.length) {
      final block = sha256.convert([
        ...nonce,
        counter >> 8,
        counter & 255,
      ]).bytes;
      for (final byte in block) {
        if (at == bytes.length) break;
        bytes[at++] ^= byte;
      }
      counter++;
    }
  }
}
