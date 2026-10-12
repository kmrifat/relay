# relayd protocol (v1)

The UI, the `relay` CLI and `relay mcp` talk to relayd over JSON-RPC 2.0. Each message is UTF-8 JSON on one line. Names live in `packages/relay_protocol/lib/src/protocol.dart` (`M` for methods, `E` for events); this document explains them.

## Connecting

1. Read `daemon.json` in the Relay home folder (`RelayPaths`):
   - `~/Library/Application Support/Relay` on macOS, `$XDG_DATA_HOME/relay` on Linux, `%APPDATA%\Relay` on Windows.
   - `$RELAY_HOME` overrides the location.
   - The file is mode 0600. It holds `{pid, version, protocol, token, socket | port, startedAt}`.
2. Connect:
   - macOS and Linux: the Unix socket at `socket`. This is `relay.sock` in the home folder, or `/tmp/relay-<hash>.sock` when that path would exceed about 100 bytes.
   - Windows: `127.0.0.1:<port>`.
3. Call `hello {token, protocol, client}`. Every other method is refused until `hello` succeeds. The answer is `{version, protocol, deviceId, pid, userName}`.

Errors use the JSON-RPC codes plus `-32001` (unauthorized: bad token, or a path outside repos and workspaces), `-32004` (not found) and `-32009` (busy: `shutdown` while agent runs are active).

## After an update

relayd outlives the app, so after an update the previous version's relayd is still the one answering. When the app connects, it compares `hello`'s `version` with its own. If relayd is older and the bundled helper (`relay version`) is newer than relayd, the app replaces relayd. A newer relayd, or one whose version doesn't parse, is left alone. Code: `apps/relay/lib/data/daemon_upgrade.dart`.

