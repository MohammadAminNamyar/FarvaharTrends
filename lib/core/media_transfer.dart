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
    final referenced = _store.referencedImageHashes.toSet()
      ..addAll(_publishingImages);
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
    try {
      final state = await deviceState();
      return state['network'] == 'wifi';
    } catch (_) {
      // A local network-state failure must not blame or disconnect a peer.
      return false;
    }
  }

  (NewsImage, bool)? _referencedImage(String hash) {
    return _store.referencedImage(hash);
  }

  Future<List<String>> _imageInventory(_Link link) async {
    if (!link.modern || link.transport == PeerTransport.bluetooth) return [];
    if (await _imagesAllowed(link)) return _media.hashes;
    // Attaching a photo explicitly authorizes publishing it, independently of
    // automatic downloads. Received photos still follow the reader's policy.
    final own = _store.localImageHashes.toSet();
    return _media.hashes.where(own.contains).toList();
  }

  Future<void> _sendImageInventory(_Link link) async {
    if (!link.modern || link.transport == PeerTransport.bluetooth) return;
    await _send(link, {
      'type': 'inventory',
      'features': ['channel-v2'],
      'media': await _imageInventory(link),
      'channels': <String>[],
      'bulletins': <String>[],
      'receipts': <String>[],
    });
  }

  Future<void> refreshImageTransfers() async {
    for (final link in _links.values.toList()) {
      await _requestImages(link, link.availableImages.toList());
      await _sendImageInventory(link);
    }
  }

  Future<void> _requestImages(_Link link, List<String> available) async {
    _imageDownloads.removeWhere(
      (_, v) =>
          _clock.elapsedMilliseconds - v.started > 120000 ||
          !_links.containsKey(v.peerId),
    );
    void count(String key) {
      final experiment = envelopeExperiment;
      if (experiment == null) return;
      experiment.stats[key] = (experiment.stats[key] ?? 0) + 1;
    }

    if (!await _imagesAllowed(link)) {
      if (available.isNotEmpty) count('imageSkipNotAllowed');
      return;
    }
    if (!_running || link.closed || !identical(_links[link.peerId], link)) {
      return;
    }
    for (final hash in available) {
      if (_imageDownloads.length >= 4 ||
          _imageDownloads.values.where((v) => v.peerId == link.peerId).length >=
              2) {
        count('imageSkipBusy');
        break;
      }
      final image = _referencedImage(hash)?.$1;
      if (image == null) {
        count('imageSkipUnreferenced');
        continue;
      }
      if (_media.has(hash)) {
        count('imageSkipAlreadyHeld');
        continue;
      }
      if (_imageDownloads.containsKey(hash)) {
        count('imageSkipInFlight');
        continue;
      }
      count('imageRequestsSent');
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
    if (!link.modern || link.transport == PeerTransport.bluetooth) return;
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
    final reference = _referencedImage(hash);
    if (reference == null || offset >= reference.$1.bytes) return;
    if (!reference.$2 && !await _imagesAllowed(link)) return;
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
        if (envelopeExperiment case final experiment?) {
          experiment.stats['imageFetchesCompleted'] =
              experiment.stats['imageFetchesCompleted']! + 1;
          if (experiment.fetchedImages.length >= 4096) {
            experiment.fetchedImages.removeAt(0);
          }
          experiment.fetchedImages.add(hash);
        }
        if (_referencedImage(hash) == null) {
          await _pruneImages();
          return;
        }
        _queueGossip(const [], announceImages: true);
        _notify();
      } else {
        await _send(link, {
          'type': 'mediaWant',
          'hash': hash,
          'offset': pending.data.length,
        });
      }
    } on FormatException {
      _imageDownloads.remove(hash);
      _discardPublisherObject(link, 'invalid_image');
    } on FileSystemException {
      _imageDownloads.remove(hash);
      _lastError = 'image_storage_failed';
      _notify();
    }
  }
}
