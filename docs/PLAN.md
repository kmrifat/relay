# Relay: build plan

Relay is the working name for the TaskManager project. It is a local-first, AI-native task manager in which a team and the team's coding agents share one board. Agents run on the subscriptions and API keys each person already has. Sync goes through the team's own Cloudflare account.

- **Design:** `Untitled.fig` (Open Pencil; rename it to `design/Relay.fig` in M0-01).
  - Page **Desktop · macOS**: T00 feature map, T01 Board, T02 Task + live run, T03 Agent fleet, T04 Team channel, T05 New-task pipeline, T06 Sync settings, T07 List, T08 Timeline, T09 Git tree, T10 Code (explorer, editor, terminal), T11 Project repos, T12 Cross-repo task, T13 Multi-repo in every view.
  - Page **iPhone · Liquid Glass**: I01 Inbox, I02 Board, I03 Live run + permission sheet, I04 Agents, I05 Channel.
- **Architecture:** [ADR-0001](adr/0001-architecture.md), a Flutter UI plus a headless Dart daemon (`relayd`), shipped as one app.
- **Sub-task IDs** (`M0-03`, `M2-05`, …) are used in branch names, PR titles and board cards.

## Status (2026-10-11)

M0–M5 are built and ready for the owner's testing. See [acceptance/m0-m5.md](acceptance/m0-m5.md). M6 (team sync) and M7 (Worker, live, channels, notifications) are built; see [acceptance/m6.md](acceptance/m6.md), [acceptance/m7.md](acceptance/m7.md), [format/sync.md](format/sync.md) and [format/worker.md](format/worker.md).

| Milestone | State | Notes |
|---|---|---|
| M0 Spike | ✅ | ADR-0001 accepted. Measured: app idle 0.18% CPU / 122 MB, relayd 0.03% / 12 MB; 3 streaming runs ≈ 1.3% each |
| M1 Local core | ✅ | Board, List (keyboard), task page, ⌘K |
| M2 Agents I | ✅ | Claude Code (stream-json + permission control), Codex (exec --json); demo agent for trying Relay without an account |
| M3 Dev views | ✅ | Terminal (relay-pty) with take over, Code view (re_editor), Git graph |
| M4 Agents II | ✅ | Gemini, OpenCode, Aider (generic text adapters); slots, limits, spend caps, routing, pipelines, Timeline, `relay mcp` |
| M5 Multi-repo | ✅ | Repos, read-only snapshots, change sets merged in order, push + PR via `gh`, contract notices |
| M6 Team sync | ✅ | E2E-encrypted op log on R2 / S3 / a shared folder; one-time invites; revoke rotates the key; teammates' shared agents; Settings → Team |
| M7 Live | ✅ | Team Worker + Durable Object deployed by Relay (no wrangler, no shared keys); live room with pokes, streamed run steps and presence; channels (T04) with `/task`, `@agent`, agent reports, digest, encrypted files, reactions, pins; macOS notifications and Dock badge |

**Still to verify with a live agent account:**
- Claude Code's permission control messages, with `claude /login` done.
- Codex's JSON events. The `codex` CLI is not installed on the dev Mac.

**Not done in M0–M5 (open decisions or later milestones):**
- Login-item registration (M9-02).
- A GitHub remote and branch protection for this repo, which needs the owner's go-ahead.

---

## 1. Product summary

- **One board for people and agents.** A task can be assigned to Sara, or to Sara's Codex. Agents comment, ask questions, ask for permission and hand off like teammates.
- **Bring your own plans.** Relay drives the CLIs the user already has (Claude Code, Codex, Gemini CLI, OpenCode with DeepSeek, Aider). It never resells API access. AI logins and keys never leave the device.
- **Many agents at once.** Each agent has slots and a queue, usage meters per plan, schedules that know when limits reset, fallback rules, and pipelines (plan → build → test → review).
- **Local first.** SQLite plus an op log on every device; it works offline.
  - Team sync: R2 for files, with an optional Worker (Durable Objects) for live updates.
  - End-to-end encrypted.
- **Multi-repo projects.** A project has many repos. A task touches several of them and becomes a *change set*: one branch name, one worktree per repo, a PR per repo, and a merge order.
- **Developer views.** Board, List, Timeline, Git (JetBrains-style graph), Code (explorer, editor, terminal with *Take over*), and Repos.
- **Out of scope for v1:** a hosted Relay server, a web app, billing, SSO, and Windows, Linux and Android builds. Their code paths stay possible; see M10.

