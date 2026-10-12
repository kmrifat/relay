# Relay v0.2: agent teams

v0.1 can run agents on many tasks. v0.2 aims to make it pleasant to run **several products at once, each staffed by a small team of agents with roles** (a project manager on a strong model, senior backend and frontend devs, a QA engineer on a cheap model). Those agents keep working, hand work to each other and talk to each other, while you watch everything from one screen and step in only when they need you.

- **Design:** `design/Relay.fig`, page **v0.2 · Agent teams (proposal)**, frames P01–P06. They are not approved yet.
- **IDs** continue from v0.1's plan: M11–M16, with sub-tasks like `M12-03`.
- **Audit date:** 2026-10-12, against `release-v0.1.2` (a9d7155).

| Frame | What it shows |
|---|---|
| P01 · Mission control | Every product on one screen, with a lane per role showing what each agent is doing; one *Needs you* queue; agent-to-agent chatter; who worked on what today; plan-limit meters |
| P02 · Agent team builder | An agent = role + CLI + **model** + **effort** + responsibilities + permissions; team workflow (You → PM → devs → QA → You); team rules; templates |
| P03 · Board v2 + peek | Epic swimlanes, filter bar (text, assignee, repo, tag, *needs me*), compact cards with PR/checks/done-when, WIP count, collapsed Done, keyboard focus, side **peek** instead of a full-page swap |
| P04 · Channel | `@agent` picker with model / effort / *make a task · just answer · plan only* / repo for each message; PM posts a plan card you approve; agent-to-agent threads shown inline |
| P05 · Ask an agent (⌘J) | Ask any agent from anywhere, with the same options, plus "continue" shortcuts (steer a live run, answer a question) |
| P06 · Keyboard map + splits | The full shortcut scheme, and resizable panes everywhere |

## Status (2026-10-12)

All six milestones are built on branch `v0.2-agent-teams`, one commit each, and tracked in Relay itself as RL-1 to RL-29 (project RL), all in Review. Every package's tests and the app's widget tests pass.

| Milestone | State | Notes |
|---|---|---|
| M11 Keyboard, focus, splits | ✅ | `app/commands.dart` (HardwareKeyboard handler), `app/menus.dart` (macOS menu bar), `ui/split.dart`; keyboard map on `?` / ⌘/ |
| M12 Model and effort | ✅ | Claude `--effort` checked on 2.1.278. Codex's `model_reasoning_effort` and the generic `{model}` / `{effort}` flags are from their docs and aren't checked: Codex isn't installed, and OpenCode can't start in the sandbox |
| M13 Roles and teams | ✅ | Role agents run on a CLI runtime; teams and templates; team page (P02). Roles stay on the owner's Mac; teammates see a summary (decision 2) |
| M14 Working together | ✅ | Mailbox, plans, handoffs, PM-first questions, limits, `relay tool`, Codex MCP via `-c`. Covered with the demo agent; not yet with live Claude runs |
| M15 Mission control | ✅ | The app opens on it (decision 4); ⌘0 returns to it |
| M16 Board v2 | ✅ | Peek, filters, epic lanes, folding Done, reorder, new status names |

**Not done yet:** scheduled team rules (e.g. a nightly suite), spend-aware model step-down, the review loop on diff lines, and the other items in section 4. A first live dogfood run with a real Claude Code squad is still to do.

---

## 1. What's wrong today (audit)

