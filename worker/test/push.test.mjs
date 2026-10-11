import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, verify } from 'node:crypto';
import { createServer } from 'node:http';
import { after, before, test } from 'node:test';
import { start } from './serve.mjs';

// A fake APNs: checks the ES256 provider token and records pushes.
const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
const p8 = privateKey.export({ type: 'pkcs8', format: 'pem' });
const pushes = [];
const apns = createServer((req, res) => {
  let body = '';
  req.on('data', (d) => (body += d));
  req.on('end', () => {
    const jwt = (req.headers.authorization || '').replace(/^bearer /, '');
    const [h, p, sig] = jwt.split('.');
    const ok = verify('sha256', Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(sig, 'base64url'));
    const head = JSON.parse(Buffer.from(h, 'base64url'));
    const claims = JSON.parse(Buffer.from(p, 'base64url'));
    const token = req.url.split('/').pop();
    if (token === 'deadbeefdeadbeefdeadbeefdeadbeef') {
      res.writeHead(410);
      return res.end('{"reason":"Unregistered"}');
    }
    pushes.push({ ok, head, claims, topic: req.headers['apns-topic'], type: req.headers['apns-push-type'], token, body: JSON.parse(body) });
    res.writeHead(ok ? 200 : 403);
    res.end();
  });
});

let mf, base;
const team = 'teampush1';
const hash = (s) => createHash('sha256').update(s).digest('hex');
const call = (path, { token = 'k1', method = 'GET', body } = {}) =>
  fetch(`${base}/v1/${path}`, { method, body: body && JSON.stringify(body), headers: token ? { authorization: `Bearer ${token}` } : {} });

before(async () => {
  await new Promise((r) => apns.listen(0, '127.0.0.1', r));
  mf = start('setup', 0, { APNS_HOST: `http://127.0.0.1:${apns.address().port}` });
  base = (await mf.ready).href.replace(/\/$/, '');
  await call('setup', { token: 'setup', method: 'POST', body: { teamId: team, epoch: 1, hash: hash('k1') } });
});
after(async () => {
  await mf.dispose();
  apns.close();
});

test('push: needs config, a registration, members only; signs for APNs', async () => {
  assert.equal((await call('push', { method: 'POST', body: { to: 'phone1', title: 'x' } })).status, 501);
  assert.equal((await call('push/config', { method: 'POST', body: { keyId: 'BAD', teamId: 'X', bundleId: 'b', p8 } })).status, 400);
  assert.equal((await call('push/config', { method: 'POST', body: { keyId: 'ABCDE12345', teamId: 'TEAM123456', bundleId: 'com.binarycastle.relay', p8: 'nope' } })).status, 400);
  assert.equal((await call('push/config', { token: 'wrong', method: 'POST', body: {} })).status, 401);
  assert.equal((await call('push/config', { method: 'POST', body: { keyId: 'ABCDE12345', teamId: 'TEAM123456', bundleId: 'com.binarycastle.relay', p8 } })).status, 200);
  const status = await (await call('push/config')).json();
  assert.equal(status.configured, true);
  assert.equal(status.p8, undefined); // never handed back

  assert.equal((await call('push', { method: 'POST', body: { to: 'phone1', title: 'x' } })).status, 404);
  assert.equal((await call('push/register', { method: 'POST', body: { device: 'phone1', token: 'zz' } })).status, 400);
  const tok = 'a1'.repeat(32);
  assert.equal((await call('push/register', { method: 'POST', body: { device: 'phone1', token: tok, sandbox: true } })).status, 200);

  const res = await call('push', { method: 'POST', body: { to: 'phone1', title: 'TM-12 needs your OK', body: 'Claude Code wants to run npm test', data: { taskId: 't1' } } });
  assert.equal(res.status, 200);
  const p = pushes.at(-1);
  assert.equal(p.ok, true, 'ES256 signature verifies with the public key');
  assert.deepEqual(p.head, { alg: 'ES256', kid: 'ABCDE12345' });
  assert.equal(p.claims.iss, 'TEAM123456');
  assert.equal(p.topic, 'com.binarycastle.relay');
  assert.equal(p.type, 'alert');
  assert.equal(p.token, tok);
  assert.equal(p.body.aps.alert.title, 'TM-12 needs your OK');
  assert.deepEqual(p.body.relay, { taskId: 't1' });

  // A token Apple says is gone is forgotten.
  await call('push/register', { method: 'POST', body: { device: 'phone2', token: 'deadbeef'.repeat(4) } });
  assert.equal((await call('push', { method: 'POST', body: { to: 'phone2', title: 'x' } })).status, 502);
  assert.equal((await call('push', { method: 'POST', body: { to: 'phone2', title: 'x' } })).status, 404);
});
