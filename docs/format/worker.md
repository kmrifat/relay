# Team Worker (v1)

The team Worker is optional and runs in the team's own Cloudflare account. It sits in front of the team's R2 bucket and adds three things to [sync](sync.md):

- **No shared storage keys.** Members authenticate with a token derived from the team key. Invite codes carry only the Worker's URL.
- **Revoke cuts storage access.** A removed device's token stops working the moment the key rotates.
- **Live.** A WebSocket room per team relays pokes ("pull now"), agent run steps as they happen, and who is online.

Sources:

- Worker: `worker/src/index.js`, a single file with no dependencies, embedded in `relay` by `tool/gen_worker_source.sh`.
- Deploy: `packages/relay_sync/lib/src/deploy.dart`.
- Live link: `packages/relay_daemon/lib/src/live.dart`.

## 1. Deploy

From the app, choose **Settings → Team → Create a team → Cloudflare Worker**. From the CLI:

```bash
CLOUDFLARE_API_TOKEN=… relay worker deploy --account <account id> --team binarycastle
```

The token needs *Account → Workers Scripts: Edit* and *Workers R2 Storage: Edit*. It is used for this call and never stored. The deploy goes through the Cloudflare API directly, with no wrangler:

1. `POST r2/buckets {name: relay-<team>}`. A bucket that already exists in the account is reused.
2. `PUT workers/scripts/relay-<team>`, multipart:
   - `metadata`: `main_module: index.js`, `compatibility_date`, and bindings `BUCKET` (r2_bucket), `ROOM` (durable_object_namespace, class `TeamRoom`) and `SETUP_TOKEN` (secret_text, 32 random bytes).
   - The first deploy also sends the migration `{new_tag: v1, new_sqlite_classes: [TeamRoom]}`.
   - `index.js`: the Worker source.
3. `GET workers/subdomain`. A fresh account without a workers.dev subdomain gets `relay-xxxxxx`.
4. `POST workers/scripts/relay-<team>/subdomain {enabled: true}`.
5. Poll `https://relay-<team>.<sub>.workers.dev/v1/health` until it answers.

Then `SyncEngine.createTeam` calls `POST /v1/setup` with the setup token. That binds the Worker to the team id and the epoch-1 token hash. The setup token works once; it is not kept and not in invites.

## 2. Access

- **Token:** `HKDF-SHA256(teamKey[epoch], salt = teamId, info = "relay/v1 worker")`, base64url, sent as `Authorization: Bearer …`.
- **What the Worker stores:** `{teamId, epoch, hashes: {epoch: sha256hex(token)}}` in its Durable Object. It never sees a team key; the derivation is one way.

| Caller | May |
|---|---|
| anyone | `GET /v1/health`; `GET`/`DELETE` one `invites/<id>.inv`. The id is random and only in the invite code, and the content is sealed with the invite secret |
| current-epoch token | everything below |
| older-epoch token | `GET team.json` and `GET keys/…` only, enough to pick up the new key if it was wrapped for this device. A removed device finds none |

Keys must sit under `relay/<teamId>/`, with no `.`/`..` segments.

## 3. HTTP API

| Request | Does |
|---|---|
| `GET /v1/health` | `{ok, version, configured}` |
| `POST /v1/setup` (setup token) | `{teamId, epoch, hash}`, once |
| `GET /v1/o/<key>` | object bytes, `ETag` |
| `PUT /v1/o/<key>` | write. `If-None-Match: *` is create-only and `If-Match` is compare-and-swap; 412 when the condition fails |
| `DELETE /v1/o/<key>` | delete, optionally `If-Match` |
| `GET /v1/list?prefix=&start-after=&cursor=` | `{objects: [{key, etag, size}], truncated, cursor}` |
| `POST /v1/epoch` | a revoke: `{epoch, hash, teamJson, ifMatch}`. It writes team.json if still at `ifMatch` and switches the access token in one step, then closes sockets opened with older keys (code 4001) |
| `GET /v1/ws?device=<id>` | WebSocket into the team room |

Every request is handled by the team's single Durable Object. R2's Workers binding has no create-only put, so conditional writes run inside `blockConcurrencyWhile`, one at a time.

## 4. Live room

The room relays each text message, unchanged, to every other socket. It sends one message of its own, `{t: "presence", devices: [...]}`, whenever someone connects or leaves.

relayd seals everything else: `{t: "sealed", e: base64url(envelope)}`. The envelope has type `live` (4), the current epoch, and object key `live`. Inside:

