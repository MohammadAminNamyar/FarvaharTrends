import 'dart:typed_data';

/// Small transport records. News stays inside the existing pinned TLS stream.
class OverlayFrame {
  const OverlayFrame(this.type, this.bytes);
  static const hello = 0;
  static const data = 1;
  static const ready = 2;
  static const maxPayload = 32768;
  final int type;
  final Uint8List bytes;

  static Uint8List encode(int type, List<int> bytes) {
    _validate(type, bytes.length);
    final result = Uint8List(bytes.length + 5);
    ByteData.sublistView(result).setUint32(0, bytes.length + 1);
    result[4] = type;
    result.setRange(5, result.length, bytes);
    return result;
  }

  static void _validate(int type, int size) {
    if (size > maxPayload ||
        type < hello ||
        type > ready ||
        type == hello && (size == 0 || size > 8192) ||
        type == data && size == 0 ||
        type == ready && size != 0) {
      throw const FormatException('Invalid overlay record.');
    }
  }
}

class OverlayFrameDecoder {
  Uint8List _pending = Uint8List(0);
  List<OverlayFrame> add(List<int> bytes) {
    if (_pending.length + bytes.length > 256 * 1024) {
      throw const FormatException('Overlay buffer limit reached.');
    }
    final buffer = Uint8List(_pending.length + bytes.length)
      ..setRange(0, _pending.length, _pending)
      ..setRange(_pending.length, _pending.length + bytes.length, bytes);
    var offset = 0;
    final result = <OverlayFrame>[];
    final header = ByteData.sublistView(buffer);
    while (buffer.length - offset >= 4) {
      final length = header.getUint32(offset);
      if (length < 1 || length > OverlayFrame.maxPayload + 1) {
        throw const FormatException('Invalid overlay record length.');
      }
      if (buffer.length - offset < length + 4) break;
      final type = buffer[offset + 4];
      final body = Uint8List.fromList(
        Uint8List.sublistView(buffer, offset + 5, offset + length + 4),
      );
      OverlayFrame._validate(type, body.length);
      result.add(OverlayFrame(type, body));
      offset += length + 4;
    }
    // One compaction per input chunk; records never retain the large buffer.
    _pending = Uint8List.fromList(Uint8List.sublistView(buffer, offset));
    return result;
  }
}
