part of 'peer_engine.dart';

class _ImageDownload {
  _ImageDownload(this.image, this.peerId, this.started);
  final NewsImage image;
  final String peerId;
  final int started;
  final BytesBuilder data = BytesBuilder(copy: false);
}

extension ImageTransfer on PeerEngine {
  Future<void> _pruneImages() async {
    final referenced = _store.bulletins.values
        .map((v) => SignedBulletin.fromJson(v).image?.hash)
        .whereType<String>()
        .toSet();
    _imageDownloads.removeWhere((hash, _) => !referenced.contains(hash));
    await _media.retain(referenced);
  }

  Future<bool> _imagesAllowed(_Link link) async {
    if (!link.modern ||
        link.transport == PeerTransport.bluetooth ||
        imageMode == 'never') {
      return false;
    }
    if (imageMode == 'any') return true;
    if (imageMode != 'wifiOnly') return false;
    if (link.transport == PeerTransport.lan ||
        link.transport == PeerTransport.wifiDirect) {
      return true;
    }
    final state = await deviceState();
    return state['network'] == 'wifi';
  }

  NewsImage? _referencedImage(String hash) {
    for (final raw in _store.bulletins.values) {
      final image = SignedBulletin.fromJson(raw).image;
      if (image?.hash == hash) return image;
    }
    return null;
  }

  Future<void> _requestImages(_Link link, List<String> available) async {
    _imageDownloads.removeWhere(
      (_, v) =>
          _clock.elapsedMilliseconds - v.started > 120000 ||
          !_links.containsKey(v.peerId),
    );
    if (!await _imagesAllowed(link)) return;
    for (final hash in available) {
      if (_imageDownloads.length >= 4 ||
          _imageDownloads.values.where((v) => v.peerId == link.peerId).length >=
              2) {
        break;
      }
      final image = _referencedImage(hash);
      if (image == null ||
          _media.has(hash) ||
          _imageDownloads.containsKey(hash)) {
        continue;
      }
      _imageDownloads[hash] = _ImageDownload(
        image,
        link.peerId,
        _clock.elapsedMilliseconds,
      );
      if (!await _send(link, {
        'type': 'mediaWant',
        'hash': hash,
        'offset': 0,
      })) {
        _imageDownloads.remove(hash);
      }
    }
  }

  Future<void> _serveImage(_Link link, Map<String, dynamic> frame) async {
    if (!await _imagesAllowed(link)) return;
    final hash = frame['hash'], offset = frame['offset'];
    if (frame.length != 3 ||
        hash is! String ||
        !ChannelControl.fingerprint.hasMatch(hash) ||
        offset is! int ||
        offset < 0 ||
        offset % 4096 != 0 ||
        offset >= NewsImage.maxBytes) {
      throw const FormatException('Invalid image request.');
    }
    if (!_allowRequests(link, 1)) return;
    final descriptor = _referencedImage(hash);
    if (descriptor == null || offset >= descriptor.bytes) return;
    final bytes = await _media.read(hash);
    if (bytes == null) return;
    await _sendResponse(link, 'image:$hash:$offset', {
      'type': 'mediaChunk',
      'hash': hash,
      'offset': offset,
      'data': base64Encode(
        bytes.sublist(offset, min(offset + 4096, bytes.length)),
      ),
    });
  }

  Future<void> _receiveImage(_Link link, Map<String, dynamic> frame) async {
    final hash = frame['hash'];
    final pending = hash is String ? _imageDownloads[hash] : null;
    if (pending == null || pending.peerId != link.peerId) return;
    if (!await _imagesAllowed(link) ||
        _referencedImage(hash as String) == null) {
      _imageDownloads.remove(hash);
      return;
    }
    try {
      final encoded = frame['data'];
      if (frame.length != 4 ||
          frame['offset'] != pending.data.length ||
          encoded is! String ||
          encoded.length > 5464) {
        throw const FormatException();
      }
      final bytes = base64Decode(encoded);
      final remaining = pending.image.bytes - pending.data.length;
      if (base64Encode(bytes) != encoded ||
          bytes.length != min(4096, remaining)) {
        throw const FormatException();
      }
      pending.data.add(bytes);
      if (pending.data.length == pending.image.bytes) {
        await _media.put(pending.image, pending.data.takeBytes());
        _imageDownloads.remove(hash);
        _notify();
      } else {
        await _send(link, {
          'type': 'mediaWant',
          'hash': hash,
          'offset': pending.data.length,
        });
      }
    } catch (_) {
      _imageDownloads.remove(hash);
      _discardPublisherObject(link, 'invalid_image');
    }
  }
}