| `t` | Sent when | Receiver |
|---|---|---|
| `poke` | after a push, and on connect | pulls 250 ms later (debounced) |
| `run` `{runId, events}` | new steps of a run on this device, batched every 100 ms, only while another device is online | imports them (`INSERT OR IGNORE` by run + seq). Its app shows them like a local run's. Ignored for runs owned by the receiver |
| `want` `{runId, after}` | the app opens a teammate's run | the run's device answers with `run` (up to 2,000 events) |

Polling at the sync interval goes on regardless, so a dropped socket only delays things. relayd reconnects with backoff from 1 to 60 s. On close code 4001 it syncs, which picks up the new key or learns it was removed, then reconnects.

## 5. Phones (M8)

**Pairing.** On the Mac, Settings → Team → Pair iPhone (`sync.pairPhone`) makes a code, shown as a QR:

- the code is `relay-pair:` + base64url(`{id, k, mac, macName, person, invite}`);
- `invite` is an ordinary one-time team invite;
- `k` is a fresh 32-byte pairing key that only the Mac (`secrets.json` → `companions`) and the phone (`pairing`) keep.

The phone joins the team with the invite. It publishes its device record with `kind: phone` and `companionOf: <mac>`. Your phone counts as you:

- work it queues runs on the Mac without the sharing switch;
- its notifications are the Mac's.

**Commands.** The phone has no agents. To act, it asks its Mac in the room:

- `{t: "cmd", to, id, pair, body, mac}`, where `body` is `{method, params}` and `mac` is HMAC-SHA256(k, `id|body`);
- the Mac runs the method through its own API and answers `{t: "ack", id, ok, result | error}`.

A teammate holds the team key but not `k`, so it can't pass for your phone. Allowed methods:

- `permissions.answer`
- `comments.post` (answers to agents' questions)
- `runs.start` / `steer` / `stop` / `pause` / `resume`
- `agents.update`

Everything else syncs as data. If the Mac isn't in the room, the phone says so at once.

**Push.** The team's own APNs key (a `.p8` from developer.apple.com) goes into the Durable Object, either with `POST /v1/push/config` from Settings → Team → iPhone push or with `relay team push-setup`. It never comes back out.

- The phone registers its device token with `POST /v1/push/register {device, token, sandbox}`.
- When relayd has a notification (an agent asks, work is ready, a mention) and a paired phone isn't in the room, it calls `POST /v1/push {to, title, body, data}`.
- The Worker signs an ES256 provider token (kept for 50 min) and posts to APNs. It forgets tokens Apple reports as gone (410).
- The text passes through Apple. With **Show task names** off (`pushPreview: false`), it is generic ("An agent needs you").

| Request | Does |
|---|---|
| `POST /v1/push/config` | `{keyId, teamId, bundleId, p8}` |
| `GET /v1/push/config` | `{configured, keyId, bundleId, devices}` (never the key) |
| `POST /v1/push/register` | `{device, token, sandbox}` |
| `POST /v1/push` | `{to, title, body, data}` → APNs; 501 when push isn't set up |

## 6. Tests

- `worker/test/worker.test.mjs` runs on Miniflare. It covers setup, auth, conditional writes, `start-after`, invites, the epoch switch with socket close, relay and presence.
- `relay_sync/test/worker_test.dart`:
  - the full team flow through the Worker;
  - invites carry no credentials;
  - the spent setup token can't take the Worker over;
  - a removed device can't list or write.
- `relay_sync/test/deploy_test.dart`:
  - a fake Cloudflare API and a fresh account;
  - redeploys keep the migration;
  - a bad token says what it needs.
- `worker/test/push.test.mjs`: a fake APNs verifies the ES256 signature with the key's public half, and checks the topic and payload. It also covers config validation, registration, and forgetting a token Apple reports as gone.
- `relay_daemon/test/mobile_test.dart` uses a Worker, a Mac relayd and a phone host:
  - pairing; the board and the Mac's agents reach the phone;
  - a task queued on the phone runs on the Mac;
  - the run streams to the phone, the phone allows the permission, and the task reaches review;
  - comments go through the Mac;
  - a wrong pairing key is refused;
  - push reaches a fake APNs while the phone is away;
  - commands report an offline Mac.
- `relay_daemon/test/live_test.dart`: two relayds.
  - A change arrives by poke with polling set to an hour.
  - A run step reaches the teammate within a second.
  - A revoke closes the removed device's socket.

The Worker tests need `npm ci` in `worker/`; without it they are skipped.
