import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Thrown when bytes don't decrypt: wrong key, tampered, or not ours.
class DecryptionFailed implements Exception {
  DecryptionFailed(this.message);
  final String message;
  @override
  String toString() => 'DecryptionFailed: $message';
}

/// What an envelope holds. Part of the authenticated data, so an object of
/// one type can't be passed off as another.
enum EnvelopeType { ops(1), keywrap(2), invite(3), live(4), file(5); const EnvelopeType(this.code); final int code; }

/// Relay's encryption (docs/format/sync.md §2).
///
/// - Data: XChaCha20-Poly1305 with a random 24-byte nonce per object.
/// - Envelope: `"RLY1" | version u8 | type u8 | epoch u32 BE | nonce(24) |
///   ciphertext+tag(16)`. The associated data binds the team, type, epoch
///   and the object's storage key, so an object can't be moved to another
///   key, team or epoch without failing to open.
/// - Key wrap: an X25519 sealed box (ephemeral key, HKDF-SHA256,
///   XChaCha20-Poly1305) per device public key.
/// - Invites: a key derived with HKDF-SHA256 from a 32-byte secret that
///   travels only in the invite code.
class RelayCrypto {
  static final _aead = Xchacha20.poly1305Aead();
  static final _x25519 = X25519();
  static final _random = Random.secure();
  static const _magic = [0x52, 0x4C, 0x59, 0x31]; // RLY1
  static const formatVersion = 1;

  static Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  /// A new 256-bit team key.
  static Uint8List newKey() => randomBytes(32);

  static List<int> _aad(String teamId, EnvelopeType type, int epoch, String objectKey) =>
      utf8.encode('relay/v$formatVersion|$teamId|${type.code}|$epoch|$objectKey');

  /// Encrypts [plain] for storage at [objectKey].
  static Future<Uint8List> seal({
    required List<int> key,
    required String teamId,
    required EnvelopeType type,
    required int epoch,
    required String objectKey,
    required List<int> plain,
  }) async {
    final nonce = randomBytes(24);
    final box = await _aead.encrypt(plain, secretKey: SecretKey(key), nonce: nonce, aad: _aad(teamId, type, epoch, objectKey));
    final b = BytesBuilder(copy: false)
      ..add(_magic)
      ..addByte(formatVersion)
      ..addByte(type.code)
      ..add([epoch >> 24 & 0xff, epoch >> 16 & 0xff, epoch >> 8 & 0xff, epoch & 0xff])
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return b.takeBytes();
  }

