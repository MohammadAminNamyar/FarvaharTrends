import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A 127.0.0.1 listener is reachable by every app on the device, so loopback
/// alone is not an application identity. Every loopback flow between native
/// code, the overlay and the Dart engine is guarded by a 32-byte random
/// preface that only ever crosses the private platform channel or in-process
/// Dart calls. The connecting side writes it before any TLS byte; the
/// listening side reads exactly that many bytes under a short deadline and
/// compares in constant time. A wrong caller is dropped without consuming the
/// legitimate flow. Prefaces are never logged, reported or sent on the air;
/// pinned mutual TLS still follows local authentication.
class LoopbackPreface {
  static const length = 32;
  static const maxAttempts = 8;
  static const readTimeout = Duration(seconds: 3);
  static final _random = Random.secure();

  static Uint8List newToken() =>
      Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

  static bool valid(Object? token) =>
      token is Uint8List && token.length == length;

  /// Constant-time comparison; never exits early on content.
  static bool matches(List<int> expected, List<int> actual) {
    if (expected.length != actual.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ actual[i];
    }
    return difference == 0;
  }

  /// Listener side on a [RawSocket]. Keeps the live subscription and any TLS
  /// bytes read after the preface for [RawSecureSocket.secureServer]. A
  /// mismatch, short read or timeout closes the socket and throws.
  static Future<LoopbackPrefaceResult> read(
    RawSocket socket,
    Uint8List token, {
    Duration timeout = readTimeout,
  }) async {
    if (!valid(token)) throw ArgumentError('Invalid loopback preface.');
    final completion = Completer<LoopbackPrefaceResult>();
    final bytes = <int>[];
    late final StreamSubscription<RawSocketEvent> subscription;
    void fail(Object error) {
      if (completion.isCompleted) return;
      completion.completeError(error);
      unawaited(socket.close());
      unawaited(subscription.cancel());
    }

    socket.writeEventsEnabled = false;
    subscription = socket.listen(
      (event) {
        if (completion.isCompleted) return;
        if (event == RawSocketEvent.read) {
          final chunk = socket.read(length + 16384 - bytes.length);
          if (chunk == null) return;
          bytes.addAll(chunk);
          if (bytes.length < length) return;
          if (!matches(token, bytes.sublist(0, length))) {
            fail(const FormatException('Loopback preface rejected.'));
            return;
          }
          socket.readEventsEnabled = false;
          socket.writeEventsEnabled = false;
          completion.complete(
            LoopbackPrefaceResult(
              Uint8List.fromList(bytes.sublist(length)),
              subscription,
            ),
          );
        } else if (event == RawSocketEvent.readClosed ||
            event == RawSocketEvent.closed) {
          fail(const SocketException('Loopback caller closed.'));
        }
      },
      onError: (Object error) => fail(error),
      onDone: () => fail(const SocketException('Loopback caller closed.')),
      cancelOnError: true,
    );
    return completion.future.timeout(
      timeout,
      onTimeout: () {
        fail(TimeoutException('Loopback preface timed out.'));
        throw TimeoutException('Loopback preface timed out.');
      },
    );
  }

  /// Client side on a [RawSocket]. Handles partial writes and hands its
  /// subscription to [RawSecureSocket.secure].
  static Future<StreamSubscription<RawSocketEvent>> write(
    RawSocket socket,
    Uint8List token, {
    Duration timeout = readTimeout,
  }) async {
    if (!valid(token)) throw ArgumentError('Invalid loopback preface.');
    final completion = Completer<StreamSubscription<RawSocketEvent>>();
    var offset = 0;
    late final StreamSubscription<RawSocketEvent> subscription;
    void fail(Object error) {
      if (completion.isCompleted) return;
      completion.completeError(error);
      unawaited(socket.close());
      unawaited(subscription.cancel());
    }

    void pump() {
      if (completion.isCompleted) return;
      try {
        while (offset < length) {
          final count = socket.write(token, offset, length - offset);
          if (count == 0) {
            socket.writeEventsEnabled = true;
            return;
          }
          offset += count;
        }
        socket.writeEventsEnabled = false;
        completion.complete(subscription);
      } catch (error) {
        fail(error);
      }
    }

    socket.readEventsEnabled = false;
    socket.writeEventsEnabled = false;
    subscription = socket.listen(
      (event) {
        if (event == RawSocketEvent.write) {
          pump();
        } else if (event == RawSocketEvent.readClosed ||
            event == RawSocketEvent.closed) {
          fail(const SocketException('Loopback listener closed.'));
        }
      },
      onError: (Object error) => fail(error),
      onDone: () => fail(const SocketException('Loopback listener closed.')),
      cancelOnError: true,
    );
    pump();
    return completion.future.timeout(
      timeout,
      onTimeout: () {
        fail(TimeoutException('Loopback preface write timed out.'));
        throw TimeoutException('Loopback preface write timed out.');
      },
    );
  }

