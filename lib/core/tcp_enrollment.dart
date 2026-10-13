import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Public connection-key admission only. News always follows pinned TLS.
/// A replayed preface grants no access without the corresponding TLS key.
class TcpEnrollment {
  static const prefix = 'PTRELAY/1 ';
  static const maxBeaconBytes = 4096;
  static const maxPrefaceBytes = 5500;
  static const timeout = Duration(seconds: 3);

  static Uint8List encode(Uint8List beacon) {
    if (beacon.isEmpty || beacon.length > maxBeaconBytes) {
      throw const FormatException('Invalid enrollment size.');
    }
    return Uint8List.fromList(
      utf8.encode('$prefix${base64UrlEncode(beacon)}\n'),
    );
  }

  /// Retains the live raw subscription for secureServer to take over. Already
  /// read TLS bytes are handed to its bufferedData argument, never discarded.
  static Future<TcpEnrollmentPreface> read(RawSocket socket) async {
    final completion = Completer<TcpEnrollmentPreface>();
    final bytes = <int>[];
    late final StreamSubscription<RawSocketEvent> subscription;
    void fail(Object error) {
      if (completion.isCompleted) return;
      completion.completeError(error);
      unawaited(socket.close());
      unawaited(subscription.cancel());
    }

    void finish(Uint8List? beacon, List<int> tls) {
      socket.readEventsEnabled = false;
      socket.writeEventsEnabled = false;
      completion.complete(
        TcpEnrollmentPreface(beacon, Uint8List.fromList(tls), subscription),
      );
    }

    socket.writeEventsEnabled = false;
    subscription = socket.listen(
      (event) {
        if (completion.isCompleted) return;
        if (event == RawSocketEvent.read) {
          try {
            final chunk = socket.read(maxPrefaceBytes + 1 - bytes.length);
            if (chunk == null) return;
            bytes.addAll(chunk);
            // Legacy pinned TLS clients remain compatible with a relay listener.
            if (bytes.first == 0x16) {
              finish(null, bytes);
              return;
            }
            if (bytes.first != 0x50) throw const FormatException();
            final end = bytes.indexOf(10);
            if (end < 0) {
              if (bytes.length > maxPrefaceBytes) {
                throw const FormatException();
              }
              return;
            }
            if (end > maxPrefaceBytes) throw const FormatException();
            final line = utf8.decode(bytes.sublist(0, end));
            if (!line.startsWith(prefix)) throw const FormatException();
            final beacon = base64Url.decode(line.substring(prefix.length));
            if (beacon.isEmpty || beacon.length > maxBeaconBytes) {
              throw const FormatException();
            }
            finish(beacon, bytes.sublist(end + 1));
          } catch (_) {
            fail(const FormatException('Invalid TCP enrollment preface.'));
          }
        } else if (event == RawSocketEvent.readClosed ||
            event == RawSocketEvent.closed) {
          fail(const SocketException('Enrollment connection closed.'));
        }
      },
      onError: (Object error) => fail(error),
      onDone: () =>
          fail(const SocketException('Enrollment connection closed.')),
      cancelOnError: true,
    );
    // The caller owns the live subscription on success; failure closes it.
    return completion.future.timeout(
      timeout,
      onTimeout: () {
        fail(TimeoutException('TCP enrollment timed out.'));
        throw TimeoutException('TCP enrollment timed out.');
      },
    );
  }

  /// Handles partial socket writes and hands its subscription to secure().
  static Future<StreamSubscription<RawSocketEvent>> write(
    RawSocket socket,
    Uint8List beacon,
  ) async {
    final bytes = encode(beacon);
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
        while (offset < bytes.length) {
          final count = socket.write(bytes, offset, bytes.length - offset);
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
          fail(const SocketException('Enrollment connection closed.'));
        }
      },
      onError: (Object error) => fail(error),
      onDone: () =>
          fail(const SocketException('Enrollment connection closed.')),
      cancelOnError: true,
    );
    pump();
    return completion.future.timeout(
      timeout,
      onTimeout: () {
        fail(TimeoutException('TCP enrollment write timed out.'));
        throw TimeoutException('TCP enrollment write timed out.');
      },
    );
  }
}

class TcpEnrollmentPreface {
  const TcpEnrollmentPreface(this.beacon, this.bufferedTls, this.subscription);
  final Uint8List? beacon;
  final Uint8List bufferedTls;
  final StreamSubscription<RawSocketEvent> subscription;
}
