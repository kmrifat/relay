import 'package:meta/meta.dart';

/// A hybrid logical clock timestamp: wall-clock milliseconds, a counter for
/// events within the same millisecond, and the device that made it.
///
/// Serialised as `<ms:15>-<counter:5>-<node>`, so string order is time order
/// and ties break by device id. Every op in the op log carries one; the
/// newest timestamp wins a field (last-writer-wins).
@immutable
class Hlc implements Comparable<Hlc> {
  const Hlc(this.millis, this.counter, this.node);

  final int millis;
  final int counter;
  final String node;

  static Hlc zero(String node) => Hlc(0, 0, node);

  factory Hlc.parse(String s) {
    final parts = s.split('-');
    if (parts.length < 3) throw FormatException('Bad HLC', s);
    return Hlc(
      int.parse(parts[0]),
      int.parse(parts[1]),
      parts.sublist(2).join('-'),
    );
  }

  @override
  String toString() =>
      '${millis.toString().padLeft(15, '0')}-'
      '${counter.toString().padLeft(5, '0')}-$node';

  @override
  int compareTo(Hlc other) => toString().compareTo(other.toString());

  @override
  bool operator ==(Object other) => other is Hlc && toString() == other.toString();

  @override
  int get hashCode => toString().hashCode;
}

/// Hands out increasing [Hlc] timestamps for one device and folds in
/// timestamps received from other devices.
class HlcClock {
  HlcClock(this.node, {int Function()? wallClock})
    : _wall = wallClock ?? (() => DateTime.now().millisecondsSinceEpoch),
      _last = Hlc.zero(node);

  final String node;
  final int Function() _wall;
  Hlc _last;

  Hlc get last => _last;

  /// A timestamp for a local event.
  Hlc now() {
    final wall = _wall();
    if (wall > _last.millis) {
      _last = Hlc(wall, 0, node);
    } else {
      _last = Hlc(_last.millis, _last.counter + 1, node);
    }
    return _last;
  }

  /// Advances the clock past a timestamp seen from another device.
  void receive(Hlc remote) {
    final wall = _wall();
    final maxMs = [wall, _last.millis, remote.millis].reduce((a, b) => a > b ? a : b);
    int counter;
    if (maxMs == _last.millis && maxMs == remote.millis) {
      counter = (_last.counter > remote.counter ? _last.counter : remote.counter) + 1;
    } else if (maxMs == _last.millis) {
      counter = _last.counter + 1;
    } else if (maxMs == remote.millis) {
      counter = remote.counter + 1;
    } else {
      counter = 0;
    }
    _last = Hlc(maxMs, counter, node);
  }
}
