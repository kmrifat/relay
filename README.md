# Relay

A local-first task manager where you, your team and your team's coding agents share one board. Relay drives the agent CLIs you already have (Claude Code, Codex, Gemini CLI, OpenCode, Aider) on your own plans, and keeps everything on your Mac.

- **Plan:** [docs/PLAN.md](docs/PLAN.md)
- **Architecture:** [ADR-0001](docs/adr/0001-architecture.md), a Flutter UI plus a headless Dart daemon (`relayd`), shipped as one app
- **Protocol:** [docs/protocol.md](docs/protocol.md) · **Performance:** [docs/perf.md](docs/perf.md)
- **Design:** `design/Relay.fig` (Open Pencil)

## Layout

```
apps/relay/          Flutter app (macOS now, iPhone next)
packages/relay_core      models, op log, SQLite store
packages/relay_protocol  JSON-RPC, paths, client
packages/relay_agents    one adapter per agent CLI
packages/relay_git       git CLI wrapper, commit graph layout
packages/relay_pty       pseudo-terminals (native relay-pty helper)
packages/relay_daemon    `relay`: daemon, MCP server, CLI, demo agent
tool/                build_relay_helper.sh, build_pty.sh, perf_check.sh
```

## Run it

```bash
flutter pub get
```

```bash
cd apps/relay && flutter run -d macos
```

The macOS build compiles `relay` and `relay-pty` into `Relay.app/Contents/Helpers/`. The app starts relayd on first launch and leaves it running when the window closes, so agents can finish.

Without the app, run the daemon and use the CLI:

```bash
tool/build_relay_helper.sh tool/out && RELAY_PTY=tool/out/relay-pty tool/out/relay daemon
```

```bash
tool/out/relay project add Kitchenly --key KT --repo ~/code/kitchenly/api --repo ~/code/kitchenly/app
```

```bash
tool/out/relay task add "Share a recipe with a link" --project KT --agent demo --repo api --repo app --queue
```

The **Demo agent** is built in and needs no account. To use a real agent, sign its CLI in first (for example `claude /login`), then press **Find CLIs** under Agents.

## Contributing

`main` is protected by a local git hook until the repo is on a GitHub plan with branch protection. Turn it on once per checkout:

```bash
git config core.hooksPath tool/git-hooks
```

The hook refuses three things: pushing straight to `main`, deleting it, and force-pushing any branch. Work on a branch and open a pull request (`gh pr create`). For a one-off override, run `RELAY_ALLOW_MAIN_PUSH=1 git push`.

## Test

```bash
for p in packages/*; do (cd $p && dart test); done
```

```bash
cd apps/relay && flutter test
```

`packages/relay_daemon/test/daemon_test.dart` runs relayd end to end against temporary git repos:
- a cross-repo task run by the demo agent, with permission prompts;
- merging the change set in order;
- contract-change notices;
- pushing to a remote;
- time limits and spend caps;
- terminals, file access limits and the MCP server.

## Licence

Apache-2.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE). Relay runs agent CLIs you install and sign in to yourself; their providers' terms apply ([docs/terms-check.md](docs/terms-check.md)).
