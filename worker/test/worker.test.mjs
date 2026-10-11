import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { after, before, test } from 'node:test';
import { start } from './serve.mjs';

const team = 'team1234';
const root = `relay/${team}`;
const hash = (s) => createHash('sha256').update(s).digest('hex');
let mf, base;

before(async () => {
  mf = start('setup-secret');
  base = (await mf.ready).href.replace(/\/$/, '');
});
after(() => mf.dispose());

const call = (path, { token, method = 'GET', body, headers = {} } = {}) =>
  fetch(`${base}/v1/${path}`, {
    method,
    body,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
  });
const o = (key) => `o/${encodeURIComponent(key)}`;

test('setup is single use and needs the setup token', async () => {
  assert.equal((await (await call('health')).json()).configured, false);
  assert.equal((await call(o(`${root}/team.json`), { token: 'k1' })).status, 409);
  const body = JSON.stringify({ teamId: team, epoch: 1, hash: hash('k1') });
  assert.equal((await call('setup', { method: 'POST', token: 'wrong', body })).status, 401);
  assert.equal((await call('setup', { method: 'POST', token: 'setup-secret', body })).status, 200);
  assert.equal((await call('setup', { method: 'POST', token: 'setup-secret', body })).status, 409);
  assert.equal((await (await call('health')).json()).configured, true);
});

test('objects: auth, create-only, compare-and-swap, list with start-after', async () => {
  const key = `${root}/ops/a/000000000001.op`;
  assert.equal((await call(o(key), { method: 'PUT', body: 'x' })).status, 401);
  assert.equal((await call(o(key), { token: 'nope', method: 'PUT', body: 'x' })).status, 401);
  assert.equal((await call(o('relay/other/team.json'), { token: 'k1', method: 'PUT', body: 'x' })).status, 400);
  assert.equal((await call(o(`${root}/../x`), { token: 'k1' })).status, 400);

  const first = await call(o(key), { token: 'k1', method: 'PUT', body: 'one', headers: { 'if-none-match': '*' } });
  assert.equal(first.status, 200);
  const again = await call(o(key), { token: 'k1', method: 'PUT', body: 'two', headers: { 'if-none-match': '*' } });
  assert.equal(again.status, 412);
  const got = await call(o(key), { token: 'k1' });
  assert.equal(await got.text(), 'one');
  const etag = got.headers.get('etag');
  assert.equal(etag, first.headers.get('etag'));
  assert.equal((await call(o(key), { token: 'k1', method: 'PUT', body: 'z', headers: { 'if-match': '"nope"' } })).status, 412);
  assert.equal((await call(o(key), { token: 'k1', method: 'PUT', body: 'three', headers: { 'if-match': etag } })).status, 200);

  await call(o(`${root}/ops/a/000000000002.op`), { token: 'k1', method: 'PUT', body: '2' });
  await call(o(`${root}/ops/b/000000000001.op`), { token: 'k1', method: 'PUT', body: 'b' });
  const list = await (await call(`list?prefix=${encodeURIComponent(`${root}/ops/a/`)}&start-after=${encodeURIComponent(key)}`, { token: 'k1' })).json();
  assert.deepEqual(list.objects.map((x) => x.key), [`${root}/ops/a/000000000002.op`]);
  assert.equal(list.truncated, false);
  assert.equal((await call(`list?prefix=relay/`, { token: 'k1' })).status, 400);
  assert.equal((await call(o(`${root}/nothing`), { token: 'k1' })).status, 404);
});

test('invites open without a key, by their id only', async () => {
  const inv = `${root}/invites/abc123.inv`;
  await call(o(inv), { token: 'k1', method: 'PUT', body: 'sealed' });
  assert.equal(await (await call(o(inv))).text(), 'sealed');
  assert.equal((await call(`list?prefix=${encodeURIComponent(`${root}/invites/`)}`)).status, 401);
  assert.equal((await call(o(inv), { method: 'DELETE' })).status, 204);
  assert.equal((await call(o(inv))).status, 404);
});

test('a new epoch swaps the key; the old one may only catch up; live sockets on it close', async () => {
  const ws = await openSocket('dev-old', 'k1');
  const closed = new Promise((r) => ws.addEventListener('close', (e) => r(e.code)));
  await call(o(`${root}/team.json`), { token: 'k1', method: 'PUT', body: '{"epoch":1}' });
  await call(o(`${root}/keys/2/dev-a.key`), { token: 'k1', method: 'PUT', body: 'wrapped' });
  const etag = (await call(o(`${root}/team.json`), { token: 'k1' })).headers.get('etag');
  const bad = await call('epoch', { token: 'k1', method: 'POST', body: JSON.stringify({ epoch: 2, hash: hash('k2'), teamJson: '{"epoch":2}', ifMatch: '"stale"' }) });
  assert.equal(bad.status, 412);
  const ok = await call('epoch', { token: 'k1', method: 'POST', body: JSON.stringify({ epoch: 2, hash: hash('k2'), teamJson: '{"epoch":2}', ifMatch: etag }) });
  assert.equal(ok.status, 204);
  assert.equal(await closed, 4001);

  assert.equal(await (await call(o(`${root}/team.json`), { token: 'k1' })).text(), '{"epoch":2}');
  assert.equal(await (await call(o(`${root}/keys/2/dev-a.key`), { token: 'k1' })).text(), 'wrapped');
  assert.equal((await call(o(`${root}/ops/a/000000000001.op`), { token: 'k1' })).status, 401);
  assert.equal((await call(o(`${root}/ops/x/1.op`), { token: 'k1', method: 'PUT', body: 'x' })).status, 401);
  assert.equal((await call(o(`${root}/ops/a/000000000001.op`), { token: 'k2' })).status, 200);
});

test('the room relays messages between devices and reports presence', async () => {
  const a = await openSocket('dev-a', 'k2');
  const aMsgs = collect(a);
  const b = await openSocket('dev-b', 'k2');
  const bMsgs = collect(b);
  await until(() => aMsgs.some((m) => m.t === 'presence' && m.devices.includes('dev-b')));
  a.send(JSON.stringify({ t: 'poke', from: 'dev-a' }));
  await until(() => bMsgs.some((m) => m.t === 'poke'));
  assert.ok(!aMsgs.some((m) => m.t === 'poke'), 'the sender does not get its own message');
  b.close(1000);
  await until(() => aMsgs.some((m) => m.t === 'presence' && !m.devices.includes('dev-b')));
  a.close(1000);
});

async function openSocket(device, token) {
  const res = await mf.dispatchFetch(`${base}/v1/ws?device=${device}`, {
    headers: { upgrade: 'websocket', authorization: `Bearer ${token}` },
  });
  assert.equal(res.status, 101);
  const ws = res.webSocket;
  ws.accept();
  return ws;
}

function collect(ws) {
  const out = [];
  ws.addEventListener('message', (e) => out.push(JSON.parse(e.data)));
  return out;
}

async function until(f, ms = 3000) {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error('timed out');
    await new Promise((r) => setTimeout(r, 20));
  }
}
