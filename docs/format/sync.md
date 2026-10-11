# Team sync format (v1)

Relay syncs a team's board through storage the team already owns: the team's own Cloudflare Worker in front of R2 ([worker.md](worker.md), recommended), an R2 or S3-compatible bucket used directly, or a shared folder (Dropbox, a NAS). There is no Relay server and no Relay account. Every object except two small plain records is encrypted on the device before upload, so the storage provider only ever holds ciphertext.

Code: `packages/relay_sync` (format and engine) and `packages/relay_daemon/lib/src/sync_service.dart` (when relayd syncs, and the team lifecycle).

## 1. What syncs

relayd's store is a log of field patches (`Op {hlc, kind, id, patch}`), merged last-writer-wins per field by hybrid logical clock (relay_core, `field_clock`). Sync moves those ops between devices. It doesn't move snapshots.

| Kind | Synced | Why |
|---|---|---|
| project, repo, task, comment, change | yes | the shared board |
| run | yes | teammates see who is running what, where (`deviceId`). Run *events* (the transcript) aren't in the op log. With a Worker they stream live ([worker.md §4](worker.md#4-live-room)) |
| device | yes | each device's name, person, agents and `shareAgents` consent |
| agent, rule | no | binaries, slots, caps and routing are per machine |

Fields that differ per device carry the device in their name, so two devices never fight over them:

- `repo.path@<deviceId>` is that device's checkout path.

Ownership rules (relayd enforces them, not the format):

- A task runs on its `runOn` device. `tasks.create` defaults `runOn` to the creating device and records `createdOn`.
- If a teammate queued the task (`createdOn ≠ runOn`), it runs only while the `runOn` device has **Share my agents** on. Until then the task shows `attention: not-shared`.
- `runs.start` by hand takes the task to the calling device (`runOn := me`). It is refused while another device has an active run of the task.
- Change entries record `deviceId`. Merge and push happen only on that device, because the worktree lives there.
- After a restart, a device recovers only its own interrupted runs.
- Tasks that existed before joining a team are pinned to their device (`runOn`) at create/join time.

## 2. Encryption

- **Team key.** 256 bits, per *epoch*. The key ring `{epoch: key}` lives in each member's `secrets.json` (mode 0600). The epoch starts at 1 and goes up on every revoke.
- **Device key.** X25519, from a 32-byte seed in `secrets.json`. The public key is published in `members/`.
- **Envelope** (ops, invites):
  `"RLY1" | version u8 (=1) | type u8 | epoch u32 BE | nonce (24) | ciphertext + Poly1305 tag (16)`
  - The cipher is XChaCha20-Poly1305 with a random nonce per object.
  - The associated data is `relay/v1|<teamId>|<type>|<epoch>|<object key>`. An object therefore fails to open if it is moved to another key, team, type or epoch.
  - Types: 1 ops, 2 keywrap, 3 invite.
- **Key wrap** (`keys/`): an X25519 sealed box. The layout is `ephemeral pub (32) | nonce (24) | ct + tag`.
  - The key is HKDF-SHA256 over the shared secret, salted with `ephPub | recipientPub`, info `relay/v1 keywrap`.
- **Invite key**: HKDF-SHA256(secret, salt = teamId, info = `relay/v1 invite`).

A batch that fails to open is reported in `sync.status.lastResult.problems` and skipped for good. The other batches still apply (tested by flipping a byte).

## 3. Bucket layout

Everything sits under `relay/<teamId>/`:

| Object | Content | Written |
|---|---|---|
| `team.json` | `{format: 1, teamId, epoch}` (plain) | on create; on revoke with `If-Match` |
| `members/<device>.json` | `{deviceId, publicKey, addedAt}` (plain) | on join; deleted on revoke/leave |
| `keys/<epoch>/<device>.key` | that epoch's team key, wrapped for the device | on create, join, revoke |
| `invites/<id>.inv` | envelope: `{teamName, expiresAt, keyring}` | on invite; deleted when used |
| `ops/<device>/<seq12>.op` | envelope: JSON array of ops | on push, `If-None-Match: *` |

