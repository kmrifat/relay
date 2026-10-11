import 'dart:convert';

import 'package:relay_sync/relay_sync.dart';
import 'package:test/test.dart';

void main() {
  final key = RelayCrypto.newKey();
  Future<List<int>> seal(String objectKey, [int epoch = 1]) => RelayCrypto.seal(
    key: key,
    teamId: 'team1',
    type: EnvelopeType.ops,
    epoch: epoch,
    objectKey: objectKey,
    plain: utf8.encode('[{"op":1}]'),
  );

  test('envelope round trip and epoch header', () async {
    final sealed = await seal('relay/team1/ops/a/000000000001.op', 3);
    expect(RelayCrypto.epochOf(sealed), 3);
    final plain = await RelayCrypto.open(key: key, teamId: 'team1', type: EnvelopeType.ops, objectKey: 'relay/team1/ops/a/000000000001.op', bytes: sealed);
    expect(utf8.decode(plain), '[{"op":1}]');
  });

  test('tampered, wrong key, moved object, wrong team or type all fail', () async {
    const k = 'relay/team1/ops/a/000000000001.op';
    final sealed = await seal(k);
    final tampered = [...sealed]..[40] ^= 1;
    Future<void> fails(Future<Object?> f) => expectLater(f, throwsA(isA<DecryptionFailed>()));
    await fails(RelayCrypto.open(key: key, teamId: 'team1', type: EnvelopeType.ops, objectKey: k, bytes: tampered));
    await fails(RelayCrypto.open(key: RelayCrypto.newKey(), teamId: 'team1', type: EnvelopeType.ops, objectKey: k, bytes: sealed));
    await fails(RelayCrypto.open(key: key, teamId: 'team1', type: EnvelopeType.ops, objectKey: 'relay/team1/ops/a/000000000002.op', bytes: sealed));
    await fails(RelayCrypto.open(key: key, teamId: 'team2', type: EnvelopeType.ops, objectKey: k, bytes: sealed));
    await fails(RelayCrypto.open(key: key, teamId: 'team1', type: EnvelopeType.invite, objectKey: k, bytes: sealed));
    await fails(RelayCrypto.open(key: key, teamId: 'team1', type: EnvelopeType.ops, objectKey: k, bytes: utf8.encode('not an envelope at all, no no no no no no no no')));
  });

  test('key wrap opens only for the intended device', () async {
    final alice = RelayCrypto.randomBytes(32);
    final bob = RelayCrypto.randomBytes(32);
    final wrapped = await RelayCrypto.wrapFor(await RelayCrypto.publicKey(alice), key);
    expect(await RelayCrypto.unwrap(alice, wrapped), key);
    await expectLater(RelayCrypto.unwrap(bob, wrapped), throwsA(isA<DecryptionFailed>()));
  });

  test('invite keys depend on secret and team', () async {
    final s = RelayCrypto.randomBytes(32);
    expect(await RelayCrypto.inviteKey(s, 't1'), await RelayCrypto.inviteKey(s, 't1'));
    expect(await RelayCrypto.inviteKey(s, 't1'), isNot(await RelayCrypto.inviteKey(s, 't2')));
  });
}
