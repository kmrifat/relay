import 'dart:math';

const _alphabet = '0123456789abcdefghjkmnpqrstvwxyz'; // Crockford base32, lower case

final Random _random = Random.secure();

/// A sortable id: 10 chars of millisecond time, then 12 random chars.
/// Ids made later sort after ids made earlier, which keeps lists stable.
String newId([DateTime? now]) {
  var ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final time = List.filled(10, '0');
  for (var i = 9; i >= 0; i--) {
    time[i] = _alphabet[ms % 32];
    ms ~/= 32;
  }
  final rand = List.generate(12, (_) => _alphabet[_random.nextInt(32)]);
  return time.join() + rand.join();
}

/// A short random token, for device ids and socket auth.
String newToken([int length = 24]) =>
    List.generate(length, (_) => _alphabet[_random.nextInt(32)]).join();