### Decisions already made
| Topic | Decision |
|---|---|
| Stack | Flutter UI + headless Dart `relay` binary (ADR-0001) |
| Platforms, in order | macOS → iPhone → Windows/Linux → Android |
| Desktop look | DevVault's per-OS kits (macos_ui / fluent_ui / yaru), dark and light, accent `#0A64D8` |
| iPhone look | iOS 26 Liquid Glass, drawn in Flutter, light and dark |
| Sync | Each team brings its own Cloudflare account: R2 (op log + files) and an optional Worker (live) |
| Distribution (macOS) | Developer ID + notarization, Sparkle updates; no Mac App Store (the daemon is not sandboxed) |
| Multi-repo | One branch name per task across all repos; worktree per touched repo; read-only links to the rest; `PROJECT.md` repo map |

### Still open (decide before the milestone in brackets)
1. Product name ("Relay" is a placeholder). [M9]
2. Should Relay merge a change set in order itself, or only show the order? [M5]
3. Should agent-to-agent messages be on by default, or allowed per task? [M4]
4. Personal tool, open source, or a paid team product. This affects licensing and onboarding, not architecture. [M9]
5. Terms of each AI provider for automated use of consumer plans through their CLIs. To check per provider before public release. [M9]

---

## 2. Architecture

### Repo layout (pub workspace)
```
TaskManager/
├─ pubspec.yaml                 # workspace: [apps/*, packages/*]
├─ apps/relay/                  # Flutter UI (macOS, iOS first)
├─ packages/
│  ├─ relay_core/               # pure Dart: ids, HLC, models, op log, CRDT merge, SQLite schema + store
│  ├─ relay_protocol/           # pure Dart: JSON-RPC messages, events, versioning, codecs
│  ├─ relay_agents/             # pure Dart: one adapter per CLI, detection, usage parsing, permission bridging
│  ├─ relay_git/                # pure Dart: git CLI wrapper (worktrees, log graph, diff, status)
│  ├─ relay_pty/                # dart:ffi: forkpty (macOS/Linux), ConPTY (Windows)
│  ├─ relay_sync/               # pure Dart: R2 + Worker client, E2E crypto (sodium), op upload/download
│  └─ relay_daemon/             # bin/relay.dart → `relay daemon | mcp | <cli>`
├─ worker/                      # Cloudflare Worker (TypeScript, wrangler): auth, Durable Object per team, R2 presign, relay
├─ tool/                        # build_relay_helper.sh, perf_check, release scripts
├─ design/                      # Relay.fig + PNG exports
└─ docs/                        # PLAN.md, adr/, protocol.md, format/
```

### Inside relayd
| Component | Job |
|---|---|
| **IPC server** | JSON-RPC over a Unix socket (macOS/Linux), or loopback + token (Windows); version handshake; event fan-out |
| **Store** | SQLite (WAL) through `relay_core`; every change is an op with an HLC timestamp |
| **Supervisor** | Starts, stops and pauses agent processes; parses their JSON streams into run events; keeps transcripts |
| **Scheduler** | Slots per agent, queue, plan limits and reset times, routing and fallback rules, pipelines, "run tonight" |
| **Workspace manager** | `git worktree` per task per repo, multi-repo task folders, `PROJECT.md`, cleanup |
| **PTY manager** | Interactive terminals, read-only mirrors of agent sessions, *Take over* |
| **MCP server** (`relay mcp`) | Lets agents read their brief, post progress, ask questions, create subtasks |
| **Sync engine** | Pushes and pulls encrypted ops to R2; WebSocket to the Worker for live events and the iPhone relay |
| **Watcher** | File and git changes feed the Code and Git views |

### Protocol (first cut; full spec in `docs/protocol.md`, M0-05)
- **Requests:**
  - `hello` (protocol version); `tasks.list | get | create | update | move`; `projects.*`; `repos.*`.
  - `runs.start | steer | pause | resume | stop | handoff | takeover | release`; `permissions.answer`; `agents.list | detect | configure`.
  - `git.log | diff | status`; `fs.list | read | write`; `term.open | input | resize | close`.
  - `messages.post | list`; `sync.status`.
- **Events:**
  - `task.changed`, `run.event` (step, tool call, message), `run.output` (batched), `permission.requested`.
  - `agent.usage`, `agent.state`, `term.output`, `fs.changed`, `git.changed`, `sync.state`, `presence`.

