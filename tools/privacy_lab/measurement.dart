// Local research instrumentation. Never imported by the application.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

final class _FileTime extends Struct {
  @Uint32()
  external int low;
  @Uint32()
  external int high;

  int get ticks => (high << 32) | low;
}

/// Windows process CPU, including all Dart isolates and runtime threads.
/// This is consumed core time, not wall time or whole-machine CPU load.
class ProcessCpu {
  ProcessCpu() {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'This baseline CPU sampler currently needs Windows.',
      );
    }
  }

  final _kernel = DynamicLibrary.open('kernel32.dll');
  late final _process = _kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetCurrentProcess',
      )();
  late final _heap = _kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();
  late final _alloc = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  late final _free = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  late final _times = _kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
        )
      >('GetProcessTimes');

  double readMs() {
    final memory = _alloc(_heap, 8, 4 * sizeOf<_FileTime>());
    if (memory == nullptr) throw StateError('CPU sampler allocation failed');
    final values = memory.cast<_FileTime>();
    try {
      if (_times(_process, values, values + 1, values + 2, values + 3) == 0) {
        throw StateError('GetProcessTimes failed');
      }
      return ((values + 2).ref.ticks + (values + 3).ref.ticks) / 10000;
    } finally {
      _free(_heap, 0, memory);
    }
  }
}

/// Counts encrypted TLS stream bytes without terminating or inspecting TLS.
/// A byte crossing the proxy is counted once, at the incoming stream.
/// TCP/IP headers, retransmissions and radio costs are NOT included.
class MeteredLink {
  MeteredLink._(this._listener, this.targetPort) {
    _subscription = _listener.listen(_accept);
  }

  final ServerSocket _listener;
  final int targetPort;
  late final StreamSubscription<Socket> _subscription;
  final _sockets = <Socket>{};
  final _pumps = <Future<void>>[];
  final errors = <String>[];
  int upstreamBytes = 0;
  int downstreamBytes = 0;
  int acceptedConnections = 0;
  bool _closing = false;

  int get port => _listener.port;
  static Future<MeteredLink> start(int targetPort) async => MeteredLink._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    targetPort,
  );

  void _accept(Socket incoming) {
    _sockets.add(incoming);
    acceptedConnections++;
    _pumps.add(_connect(incoming));
  }

  Future<void> _connect(Socket incoming) async {
    Socket? outgoing;
    try {
      outgoing = await Socket.connect(
        InternetAddress.loopbackIPv4,
        targetPort,
        timeout: const Duration(seconds: 3),
      );
      _sockets.add(outgoing);
      if (_closing) return;
      final target = outgoing;
      Future<void> pump(Socket from, Socket to, bool upstream) async {
        try {
          await for (final bytes in from) {
            if (upstream) {
              upstreamBytes += bytes.length;
            } else {
              downstreamBytes += bytes.length;
            }
            to.add(bytes);
            await to.flush();
          }
        } on SocketException catch (e) {
          if (!_closing && errors.length < 10) errors.add('$e');
        } finally {
          from.destroy();
          to.destroy();
        }
      }

      await Future.wait([
        pump(incoming, target, true),
        pump(target, incoming, false),
      ]);
    } catch (e) {
      if (!_closing && errors.length < 10) errors.add('$e');
    } finally {
      incoming.destroy();
      outgoing?.destroy();
      _sockets.remove(incoming);
      _sockets.remove(outgoing);
    }
  }

  Map<String, int> snapshot() => {
    'upstreamTlsBytes': upstreamBytes,
    'downstreamTlsBytes': downstreamBytes,
    'acceptedConnections': acceptedConnections,
  };

  Future<void> close() async {
    _closing = true;
    await _subscription.cancel();
    await _listener.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await Future.wait(_pumps);
  }
}
