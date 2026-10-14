import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/peer_engine.dart';

void main() {
  test('A reader making continuous tiny progress still reaches an absolute deadline', () async {
    final writer = PeerWriteQueue();
    var written = 0, failures = 0;
    final clock = Stopwatch()..start();
    final completed = await writer.enqueue(
      deadline: const Duration(milliseconds: 50),
      onFailure: () => failures++,
      operation: () async {
        while (written < 1000 && !writer.closed) {
          await Future<void>.delayed(const Duration(milliseconds: 3));
          if (!writer.closed) written++;
        }
      },
    );
    expect(completed, isFalse);
    expect(written, greaterThan(0));
    expect(written, lessThan(1000));
    expect(failures, 1);
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
    final afterTimeout = written;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      written,
      afterTimeout,
      reason: 'Closing must prevent writes after timeout',
    );
  });

  test('Deadline includes queue wait and frees callers even if an earlier operation is blocked', () async {
    final writer = PeerWriteQueue();
    final gate = Completer<void>();
    var failures = 0, lateWrites = 0;
    final first = writer.enqueue(
      deadline: const Duration(milliseconds: 150),
      onFailure: () => failures++,
      operation: () async {
        await gate.future;
      },
    );
    final clock = Stopwatch()..start();
    final queued = writer.enqueue(
      deadline: const Duration(milliseconds: 30),
      onFailure: () => failures++,
      operation: () async {
        lateWrites++;
      },
    );
    expect(await queued, isFalse);
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
    expect(writer.closed, isTrue);
    expect(failures, 1);
    expect(lateWrites, 0);
    expect(await first, isFalse);
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      lateWrites,
      0,
      reason: 'A timed-out queued frame must never start later',
    );
    expect(writer.pending, 0);
  });

  test('Healthy queued frames preserve order and one failure closes all later work', () async {
    final writer = PeerWriteQueue();
    final order = <int>[];
    var failures = 0;
    void fail() => failures++;
    final results = await Future.wait([
      writer.enqueue(
        deadline: const Duration(seconds: 1),
        onFailure: fail,
        operation: () async {
          await Future<void>.delayed(Duration.zero);
          order.add(1);
        },
      ),
      writer.enqueue(
        deadline: const Duration(seconds: 1),
        onFailure: fail,
        operation: () async {
          order.add(2);
        },
      ),
    ]);
    expect(results, [true, true]);
    expect(order, [1, 2]);
    expect(
      await writer.enqueue(
        deadline: const Duration(seconds: 1),
        onFailure: fail,
        operation: () async {
          throw StateError('Socket failed');
        },
      ),
      isFalse,
    );
    expect(
      await writer.enqueue(
        deadline: const Duration(seconds: 1),
        onFailure: fail,
        operation: () async {
          order.add(3);
        },
      ),
      isFalse,
    );
    expect(order, [1, 2]);
    expect(failures, 1);
  });
}