  /// Listener side on a dart:io [Socket]. Resolves with the stream of bytes
  /// that follow a correct preface; backpressure on that stream reaches the
  /// socket. A mismatch, short read or timeout destroys the socket and throws.
  static Future<Stream<Uint8List>> readStream(
    Socket socket,
    Uint8List token, {
    Duration timeout = readTimeout,
  }) {
    if (!valid(token)) throw ArgumentError('Invalid loopback preface.');
    final completion = Completer<Stream<Uint8List>>();
    final bytes = <int>[];
    StreamController<Uint8List>? forward;
    late final StreamSubscription<Uint8List> subscription;
    late final Timer deadline;
    void fail(Object error) {
      deadline.cancel();
      if (completion.isCompleted) return;
      completion.completeError(error);
      socket.destroy();
      unawaited(subscription.cancel());
    }

    subscription = socket.listen(
      (chunk) {
        final target = forward;
        if (target != null) {
          target.add(chunk);
          return;
        }
        if (completion.isCompleted) return;
        bytes.addAll(chunk);
        if (bytes.length < length) return;
        if (!matches(token, bytes.sublist(0, length))) {
          fail(const FormatException('Loopback preface rejected.'));
          return;
        }
        deadline.cancel();
        final controller = StreamController<Uint8List>(
          onPause: subscription.pause,
          onResume: subscription.resume,
          onCancel: subscription.cancel,
        );
        forward = controller;
        if (bytes.length > length) {
          controller.add(Uint8List.fromList(bytes.sublist(length)));
        }
        bytes.clear();
        completion.complete(controller.stream);
      },
      onError: (Object error) {
        final target = forward;
        if (target != null) {
          target.addError(error);
        } else {
          fail(error);
        }
      },
      onDone: () {
        final target = forward;
        if (target != null) {
          unawaited(target.close());
        } else {
          fail(const SocketException('Loopback caller closed.'));
        }
      },
    );
    deadline = Timer(timeout, () {
      fail(TimeoutException('Loopback preface timed out.'));
    });
    return completion.future;
  }

  /// A single-use flow on a dart:io [ServerSocket]: accepts until one loopback
  /// caller proves [token], [deadline] passes or [maxAttempts] callers failed.
  /// The listener is always closed before the returned future completes, so a
  /// replayed preface after use is refused and late callers reach nothing.
  static Future<LoopbackFlow> acceptOnce(
    ServerSocket server,
    Uint8List token, {
    required Duration deadline,
    Duration readTimeout = readTimeout,
  }) {
    if (!valid(token)) throw ArgumentError('Invalid loopback preface.');
    final completion = Completer<LoopbackFlow>();
    final pending = <Socket>{};
    var attempts = 0;
    late final StreamSubscription<Socket> accepting;
    late final Timer expiry;
    Future<void> finish([Object? error]) async {
      expiry.cancel();
      await accepting.cancel();
      await server.close();
      for (final socket in pending.toList()) {
        socket.destroy();
      }
      pending.clear();
      if (completion.isCompleted) return;
      if (error != null) {
        completion.completeError(error);
      }
    }

    accepting = server.listen(
      (socket) {
        if (completion.isCompleted ||
            !socket.remoteAddress.isLoopback ||
            attempts >= maxAttempts) {
          socket.destroy();
          return;
        }
        attempts++;
        pending.add(socket);
        unawaited(() async {
          try {
            final data = await readStream(socket, token, timeout: readTimeout);
            pending.remove(socket);
            if (completion.isCompleted) {
              socket.destroy();
              return;
            }
            completion.complete(LoopbackFlow(socket, data));
            await finish();
          } catch (_) {
            pending.remove(socket);
            socket.destroy();
            if (!completion.isCompleted && attempts >= maxAttempts) {
              await finish(
                const SocketException('Loopback preface attempts exhausted.'),
              );
            }
          }
        }());
      },
      onError: (Object error) => unawaited(finish(error)),
      onDone: () {
        if (!completion.isCompleted) {
          unawaited(finish(const SocketException('Loopback listener closed.')));
        }
      },
    );
    expiry = Timer(deadline, () {
      unawaited(finish(TimeoutException('Loopback flow expired.')));
    });
    return completion.future;
  }
}

class LoopbackPrefaceResult {
  const LoopbackPrefaceResult(this.bufferedTls, this.subscription);
  final Uint8List bufferedTls;
  final StreamSubscription<RawSocketEvent> subscription;
}

class LoopbackFlow {
  const LoopbackFlow(this.socket, this.data);

  /// Authenticated loopback socket; write to it directly.
  final Socket socket;

  /// Bytes that follow the preface. Listen here instead of on [socket].
  final Stream<Uint8List> data;
}