### Data model (relay_core)
- **Org (team)** → **Member**, **Device**, **Channel**.
- **Project** → **Repo** (role, stack, base branch, test command, local path per device, agent rules).
- **Task:** title, brief, done-when checklist, status, priority, assignee (person or agent), dependencies, pipeline steps, repos touched.
  - **ChangeSet:** one entry per repo, with branch, worktree, PR, checks, merge order.
  - **Run:** agent, device, step, events, usage.
  - **Thread:** messages from people and agents.
- **Merge rules:** last-writer-wins per field (HLC), with a list CRDT for checklists and pipeline steps. Ops are append-only and encrypted with the team key before upload.

---

## 3. Definition of done (every PR)
1. `dart analyze` / `flutter analyze` is clean, and `dart test` in every package plus `flutter test` in `apps/relay` are green in CI.
2. New logic has unit tests. Each agent adapter has **transcript tests**: recorded CLI output is replayed and the expected run events are asserted.
3. UI work matches its frame in the design file. Goldens: desktop 1440×900, iPhone 402×874 @3x.
4. `tool/perf_check` stays within the ADR-0001 budget. A PR that regresses idle CPU or RAM is not merged.
5. No secret, token or prompt content appears in logs or crash output, and agent credentials are never read by Relay.
6. Protocol or format changes update `docs/protocol.md` / `docs/format/` and bump the protocol version.
7. Branch `<milestone>/<nn>-<slug>`; PR title `M2-05 · …`.

---

## 4. Milestones and sub-tasks
Format: **ID · title** (estimate). **D:** dependencies. **AC:** acceptance criteria. Estimates assume one developer working with agents.

### M0 · Scaffold + architecture spike (go / no-go for ADR-0001)
- **M0-01 · Repo** (0.5d). `git init`, GitHub repo, protected `main`; move `Untitled.fig` → `design/Relay.fig`. AC: first commit has docs/ and design/.
- **M0-02 · Workspace** (1d). D: M0-01. `apps/relay` (macOS + iOS enabled), the package skeletons, each with a smoke test, and CI. AC: `flutter run -d macos` works; `dart test` passes everywhere.
- **M0-03 · Profile DevVault idle CPU** (0.5d). Find what wakes DevVault at idle (0–10%). Record the cause and fix in `docs/perf.md`. AC: the cause is named, and a rule is added to the Definition of Done if needed.
- **M0-04 · `relay` binary + bundling** (1d). D: M0-02. `dart compile exe`; `tool/build_relay_helper.sh` copies it to `Contents/Helpers/relay` and signs it (DevVault ADR-0006 entitlements); the app starts it if it isn't running. AC: the release app launches relayd; quitting the UI leaves relayd running.
- **M0-05 · IPC + protocol v0** (1.5d). D: M0-04. Unix socket, `hello`, request/response and event stream, reconnect, `docs/protocol.md` v0. AC: the UI shows relayd's version and uptime, and survives a daemon restart.
- **M0-06 · One real agent run** (2d). D: M0-05.
  - Verify Claude Code's headless streaming-JSON flags on the installed version.
  - Start a run in a scratch git worktree, parse steps, and stream them to a bare run view, batched at ≤ 30 fps.
  - AC: a `claude` run's steps appear live; Stop works; the transcript is saved.
- **M0-07 · Perf harness** (1d). D: M0-06. `tool/perf_check` measures RSS and CPU for UI idle, UI with 3 streaming runs, and relayd idle. AC: a report in CI artifacts, and **the budget in ADR-0001 is met. If it is not, revisit ADR-0001 before M1.**

### M1 · Local task core (T01, T07, T02-left)
- **M1-01 · relay_core models + SQLite** (2d). Org, Project, Task, Checklist, Comment; HLC ids; migrations. AC: CRUD tests; the op log is written for every change.
- **M1-02 · Desktop shell** (2d). D: M1-01. DevVault kit reused: 220 pt sidebar, 52 pt toolbar, status bar, view switcher (Board · List · Timeline · Git · Code · Repos). AC: matches T01 chrome.
- **M1-03 · Board view** (2d). Columns, cards, drag to move, quick add. AC: golden vs T01 (static cards).
- **M1-04 · List view** (1.5d). Grouped table, sorting, keyboard navigation. AC: golden vs T07.
- **M1-05 · Task detail** (2d). Fields table, brief, done-when checklist, thread. AC: matches the left pane of T02.
- **M1-06 · Search + ⌘K** (1d). Searches tasks and comments. AC: results in < 50 ms on 5k tasks.

