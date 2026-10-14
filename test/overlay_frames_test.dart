import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/overlay_frames.dart';

void main() {
  test('many coalesced small records decode within a bounded time', () {
    final frame = OverlayFrame.encode(OverlayFrame.data, [42]);
    final chunk = Uint8List.fromList([for (var i = 0; i < 30000; i++) ...frame]);
    final clock = Stopwatch()..start();
    final frames = OverlayFrameDecoder().add(chunk);
    clock.stop();
    expect(frames, hasLength(30000));
    expect(frames.every((f) => f.bytes.single == 42), true);
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
  });
  test('Fragmented and coalesced records preserve exact bytes', () {
    final bytes = [
      ...OverlayFrame.encode(OverlayFrame.hello, [1, 2]),
      ...OverlayFrame.encode(OverlayFrame.ready, []),
      ...OverlayFrame.encode(OverlayFrame.data, [255, 0, 128, 7]),
    ];
    final decoder = OverlayFrameDecoder();
    final frames = <OverlayFrame>[];
    for (var index = 0; index < bytes.length; index++) {
      frames.addAll(decoder.add([bytes[index]]));
    }
    expect(frames.map((frame) => frame.type), [0, 2, 1]);
    expect(frames.last.bytes, [255, 0, 128, 7]);
    expect(OverlayFrameDecoder().add(bytes).length, 3);
  });
  test('Reject impossible lengths before buffering their bodies', () {
    for (final length in [0, 32770, 0xffffffff]) {
      final header = Uint8List(4);
      ByteData.sublistView(header).setUint32(0, length);
      expect(() => OverlayFrameDecoder().add(header), throwsFormatException);
    }
    expect(
      () => OverlayFrameDecoder().add(Uint8List(256 * 1024 + 1)),
      throwsFormatException,
    );
  });
  test('Reject unknown records, empty data and oversized introductions', () {
    for (final type in [-1, 3, 255]) {
      expect(() => OverlayFrame.encode(type, [1]), throwsFormatException);
    }
    expect(
      () => OverlayFrame.encode(OverlayFrame.ready, [1]),
      throwsFormatException,
    );
    expect(
      () => OverlayFrame.encode(OverlayFrame.data, []),
      throwsFormatException,
    );
    expect(
      () => OverlayFrame.encode(OverlayFrame.hello, Uint8List(8193)),
      throwsFormatException,
    );
    expect(
      () => OverlayFrameDecoder().add([0, 0, 0, 1, 255]),
      throwsFormatException,
    );
  });
}