Op objects are immutable and never overwritten. `seq` is per device, zero-padded to 12 digits so keys sort.

## 4. Push and pull

- **Push.** Pending ops go out in batches. Non-synced kinds are marked done without upload.
  - Each batch is written with `If-None-Match: *`. If the slot is taken (for example a reinstalled device reusing its id), the next `seq` is tried.
  - Pending ops survive restarts because they live in SQLite until marked synced.
- **Pull.** relayd lists `ops/`. For each other device it reads objects after that device's cursor (`meta sync.cursor.<device>`), in key order, and applies them with `applyRemote`, which is idempotent by HLC.
  - If an object needs an epoch key this device doesn't have, the pull stops there for that device without moving the cursor.
- **When.**
  - 3 s after a local change to a synced kind.
  - Every `syncIntervalSeconds` (default 30, clamped to 5–3600).
  - On `sync.now`.
  - After every pass, relayd emits `sync.state`.

## 5. Invites, joining, revoking

1. **Invite.** The inviter seals the key ring with a fresh 32-byte secret into `invites/<id>.inv` (expires in 2 days). The code is
   `relay-invite:` + base64url(`{v: 1, team, inv, s: secret, storage}`).
   The code carries the storage credentials, so it must be sent privately. It is single-use: the joiner deletes the invite object.
2. **Join.** The joiner opens the invite, then publishes `members/<me>.json` and `keys/<epoch>/<me>.key` for every epoch it received. It also stores the key ring and storage in `secrets.json`. It then pulls the whole history.
3. **Revoke.**
   - Delete the device's member record.
   - Mark its `device` record `revoked`.
   - Make a new key for `epoch + 1` and wrap it for each remaining member.
   - Bump `team.json` with `If-Match`, so two concurrent revokes can't both win.

   The removed device can still read what it already had, but nothing new. Its next sync fails with *removed from the team* and relayd stops syncing.
4. **Leave.** Delete own member record and forget the team in `secrets.json`. The local board stays.

**Storage credentials and trust.** With direct R2/S3, members share one bucket token. A removed member who kept the token can still list, delete or garble objects, but cannot read or forge new ones. Use a token scoped to the one bucket, and rotate it after removing someone.

With a Worker there is no shared token. Access derives from the team key, and a revoke switches it atomically ([worker.md §2](worker.md#2-access)).

## 6. API (relayd)

| Method | Params | Returns |
|---|---|---|
| `sync.status` | — | `{inTeam, teamId, teamName, storage, epoch, deviceId, pendingOps, lastSync, lastPush, lastPull, lastResult, error, intervalSeconds, shareAgents}` |
| `sync.test` | `{storage}` | `{problems: []}`; S3 also checks `If-None-Match` is honoured |
| `sync.createTeam` | `{name, storage}` | status |
| `sync.invite` | — | `{code}` |
| `sync.join` | `{code}` | status |
| `sync.now` | — | status |
| `sync.revoke` | `{deviceId}` | status |
| `sync.leave` | — | status |
| `devices.list` | — | device records |

`storage` is one of:

- `{kind: 'r2', accountId, bucket, accessKeyId, secretAccessKey}`
- `{kind: 's3', endpoint, region, bucket, accessKeyId, secretAccessKey}`
- `{kind: 'folder', folder}`
- `{kind: 'worker', url, setupToken?}`: an already-deployed team Worker
- `{kind: 'cloudflare', accountId, apiToken}`: `sync.createTeam` deploys the Worker first, reporting progress as `sync.state` `{step}`, then uses it. `sync.test` checks the token's permissions

## 7. Known limits (v1)

- Pull lists all of `ops/` each pass. Fine for thousands of batches. Snapshots and compaction (with per-device `start-after` listing) come with M7.
- Without a Worker, run transcripts don't reach teammates; they see a run's status, agent and device only.