### Keyboard
Keyboard support was never written for most of the app; nothing regressed. These are the only bindings: ⌘N, ⌘K and Esc (`app/shell.dart:199-215`); ↑/↓/↵ in List (`features/list/list_view.dart:88-96`); ⌘S, ⌘W and ⌃` in Code; and the channel composer.

Why even those feel dead:
- **The terminal steals focus.** `RelayTerminal` autofocuses (`features/code/terminal_panel.dart:10`), and the panel is open by default. xterm then consumes Esc, the arrows and ↵ (`code_view.dart:374`).
- **List's `Focus(autofocus: true)` never wins.** It is nested under the shell's autofocus node, and clicking a row doesn't request focus (`list_view.dart:96`).
- **Nothing can take focus.** `Hoverable` is only `MouseRegion` + `GestureDetector` (`ui/widgets.dart:351-385`), so Tab traversal and focus rings don't exist anywhere.
- **Shortcuts only work inside `Shell`.** There is no app-level `Shortcuts`/`Actions` and no `PlatformMenuBar`.
- **Board, sidebar, task page, Code tabs, fleet and timeline** have no keys at all.

### Resizing
- **The terminal has a drag strip, but it's 5 px tall** and easy to miss (`code_view.dart:303-311`).
- **It can crash.** `clamp(120, maxHeight - 160)` throws when the editor area is under 280 px (`code_view.dart:308`; line 235 guards this case, 308 doesn't).
- **Each pixel of drag rebuilds the whole Code view**, editor included.
- **Every other split is fixed:** explorer 250, agent mirror 420, sidebar 220, task details 480.

### Model and effort
- **No screen sets the model.** `AgentProfile.model` exists and reaches `RunSpec` (`relay_daemon/lib/src/supervisor.dart:251`), but no UI sets it. Generic adapters have no `{model}` placeholder.
- **Effort isn't supported anywhere.**
- **No per-task, per-step or per-message override exists.**
- **Channel messages carry only `{channelId, body, files}`** (`channel_page.dart:560`). The task they create gets no model, effort, mode or repo; the repo falls back to the project's first repo.

### Agents as roles
- **One profile per CLI.** The id is the adapter id (`relay_daemon/lib/src/api.dart:524-553`), so you can't have "Bram (Sonnet, backend)" and "Quinn (Haiku, QA)" both on Claude Code.
- **No role, responsibilities or system prompt.** The only identity is "You are ${agent.name}…" (`supervisor.dart:302`). `goodAt` is display-only.
- **Profiles are local-only and not synced.**
- **Agents are hard to reach.** The sidebar's agent rows all open the same fleet page. Apart from a channel, nowhere lets you just ask an agent something.

### Collaboration
- **Agent MCP tools are scoped to the agent's own task.** `relay_create_task` from a run makes a Backlog follow-up with no assignee and no queue (`mcp.dart:300-307`).
- **`relay_message_agent` only arrives** if the target has a live, steerable run on the **same task**. In practice that means Claude/Demo only.
- **Codex and the generic adapters never get the MCP config.** Codex's `argsFor` has no MCP (`relay_agents/lib/src/codex.dart:30-40`).
- **Agents can't post in channels, can't assign or queue work for others, and can't wait for a reply.**
- **`Repo.agentPolicy: 'ask'` is saved and shown, but never enforced.** `worktreePerRun` is unused.

### Board and visualization
- **Columns are fixed** to backlog, queued, running, review and done.
- **Within a column, cards can't be reordered.**
- **Filtering is limited:** only by repo. There are no swimlanes and no empty states.
- **Cards leave out what you need to judge them:** PR state and checks, done-when progress, cost.
- **Opening a task replaces the whole content area.**
- **There's no cross-product view.** There's also no activity feed, task dependency graph, epics or milestones, or cost/usage charts.
- **Timeline only covers one project.**
- **The task model has no** parent/subtasks, epics, milestones or due dates. The New Task sheet can't set `dependsOn`.

---

## 2. Milestones

Estimates assume one developer working with agents, as in v0.1.

### M11 · Usability fixes: keyboard, focus, splits (P06) — ~4d
Ship this first: it is small, and it fixes the things you hit every day.
- **M11-01 · Focus model** (1d).
  - The terminal autofocuses only after *New terminal*, *Take over*, or clicking it.
  - ⌘Esc leaves terminal or editor focus.
  - Move global bindings to `MaterialApp.shortcuts/actions` and a macOS `PlatformMenuBar`, so they work whatever has focus.
  - AC: with the Code view open, ⌘K, ⌘J, ⌘0–9 and ? all work.
- **M11-02 · Focusable controls** (0.5d). `Hoverable` becomes a `FocusableActionDetector` (↵/Space activate it, with a focus ring in the accent colour). AC: Tab reaches every button, row and card.
- **M11-03 · Global keys** (1d). ⌘0 mission control, ⌘1–9 products, ⌥1–6 views, ⌘[ / ⌘] back/forward, ⌃Tab sidebar ↔ content, ? keyboard map sheet. AC: matches P06; every binding also appears in the menu bar.
- **M11-04 · Board, list, sidebar navigation** (1d). Arrows or J/K move; Space peeks; ↵ opens; ⌥←/→ moves a card; A assign; R run now; S steer. AC: you can triage a board without the mouse.
- **M11-05 · `ResizableSplit` widget** (1d).
  - 8 px grab zone, highlighted on hover; double-click resets; sizes are saved per view.
  - Drag updates go through a `ValueNotifier`, so the editor doesn't rebuild.
  - Fix the clamp crash at `code_view.dart:308`.
  - Apply it to explorer/editor, editor/terminal, terminal/mirror, task details/run, and the sidebar.
  - AC: no crash at any window size; dragging stays at 60 fps with a 5k-line file open.

### M12 · Model and effort everywhere (P02, P04, P05) — ~5d
- **M12-01 · Adapter capabilities** (1.5d).
  - `AgentAdapter` exposes `models()` and `efforts()`. They are detected where the CLI can list them, otherwise taken from a shipped table that you can edit in Settings.
  - **Check each flag against the installed version.** These are the flags I expect:
    - Claude Code: `--model` (effort: confirm flag vs. settings/env).
    - Codex: `--model`, `-c model_reasoning_effort=…`.
    - Gemini: `-m`.
    - OpenCode: `--model provider/model`.
    - Aider: `--model`, `--reasoning-effort`.
  - AC: a transcript test for each adapter proves the args are built.
- **M12-02 · Resolution order** (0.5d). Message/ask override → task → pipeline step → agent → CLI default. `RunSpec.effort` is added. The run header shows the model and effort that were actually used.
- **M12-03 · Task and new-task pickers** (1d). Model and effort fields on the task page and the new-task sheet, plus per-step overrides in pipelines.
- **M12-04 · Channel composer picker** (1.5d).
  - `messages.post` gains `{agent, model, effort, mode: task|answer|plan, repoIds}`. Options stick per channel until changed. AC: matches P04.
  - **"Just answer"** runs read-only in the product workspace (no worktree, no task) and replies in the thread.

### M13 · Agents as roles and teams (P02) — ~7d
- **M13-01 · Data model** (2d).
  - Split `AgentProfile` in two:
    - **Runtime:** a detected CLI install plus its account and limits. Local to the device.
    - **Agent:** the persona. Fields: name, role, runtime, model, effort, responsibilities, capabilities, slots, products, team, wake-on. Synced, so teammates see your squad.
  - Migration: each existing per-CLI profile becomes one agent with no role.
  - AC: two agents on Claude Code with different models run side by side.
- **M13-02 · Role prompt and capabilities enforced** (1.5d).
  - Responsibilities reach every run: Claude via `--append-system-prompt`, other CLIs via a generated `AGENTS.md` in the workspace.
  - Capabilities (`createTasks`, `assign`, `postChannel`, `editCode`, `runShell`, `merge`) gate the MCP tools and map to the CLI's permission mode and disallowed tools. A PM, for example, can't edit code.
  - Also enforce `Repo.agentPolicy: 'ask'`.
- **M13-03 · Teams and templates** (1d). A team has members, products, workflow edges and rules. Templates: Product squad, Solo builder, Bug crew.
- **M13-04 · Team builder UI** (2d). Matches P02. Sidebar section "Agent teams"; clicking an agent opens that agent (not the fleet page).
- **M13-05 · Limits per runtime** (0.5d). Slots are per agent; plan windows and the daily cap are per runtime/account, because agents share one subscription.

### M14 · Agents that work together (P01, P04) — ~9d
This is the core of "they keep working and talk to each other".
- **M14-01 · MCP tools v2** (2d). All are gated by capabilities.
  - `relay_create_task {title, brief, doneWhen, assignee|role, dependsOn, queue}`
  - `relay_assign`
  - `relay_post {channel, text}`
  - `relay_message {agent|role, text, task?}`: works across tasks.
  - `relay_wait {for: reply|task, timeout}`
  - `relay_report {kind: test|review, passed, failed, details}`
  - `relay_propose_plan {tasks[]}`
- **M14-02 · MCP for every adapter** (1.5d).
  - Codex through `-c mcp_servers.relay…`, Gemini through `settings.json` `mcpServers`, OpenCode through its config.
  - CLIs without MCP get a `relay tool …` CLI fallback, explained in the prompt.
  - AC: Codex calls `relay_progress` in a transcript test.
- **M14-03 · Mailbox** (1.5d).
  - A message to an agent with no live run is queued. It is delivered at that agent's next run start, or it wakes the agent with a short "respond" run, according to the agent's wake-on setting.
  - `relay_wait` resolves when the reply arrives.
  - AC: QA's question reaches the backend agent even though they are on different tasks.
- **M14-04 · Plan approval gate** (1d).
  - `relay_propose_plan` creates draft tasks with dependencies.
  - The plan appears as a card in the channel and in *Needs you*.
  - *Approve* queues them, *Edit* opens them in the List, *Ask to change* steers the PM.
  - Per-team setting: approval required (default on).
- **M14-05 · Workflow and rules engine** (2d).
  - Built on team edges and rules:
    - a builder's task done → a verification step for QA;
    - QA fails → back to the builder with the report;
    - an agent's product question → PM first, escalated to you only if the PM is unsure;
    - scheduled rules (e.g. a nightly full suite and digest).
  - Replaces routing rules; existing ones are migrated.
- **M14-06 · Autonomy guardrails** (1d).
  - Limits per agent: tasks created per hour, max subtask depth, and a daily team budget.
  - Ping-pong detection: the same two agents exchanging more than N messages without progress → pause and ask you.
  - A *Pause team* button.
  - Closes v0.1 open decision 3: agent messages are on by default inside a team.

### M15 · Mission control and visualization (P01) — ~7d
- **M15-01 · Products: goal, milestone, epics** (1.5d).
  - The project gains a goal, milestones (with due dates), and `parentId` on tasks for epics/subtasks.
  - The New Task sheet can set `dependsOn`.
- **M15-02 · Mission control page** (2.5d). Matches P01 and becomes the home page (⌘0). Product cards have role lanes (current step, LIVE/WAITING/FAILED/QUEUED), milestone progress, and a board strip.
- **M15-03 · Needs you queue** (1d). One queue for questions, permissions, plan approvals and reviews. Navigate it with J/K and answer inline. It is the same data as the Dock badge and menu bar.
- **M15-04 · Activity and team chatter** (1d). A global event feed filterable by product, agent and kind, with agent-to-agent messages first.
- **M15-05 · Usage** (1d).
  - A who-worked-on-what swimlane across products.
  - Plan-window meters per runtime, taken from limit errors and reset times. Check whether each CLI can report its usage directly.
  - Tokens and cost per task, agent and product.

### M16 · Board v2 (P03) — ~5d
- **M16-01 · Peek panel** (1.5d). Space or a click opens a 380 px side peek showing assignee, model, done-when, a live tail and a steer box. ↵ opens the full task page. AC: the board stays visible while you steer.
- **M16-02 · Filter bar and swimlanes** (1.5d).
  - Filters: text (`/`), assignee avatars, repo, tag, needs me.
  - Lanes: none, epic, agent, role or repo.
  - Density: compact or comfortable.
  - Saved per product.
- **M16-03 · Cards and columns** (1.5d).
  - Cards show the PR number and checks, done-when x/y, the model chip, and a dependency chip.
  - Columns get a WIP count (*In progress 3/4* comes from the slots), a collapsed Done column, reordering within a column, and empty states.
- **M16-04 · Status rename** (0.5d). Queued → *Ready*, Running → *In progress*, Review → *Review · QA*. Labels only; the stored enum is unchanged.

---

## 3. Order and timeline

```
week 1   M11 usability ───────────┐
week 2   M12 model/effort ────────┤
week 3-4 M13 roles + teams ───────┤──► dogfood: run Relay's own v0.2 with a Product squad
week 4-6 M14 collaboration ───────┘
week 5-7 M15 mission control  ║  M16 board v2   (parallel, mostly UI)
```

About 6–7 weeks. M11 and M12 are independent and can ship as 0.1.3 and 0.1.4. From M14 on, Relay can build its own milestones: a PM agent splits each `M1x-0y` into tasks for the backend and frontend agents, and a QA agent runs `dart test` / `flutter test`.

## 4. More tooling worth adding (not scheduled)
- **Role knowledge files.** A generated `AGENTS.md`/`CLAUDE.md` per role in each workspace, so QA gets the repo's test command from the Repo registry and frontend gets the design file path.
- **Review loop.** Comment on diff lines; *Request changes* steers the builder with those comments; `gh pr checks` feeds into QA's report.
- **Spend-aware routing.** When a team's budget passes 80%, step models down one tier, or hold P3 work until the plan window resets.
- **Run timeline.** A Gantt of the steps in a run, to see where time went. Failures are clustered by error text across runs.
- **Transcript search** across every run (⌘K scope "runs").
- **Playbooks.** Saved multi-step asks ("release checklist", "dependency bump"), started from ⌘J.

## 5. Decisions
1. **Plan approval.** Should the PM need your OK before its plan starts? Proposed: yes by default, with a per-team toggle. *Built that way.*
2. **Sync agents?** *Decided 2026-10-12: no; share a view of them instead.* Role agents run on the owner's CLI logins and plan limits, so their definitions stay on that Mac. Teammates see each one's name, role, team, model and effort through the device summary. Responsibilities stay private. Teammates can give them work only when the owner turns on Share my agents.
3. **Keys.** ⌘1–9 for products and ⌥1–6 for views (proposed). *Built that way.*
4. **Home page.** *Decided 2026-10-12: Relay opens on Mission control.*
5. **Status names.** *Built: Ready, In progress, Review · QA.*

## 6. Risks
- **CLI flags drift**, especially for effort. Mitigation: a capability probe at detect time, plus the editable table.
- **Runaway token use** with an Opus PM waking often. Mitigation: wake-on rules, a cheaper model for "respond" runs, team budgets, and ping-pong detection.
- **Consumer-plan terms** for autonomous multi-agent use. v0.1 decision 5 stands (warn, don't block); the warning moves to the Team builder.
- **Context bloat** from mailboxes and plans. Mitigation: deliver summaries, and link the full threads through `relay_task`.
