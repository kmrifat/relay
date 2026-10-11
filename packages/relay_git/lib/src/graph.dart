/// Lays out a commit graph in lanes, like JetBrains' Git log.
///
/// Input is commits newest first, each with its parent hashes. Output is,
/// per row, the lane of the commit's dot and the line segments to draw
/// between this row and the next one.
class GraphRow {
  GraphRow(this.lane, this.segments, this.laneCount);

  /// Column of this commit's dot.
  final int lane;

  /// Lines from this row (at `from` lane) down to the next row (at `to`).
  final List<(int from, int to, int colorLane)> segments;

  final int laneCount;

  Map<String, Object?> toJson() => {
    'lane': lane,
    'segments': [for (final (f, t, c) in segments) [f, t, c]],
    'lanes': laneCount,
  };
}

List<GraphRow> layoutGraph(List<(String hash, List<String> parents)> commits) {
  // lanes[i] = hash the lane is waiting for (the next commit drawn in it).
  final lanes = <String?>[];
  final laneColor = <int>[];
  var nextColor = 0;
  final rows = <GraphRow>[];

  for (final (hash, parents) in commits) {
    var lane = lanes.indexOf(hash);
    if (lane == -1) {
      lane = lanes.indexOf(null);
      if (lane == -1) {
        lanes.add(hash);
        laneColor.add(nextColor++);
        lane = lanes.length - 1;
      } else {
        lanes[lane] = hash;
        laneColor[lane] = nextColor++;
      }
    }
    // Other lanes also waiting for this commit merge into it here.
    final merging = <int>[];
    for (var i = 0; i < lanes.length; i++) {
      if (i != lane && lanes[i] == hash) merging.add(i);
    }

    final before = List<String?>.of(lanes);
    final colorBefore = List<int>.of(laneColor);
    for (final i in merging) {
      lanes[i] = null;
    }

    // First parent continues in this lane; others take free or new lanes.
    if (parents.isEmpty) {
      lanes[lane] = null;
    } else {
      lanes[lane] = parents.first;
      for (final parent in parents.skip(1)) {
        if (lanes.contains(parent)) continue;
        final free = lanes.indexOf(null);
        if (free == -1) {
          lanes.add(parent);
          laneColor.add(nextColor++);
        } else {
          lanes[free] = parent;
          laneColor[free] = nextColor++;
        }
      }
    }

    final segments = <(int, int, int)>[];
    for (var i = 0; i < before.length; i++) {
      final h = before[i];
      if (h == null) continue;
      if (i == lane || merging.contains(i)) continue;
      // A lane passing straight through.
      final to = lanes.indexOf(h);
      segments.add((i, to == -1 ? i : to, colorBefore[i]));
    }
    for (final parent in parents) {
      final to = lanes.indexOf(parent);
      if (to != -1) segments.add((lane, to, laneColor[to == lane ? lane : to]));
    }

    while (lanes.isNotEmpty && lanes.last == null) {
      lanes.removeLast();
      laneColor.removeLast();
    }
    final count = [before.length, lanes.length, lane + 1].reduce((a, b) => a > b ? a : b);
    rows.add(GraphRow(lane, segments, count));
  }
  return rows;
}
