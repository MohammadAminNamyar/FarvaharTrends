import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class NewsImage {
  NewsImage._(this.hash, this.bytes, this.width, this.height);
  final String hash;
  final int bytes, width, height;
  static const maxBytes = 96 * 1024;
  static const maxDimension = 1280;
  factory NewsImage.fromJson(Map<String, dynamic> json) {
    if (json.length != 5 ||
        json['mime'] != 'image/jpeg' ||
        json['hash'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(json['hash'] as String) ||
        json['bytes'] is! int ||
        json['bytes'] < 4 ||
        json['bytes'] > maxBytes ||
        json['width'] is! int ||
        json['height'] is! int ||
        json['width'] < 1 ||
        json['height'] < 1 ||
        json['width'] > maxDimension ||
        json['height'] > maxDimension) {
      throw const FormatException('Invalid compressed image descriptor.');
    }
    return NewsImage._(
      json['hash'] as String,
      json['bytes'] as int,
      json['width'] as int,
      json['height'] as int,
    );
  }
  Map<String, dynamic> toJson() => {
    'hash': hash,
    'bytes': bytes,
    'width': width,
    'height': height,
    'mime': 'image/jpeg',
  };
  static NewsImage inspect(Uint8List data) {
    if (data.length < 4 ||
        data.length > maxBytes ||
        data[0] != 255 ||
        data[1] != 216 ||
        data[data.length - 2] != 255 ||
        data.last != 217) {
      throw const FormatException('Expected a bounded JPEG image.');
    }
    var offset = 2;
    var entropy = false, scanned = false;
    NewsImage? image;
    while (offset < data.length) {
      if (entropy) {
        while (offset < data.length && data[offset] != 255) {
          offset++;
        }
      }
      if (offset >= data.length || data[offset++] != 255) {
        throw const FormatException('Invalid JPEG marker.');
      }
      while (offset < data.length && data[offset] == 255) {
        offset++;
      }
      if (offset >= data.length) break;
      final marker = data[offset++];
      if (entropy && (marker == 0 || (marker >= 208 && marker <= 215))) {
        continue;
      }
      if (marker == 217) {
        if (offset != data.length || image == null || !scanned) {
          throw const FormatException('Incomplete JPEG.');
        }
        return image;
      }
      if (marker == 216 || offset + 2 > data.length) {
        throw const FormatException('Invalid JPEG marker.');
      }
      final length = (data[offset] << 8) | data[offset + 1];
      if (length < 2 || offset + length > data.length) {
        throw const FormatException('Invalid JPEG segment.');
      }
      if (marker >= 192 && marker <= 207 && !{196, 200, 204}.contains(marker)) {
        if (!{192, 194}.contains(marker) ||
            image != null ||
            scanned ||
            length < 11 ||
            data[offset + 2] != 8) {
          throw const FormatException('Unsupported or repeated JPEG frame.');
        }
        final components = data[offset + 7];
        if (!{1, 3}.contains(components) || length != 8 + 3 * components) {
          throw const FormatException('Invalid JPEG components.');
        }
        image = NewsImage.fromJson({
          'hash': sha256.convert(data).toString(),
          'bytes': data.length,
          'height': (data[offset + 3] << 8) | data[offset + 4],
          'width': (data[offset + 5] << 8) | data[offset + 6],
          'mime': 'image/jpeg',
        });
      }
      entropy = marker == 218;
      if (entropy) {
        if (image == null || length < 6) {
          throw const FormatException('JPEG scan has no bounded frame.');
        }
        final components = data[offset + 2];
        if (components < 1 || components > 3 || length != 6 + 2 * components) {
          throw const FormatException('Invalid JPEG scan.');
        }
        scanned = true;
      }
      offset += length;
    }
    throw const FormatException('JPEG dimensions are missing.');
  }
}

/// Content-addressed image cache. Text delivery never waits for an image.
class MediaStore {
  MediaStore(Directory parent)
    : directory = Directory('${parent.path}/news-images');
  final Directory directory;
  static const maxCacheBytes = 8 * 1024 * 1024;
  static const maxFiles = 96;
  final Map<String, int> _files = {};
  Future<void> _tail = Future.value();
  Future<void> load() async {
    await directory.create(recursive: true);
    // A crash between writing and renaming must not leave accumulating files.
    await for (final item in directory.list()) {
      if (item is File &&
          RegExp(r'^[a-f0-9]{64}\.next$')
              .hasMatch(item.uri.pathSegments.last)) {
        await item.delete();
      }
    }
    final files = await directory
        .list()
        .where(
          (item) =>
              item is File &&
              RegExp(r'^[a-f0-9]{64}\.jpg$')
                  .hasMatch(item.uri.pathSegments.last),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      try {
        if (await file.length() > NewsImage.maxBytes) {
          await file.delete();
          continue;
        }
        final image = NewsImage.inspect(await file.readAsBytes());
        if (!file.path.endsWith('${image.hash}.jpg')) {
          await file.delete();
          continue;
        }
        _files[image.hash] = image.bytes;
      } on FormatException {
        await file.delete();
      }
    }
    await _trim();
  }

  bool has(String hash) => _files.containsKey(hash);
  String? path(String hash) => has(hash) ? '${directory.path}/$hash.jpg' : null;
  List<String> get hashes => _files.keys.toList().reversed.take(64).toList();
  Future<Uint8List?> read(String hash) async {
    if (!has(hash)) return null;
    try {
      return await File(path(hash)!).readAsBytes();
    } on FileSystemException {
      _files.remove(hash);
      return null;
    }
  }

  Future<void> put(NewsImage expected, Uint8List bytes) {
    final operation = _tail.then((_) async {
      final actual = NewsImage.inspect(bytes);
      if (actual.hash != expected.hash ||
          actual.bytes != expected.bytes ||
          actual.width != expected.width ||
          actual.height != expected.height) {
        throw const FormatException(
          'Image hash or dimensions disagree with signed news.',
        );
      }
      if (has(actual.hash)) return;
      await directory.create(recursive: true);
      final pending = File('${directory.path}/${actual.hash}.next');
      await pending.writeAsBytes(bytes, flush: true);
      await pending.rename('${directory.path}/${actual.hash}.jpg');
      _files[actual.hash] = actual.bytes;
      await _trim();
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> retain(Set<String> referenced) {
    final operation = _tail.then((_) async {
      for (final hash
          in _files.keys.where((hash) => !referenced.contains(hash)).toList()) {
        _files.remove(hash);
        final file = File('${directory.path}/$hash.jpg');
        if (await file.exists()) await file.delete();
      }
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> _trim() async {
    var total = _files.values.fold<int>(0, (sum, value) => sum + value);
    while (_files.length > maxFiles || total > maxCacheBytes) {
      final hash = _files.keys.first;
      total -= _files.remove(hash)!;
      final file = File('${directory.path}/$hash.jpg');
      if (await file.exists()) await file.delete();
    }
  }
}