1. If agent runs are active (`runs.list {active: true}` with `live`), the app waits for them to finish. A banner offers **Restart now**, which asks first and then stops the runs. Their tasks go back to the queue.
2. The app calls `shutdown`. A relayd from before 0.1.2 has no `shutdown`, so it gets SIGTERM, which stops it the same way.
3. The app waits until nothing answers on the socket or port as that pid and the process has exited.
4. The app starts the bundled relayd through whatever started the old one, so there is only one relayd and it belongs to the service manager:
   - macOS LaunchAgent (`launchctl list com.binarycastle.relay.daemon` shows relayd's pid): `launchctl kickstart`. relayd exited 0, so `KeepAlive` didn't restart it.
   - Linux systemd user unit (`MainPID` is relayd's pid): the unit is rewritten for this version's binary, then `systemctl --user start relayd.service`.
   - Otherwise, including the Windows Run entry, which only acts at login: started detached, as on a first start.

The app tries this once per launch, so a relayd that comes back old is not restarted again.

## Records

Records are JSON maps with an `id`. Each kind has its fields in `relay_core/lib/src/models.dart`: `project`, `repo`, `task`, `comment`, `run`, `agent`, `change` (one repo's part of a task's change set) and `rule`. Writes are field patches. A `null` value removes a field. Every patch is an op in the op log (for sync in M6).

## Methods

| Method | Params | Returns |
|---|---|---|
| `status` | — | version, pid, uptime, active runs, RSS, home |
| `shutdown` | `{force?}` | `{pid, version, stoppedRuns}`, then relayd stops: active runs are marked stopped and their tasks are queued again, the socket and `daemon.json` are removed, and the process exits 0. Refused with `-32009` (`data.activeRuns`) while runs are active, unless `force`. Local clients only: a paired phone can't call it |
| `projects.list / create / update` | `{name, key}` / `{id, fields}` | project(s) |
| `repos.list` | `{projectId?}` | repos with `localPath`, `cloned` |
| `repos.inspect` | `{path}` | git facts, stack, test command, contracts |
| `repos.add` | `{projectId, path?, fields}` | repo |
| `repos.update / remove / clone` | `{id, fields}` / `{id}` / `{id, dest?}` | repo / true |
| `tasks.list / get` | `{projectId?}` / `{id}` | tasks / `{task, comments, runs, changes, workspace}` |
| `tasks.create` | `{projectId, fields}` | task (numbered per project) |
| `tasks.update / move / delete` | `{id, fields}` / `{id, status, position?}` / `{id}` | task / true |
| `tasks.suggestRepos` | `{projectId, text, repoIds}` | `[{repoId, name, reason}]` |
| `comments.list / post` | `{taskId}` / `{taskId, body, authorKind?, author?, question?}` | comments / comment |
| `runs.list / get / events` | `{taskId?, active?}` / `{id}` / `{runId, after?, limit?}` | runs / run / run events |
| `runs.start` | `{taskId, agentId?, note?}` | run (prepares the workspace) |
| `runs.steer / pause / resume / stop` | `{runId, text}` / `{runId}` | true |
| `runs.handoff` | `{runId, agentId, note?}` | new run |
| `permissions.answer` | `{runId, requestId, answer}` (`allow_once`, `allow_always`, `deny`) | true |
| `agents.list / detect / update` | — / — / `{id, fields}` | agents with `active` and `today` usage |
| `agents.message` | `{taskId, from, to, text}` | true (agent-to-agent) |
| `rules.list / save / delete` | — / `{id?, fields}` / `{id}` | rules |
| `settings.get / set` | — / `{values}` | settings |
| `changes.list` | `{taskId}` | change entries with their repo |
| `changes.merge` | `{taskId, repoId?}` | `[{repo, ok, commit | error}]`, merged in repo order |
| `changes.push` | `{taskId, repoId?}` | `[{repo, ok, url | error}]`; opens a PR with `gh` when installed |
| `workspaces.list` | — | task workspaces and their change entries |
| `git.log` | `{path, limit?, grep?}` | commits with `agent`, `task` and `graph` lanes |
| `git.show / diff / status / branches / worktrees` | `{path, …}` | — |
| `fs.list / read / write` | `{path, text?}` | limited to repo checkouts and workspaces |
| `term.open` | `{path, cols, rows, runId?}` | terminal id |
| `term.input / resize / close` | `{termId, text \| data(base64)}` / `{termId, cols, rows}` / `{termId}` | true |
| `term.takeover` | `{runId}` | pauses the agent and opens a shell in its workspace |
| `term.list` | – | open terminals `[{id, cwd, command, runId?, openedAt}]`; they live as long as relayd |
| `term.attach` | `{termId}` | `{id, cwd, command, …, data(base64)}`: the last 256 KB of output. Apply `term.output` that arrives after the answer; what came before is already in `data` |
| `ui.get` / `ui.set` | `{key}` / `{key, value \| null}` | this device's UI state (open tabs, saved terminal commands), up to 256 KB a key; never synced |
| `sync.status / test / createTeam / invite / join / now / revoke / leave` | see [format/sync.md §6](format/sync.md#6-api-relayd) | team sync; status adds `live`, `online` (device ids in the Worker room) |
| `sync.pairPhone / pair` | — / `{code}` | `{code, macName}` / status (phone joins as the Mac's companion) |
| `push.config / status / register` | `{keyId, teamId, bundleId?, p8}` / — / `{token, sandbox}` (phone) | phone push through the team Worker ([format/worker.md §5](format/worker.md#5-phones-m8)) |
| `devices.list` | — | team device records (name, person, agents, `shareAgents`, `lastSeen`) |
| `channels.list` | — | channels with `unread` and `lastAt` (`#general` and one per project exist by default) |
| `channels.create / update / read / pin` | `{name, projectId?, topic?}` / `{id, fields}` / `{channelId}` / `{channelId, messageId, on?}` | channel / true |
| `messages.list` | `{channelId, limit?}` | messages, oldest first |
| `messages.post` | `{channelId, body, replyTo?, files?: [path]}` | `{message, task?}`, or `{message, tasks}` when `@agent` mentions made tasks. `/task [@agent] title` makes a task on the channel's board |
| `messages.react / delete` | `{messageId, emoji, on?}` / `{id}` (own only) | true |
| `files.get` | `{messageId, fileId}` | `{path}`, fetched and decrypted from team storage the first time |

## Events (notifications from relayd)

| Event | Params |
|---|---|
| `entity.changed` | `{items: [{kind, data}]}` batched, ≤ 30/s |
| `run.events` | `{runId, events: [RunEvent]}` batched, ≤ 30/s |
| `term.output` / `term.exit` | `{termId, data(base64)}` / `{termId, code}` |
| `agent.state` | `{agents: [{id, active, slots, limitedUntil}]}` |
| `notice` | `{text, level}` (info, warning, error, ask) |
| `sync.state` | `sync.status`'s shape, after every sync pass, live-room change, or deploy `step` |
| `notify` | `{kind, title, body, taskId?, channelId?, messageId?}`. `kind` is one of `ask` (permission or question on this Mac), `review` / `failed` (your task), `mention`, or `consent` (a teammate queued work on your unshared agents) |

## Run event types

`message {text}`, `tool_use {id, tool, summary}`, `tool_result {id, ok, summary}`, `permission {id, tool, summary, input}`, `permission_answer {id, answer}`, `steer {text, from?}`, `status {status, detail}`, `output {text}`, `error {text}`. Usage goes to the run record (`tokensIn`, `tokensOut`, `costUsd`) instead of the event stream.

## `relay mcp --run <id>`

An MCP server over stdio that agents get through `--mcp-config`. Tools:
- `relay_task`: read the brief, checklist and discussion.
- `relay_progress`: post a note.
- `relay_ask`: ask the people on the task. The reply is steered back to the agent.
- `relay_message_agent`: message another agent on the task.
- `relay_check`: tick a "done when" item.
- `relay_create_task`: add a follow-up task.

## `relay mcp`

Without `--run` (and no `RELAY_RUN`), the same server is for a person's own agent session, across projects. Add it to Claude Code with `claude mcp add relay -- <path to relay> mcp` (on macOS: `/Applications/Relay.app/Contents/Helpers/relay`). Tools:
- `relay_projects`: project keys and repos, and the agents that can take tasks.
- `relay_tasks {project?, status?}`: a project's tasks with their keys.
- `relay_create_task {title, project?, brief?, doneWhen?, repos?, agent?, queue?}`: a task in Backlog, or queued with `queue: true`. Without `repos`, Relay suggests them from the title and brief, as the new-task sheet does.
- `relay_task_status {task}`: status, latest run, open question, checklist and discussion of a task such as `GA-3`.
