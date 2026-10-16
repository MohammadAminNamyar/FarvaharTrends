import 'media_store.dart';

/// References from admitted public news only. Pending publications never enter
/// this index. Work is paid on admission/eviction, not for every advertised hash.
class ImageReferenceIndex {
  final Map<String, NewsImage> _byBulletin = {};
  final Map<String, _References> _byHash = {};

  Iterable<String> get hashes => _byHash.keys;
  Iterable<String> get localHashes =>
      _byHash.entries.where((e) => e.value.local.isNotEmpty).map((e) => e.key);

  void put(String id, NewsImage? image, {required bool local}) {
    remove(id);
    if (image == null) return;
    _byBulletin[id] = image;
    final refs = _byHash.putIfAbsent(image.hash, _References.new);
    refs.images[id] = image;
    if (local) refs.local.add(id);
  }

  void setLocal(String id, bool local) {
    final image = _byBulletin[id];
    if (image == null) return;
    final refs = _byHash[image.hash]!;
    if (local) {
      refs.local.add(id);
    } else {
      refs.local.remove(id);
    }
  }

  (NewsImage, bool)? lookup(String hash) {
    final refs = _byHash[hash];
    if (refs == null) return null;
    if (refs.local.isNotEmpty) return (refs.images[refs.local.first]!, true);
    return (refs.images.values.first, false);
  }

  void remove(String id) {
    final image = _byBulletin.remove(id);
    if (image == null) return;
    final refs = _byHash[image.hash]!;
    refs.images.remove(id);
    refs.local.remove(id);
    if (refs.images.isEmpty) _byHash.remove(image.hash);
  }

  void replaceWith(ImageReferenceIndex other) {
    _byBulletin.clear();
    _byHash.clear();
    for (final entry in other._byBulletin.entries) {
      put(
        entry.key,
        entry.value,
        local: other._byHash[entry.value.hash]!.local.contains(entry.key),
      );
    }
  }
}

class _References {
  final Map<String, NewsImage> images = {};
  final Set<String> local = {};
}