  /// The epoch an envelope was sealed with (to pick the key), without
  /// opening it. Null when the bytes aren't an envelope.
  static int? epochOf(List<int> bytes) {
    if (bytes.length < 10 + 24 + 16) return null;
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _magic[i]) return null;
    }
    return bytes[6] << 24 | bytes[7] << 16 | bytes[8] << 8 | bytes[9];
  }

  /// Opens an envelope. Throws [DecryptionFailed] if anything is off.
  static Future<Uint8List> open({
    required List<int> key,
    required String teamId,
    required EnvelopeType type,
    required String objectKey,
    required List<int> bytes,
  }) async {
    final epoch = epochOf(bytes);
    if (epoch == null) throw DecryptionFailed('not a Relay envelope');
    if (bytes[4] != formatVersion) throw DecryptionFailed('unknown format version ${bytes[4]}');
    if (bytes[5] != type.code) throw DecryptionFailed('expected a ${type.name} envelope');
    final nonce = bytes.sublist(10, 34);
    final body = bytes.sublist(34);
    final box = SecretBox(body.sublist(0, body.length - 16), nonce: nonce, mac: Mac(body.sublist(body.length - 16)));
    try {
      final plain = await _aead.decrypt(box, secretKey: SecretKey(key), aad: _aad(teamId, type, epoch, objectKey));
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw DecryptionFailed('authentication failed (wrong key or tampered)');
    }
  }

  // ------------------------------------------------------------ device keys

  /// A device's X25519 key pair from a 32-byte seed.
  static Future<SimpleKeyPair> deviceKeyPair(List<int> seed) => _x25519.newKeyPairFromSeed(seed);

  static Future<Uint8List> publicKey(List<int> seed) async {
    final kp = await deviceKeyPair(seed);
    return Uint8List.fromList((await kp.extractPublicKey()).bytes);
  }

  static Future<SecretKey> _wrapKey(List<int> shared, List<int> ephPub, List<int> recipientPub) => Hkdf(hmac: Hmac.sha256(), outputLength: 32)
      .deriveKey(secretKey: SecretKey(shared), nonce: [...ephPub, ...recipientPub], info: utf8.encode('relay/v1 keywrap'));

  /// Encrypts [secret] so only the holder of [recipientPublicKey]'s private
  /// key can read it: `ephemeral pub(32) | nonce(24) | ciphertext+tag`.
  static Future<Uint8List> wrapFor(List<int> recipientPublicKey, List<int> secret) async {
    final eph = await _x25519.newKeyPair();
    final ephPub = (await eph.extractPublicKey()).bytes;
    final shared = await _x25519.sharedSecretKey(keyPair: eph, remotePublicKey: SimplePublicKey(recipientPublicKey, type: KeyPairType.x25519));
    final k = await _wrapKey(await shared.extractBytes(), ephPub, recipientPublicKey);
    final nonce = randomBytes(24);
    final box = await _aead.encrypt(secret, secretKey: k, nonce: nonce);
    return Uint8List.fromList([...ephPub, ...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Opens a [wrapFor] box with this device's seed.
  static Future<Uint8List> unwrap(List<int> deviceSeed, List<int> wrapped) async {
    if (wrapped.length < 32 + 24 + 16) throw DecryptionFailed('wrapped key too short');
    final kp = await deviceKeyPair(deviceSeed);
    final myPub = (await kp.extractPublicKey()).bytes;
    final ephPub = wrapped.sublist(0, 32);
    final nonce = wrapped.sublist(32, 56);
    final body = wrapped.sublist(56);
    final shared = await _x25519.sharedSecretKey(keyPair: kp, remotePublicKey: SimplePublicKey(ephPub, type: KeyPairType.x25519));
    final k = await _wrapKey(await shared.extractBytes(), ephPub, myPub);
    try {
      return Uint8List.fromList(await _aead.decrypt(
        SecretBox(body.sublist(0, body.length - 16), nonce: nonce, mac: Mac(body.sublist(body.length - 16))),
        secretKey: k,
      ));
    } on SecretBoxAuthenticationError {
      throw DecryptionFailed('this key was not wrapped for this device');
    }
  }

  // ------------------------------------------------------------ invites

  /// The key that seals an invite, from the secret in the invite code.
  static Future<Uint8List> inviteKey(List<int> secret, String teamId) async {
    final k = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: SecretKey(secret), nonce: utf8.encode(teamId), info: utf8.encode('relay/v1 invite'));
    return Uint8List.fromList(await k.extractBytes());
  }

  // ------------------------------------------------------------ worker

  /// The bearer token for the team's Worker in [teamKey]'s epoch. Derived
  /// one way, so the Worker (which keeps only its SHA-256) learns nothing
  /// about the team key.
  static Future<String> workerToken(List<int> teamKey, String teamId) async {
    final k = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: SecretKey(teamKey), nonce: utf8.encode(teamId), info: utf8.encode('relay/v1 worker'));
    return b64(await k.extractBytes());
  }

  /// What the Worker stores for a token: hex SHA-256 of its text.
  static Future<String> tokenHash(String token) async {
    final h = await Sha256().hash(utf8.encode(token));
    return h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
Uint8List unb64(String s) => base64Url.decode(base64Url.normalize(s));