### M2 · Agents I: Claude Code + Codex (T02, T03)
- **M2-01 · Adapter interface** (1d). detect → version → plan/usage → start → events → permission → stop; transcript test harness.
- **M2-02 · Claude Code adapter** (2d). D: M2-01. Streaming events, tool calls, permission requests routed to Relay, session resume. AC: transcript tests for read/edit/bash/permission.
- **M2-03 · Codex adapter** (2d). D: M2-01. Its JSON mode; same AC as M2-02.
- **M2-04 · Worktrees per run** (1.5d). `relay_git` creates and cleans `tm-<id>` worktrees; diff summary. AC: two runs on one repo never touch each other's files.
- **M2-05 · Live run pane** (2.5d). D: M2-02. Steps, agent messages, permission card (Allow once / Always in project / Deny), steer box, pause, hand off. AC: matches the right pane of T02; ≤ 30 fps updates.
- **M2-06 · Agent fleet screen** (2d). Detected CLIs, plans, slots, usage meters, guardrails. AC: matches T03 (single device).
- **M2-07 · Review flow** (1.5d). Ready-for-review state, diff view, approve and merge locally. AC: the TM-39 path in T01 works end to end.

### M3 · Developer views: terminal, code, git (T09, T10)
- **M3-01 · relay_pty** (2.5d). forkpty via ffi, resize, signals; ConPTY stub. AC: vim and htop render correctly in the terminal.
- **M3-02 · Terminal panel** (2d). D: M3-01. xterm.dart frontend, tabs, split; a read-only mirror of the agent session; *Take over* pauses the agent. AC: matches the bottom panel of T10.
- **M3-03 · Explorer + editor** (3d). Worktree picker, git status colours, an "agent editing" marker, read and small edits (re_editor or flutter_code_editor, picked in a 0.5d spike), selection actions (Ask agent, New task). AC: matches T10; opening a 5k-line file takes < 200 ms.
- **M3-04 · Git log view** (3d). Commit graph lanes, branches, worktrees, commit details, agent authorship from trailers. AC: matches T09; 10k commits scroll smoothly.
- **M3-05 · Open in external editor** (0.5d). VS Code, Cursor, Zed.

### M4 · Agents II: fleet scale (T03, T05, T08)
- **M4-01 · More adapters** (3d). Gemini CLI, OpenCode (DeepSeek), Aider; detection on PATH. AC: transcript tests for each.
- **M4-02 · Slots, queue, scheduler** (2d). Concurrency per agent and per device; queue order; dependencies block. AC: TM-45 starts only after TM-44.
- **M4-03 · Usage + limits** (2d). Per-plan meters, reset times, a spend cap for API-key agents, fallback rules. AC: a Gemini limit moves queued work to Claude (T03).
- **M4-04 · Routing rules** (1d). If/then rules by tag and step. AC: rules editor as in T03.
- **M4-05 · Pipelines + new-task sheet** (2.5d). Plan → build → test → review steps, start options (now, slot free, tonight), stop limits. AC: matches T05.
- **M4-06 · Timeline view** (3d). Rows per agent slot and per person, running/scheduled/done/failed bars, now line, limit windows, overnight queue, drag to reschedule. AC: matches T08.
- **M4-07 · `relay mcp`** (2d). Agents read their brief, post progress, ask questions, create subtasks; agent-to-agent questions (open decision 3). AC: Claude Code uses it via `claude mcp add`.

### M5 · Multi-repo projects (T11–T13)
- **M5-01 · Repo registry** (1.5d). Repos per project, role, base, test command, local path per device, clone. AC: matches T11's table.
- **M5-02 · Task workspaces** (2d). One branch name per task; worktree per touched repo; read-only links; generated `PROJECT.md`. AC: an agent started in `~/.relay/<project>/<task>/` can read all repos and write only the touched ones.
- **M5-03 · Change sets** (2.5d). Per-repo status, PRs (GitHub API), checks, merge order (open decision 2). AC: matches T12.
- **M5-04 · Contracts** (1d). Watch the declared contract files (e.g. `shared/openapi.yaml`) and notify agents in dependent repos. AC: the notice appears in Codex's run when shared changes.
- **M5-05 · Multi-repo everywhere** (2d). Sidebar repo tree, board chips, Git "all repos", multi-root explorer, repo suggestion in new task. AC: matches T13.

