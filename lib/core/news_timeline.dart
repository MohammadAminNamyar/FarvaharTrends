/// Newest first, independent of delivery order or this phone's clock.
///
/// A writer's signed sequence orders their own posts. Normalize clock rollback
/// within each writer's retained posts, then merge writers by signed UTC time.
/// This creates a total order; a pairwise 'sequence OR time' comparator can form
/// cycles. Concurrent writers with inaccurate clocks cannot establish true
/// physical chronology without a shared trusted clock or coordination.
List<Map<String, dynamic>> orderNews(Iterable<Map<String, dynamic>> values) {
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final item in values) {
    final key = '${item['channelId']}|${item['sourceId']}';
    groups.putIfAbsent(key, () => []).add(item);
  }
  final ranked = <({Map<String, dynamic> news, int wall})>[];
  for (final group in groups.values) {
    group.sort((a, b) {
      final sequence = _int(a['sequence']).compareTo(_int(b['sequence']));
      if (sequence != 0) return sequence;
      final time = _int(a['createdAtMs']).compareTo(_int(b['createdAtMs']));
      return time != 0 ? time : '${a['id']}'.compareTo('${b['id']}');
    });
    var wall = 0;
    for (final item in group) {
      final sent = _int(item['createdAtMs']);
      if (sent > wall) wall = sent;
      ranked.add((news: item, wall: wall));
    }
  }
  ranked.sort((a, b) {
    final time = b.wall.compareTo(a.wall);
    if (time != 0) return time;
    final writer = '${a.news['sourceId']}'.compareTo('${b.news['sourceId']}');
    if (writer != 0) return writer;
    final channel = '${a.news['channelId']}'.compareTo(
      '${b.news['channelId']}',
    );
    if (channel != 0) return channel;
    final sequence = _int(b.news['sequence'])
        .compareTo(_int(a.news['sequence']));
    return sequence != 0
        ? sequence
        : '${a.news['id']}'.compareTo('${b.news['id']}');
  });
  return ranked.map((entry) => entry.news).toList();
}

int _int(dynamic value) => value is int ? value : 0;