### M6 · Team sync via R2 (T06)
- **M6-01 · Op log format + E2E** (2.5d). Team key, per-device sequence, envelope (reuse the vault_core pattern from DevVault), `docs/format/`. AC: tamper and wrong-key negative tests.
- **M6-02 · R2 push/pull** (2d). Conditional writes, idempotent pull, offline queue that survives restart. AC: two devices converge after offline edits.
- **M6-03 · Invites + devices** (2d). Invite link/QR, key exchange, device list, revoke. AC: a new teammate syncs the full workspace.
- **M6-04 · Shared agents** (1.5d). Teammates' agents shown as remote resources; assigning work to them; their consent rules. AC: assigning a task to Sara's Codex runs it on Sara's Mac.
- **M6-05 · Sync settings** (1d). Modes (device only / files in R2 / R2 + Worker). AC: matches T06.

### M7 · Live: Worker + chat (T04)
- **M7-01 · Worker + Durable Object** (3d). Per-team DO: auth, presence, event relay; R2 presign; one-command deploy to the team's account. AC: `relay worker deploy` works on a fresh Cloudflare account.
- **M7-02 · Live events** (2d). WebSocket from relayd; live run streams to watchers; falls back to R2 polling. AC: a teammate sees a run's steps in < 1 s.
- **M7-03 · Channels** (3d). Messages, threads, reactions, files in R2, `/task` and `@agent`, morning digest. AC: matches T04.
- **M7-04 · Notifications** (1d). macOS notifications for questions, permissions and review requests.

### M8 · iPhone (I01–I05)
- **M8-01 · Glass kit** (2.5d). Glass capsule, tab bar, toolbar pills, inset sheet; blur budget (≤ 4 glass layers on screen). AC: I01 golden; 120 fps scroll on iPhone 15+.
- **M8-02 · Remote connection** (2d). The phone talks to the owner's relayd through the Worker; pairing via QR. AC: works on cellular with the Mac at home.
- **M8-03 · Screens** (5d). Inbox, Board, Live run + permission sheet, Agents, Channel. AC: matches I01–I05.
- **M8-04 · Push** (1.5d). APNs through the Worker for agent questions and permission requests.

### M9 · Ship macOS + iPhone
- **M9-01 · Onboarding** (2d). Detect CLIs, pick a repo, first task, optional team setup.
- **M9-02 · Login item + background** (1d). `SMAppService`; a menu bar status from the UI app.
- **M9-03 · Sign, notarize, Sparkle** (1.5d). Reuse DevVault's release scripts.
- **M9-04 · TestFlight + App Store** (1.5d) for the iPhone client.
- **M9-05 · Name, site, license, provider terms check** (open decisions 1, 4 and 5).

### M10 · Windows + Linux (after v1)
ConPTY, loopback IPC with a token, fluent_ui / yaru shells (from DevVault), installers, a Startup entry or systemd `--user` service.

---

## 5. Order and rough timeline
| Milestone | Estimate | Running total |
|---|---|---|
| M0 Spike | ~7.5d | 1.5 weeks |
| M1 Local core | ~10.5d | 3.5 weeks |
| M2 Agents I | ~12.5d | 6 weeks |
| M3 Dev views | ~11d | 8 weeks |
| M4 Agents II | ~15.5d | 11 weeks |
| M5 Multi-repo | ~9d | 13 weeks |
| M6 Sync | ~9d | 15 weeks |
| M7 Live + chat | ~9d | 17 weeks |
| M8 iPhone | ~11d | 19.5 weeks |
| M9 Ship | ~7d | ~21 weeks |

The first usable solo build ("my agents on one board") ships after **M2**, about 6 weeks in. The milestones after it can be reordered: if the team matters before multi-repo, swap M5 with M6 and M7.

---

## 6. Risks
| Risk | Mitigation |
|---|---|
| Flutter misses the idle-CPU budget | M0-03 and M0-07 gate it; no animations at idle; batched output; fall back per ADR-0001 |
| Agent CLIs change their output | Adapters are versioned; transcript tests; detect the CLI version; degrade to a plain log view |
| Provider terms on automated use of consumer plans | Check before public release (open decision 5); API-key mode stays available |
| PTY on Windows | Deferred to M10; ConPTY is behind the same interface |
| Durable Object or R2 limits for big teams | Per-team DO; batch ops; snapshots in R2 |
| Liquid Glass imitation looks off | Limit glass to bars and sheets; the iPhone shell can move to SwiftUI later (thin client) |

## 7. Testing strategy
- **Pure packages:** `dart test`, with property tests for the CRDT merge and op log.
- **Adapters:** transcript replay tests, plus a nightly job that runs each installed CLI on a canned task.
- **Daemon:** integration tests against a temporary git repo and a fake agent binary.
- **UI:** widget tests and goldens per frame; `tool/perf_check` in CI.
- **Sync:** two-device simulation with Miniflare or a local Worker, and offline/online fuzzing.
