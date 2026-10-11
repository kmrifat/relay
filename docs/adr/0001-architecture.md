# ADR-0001: Flutter UI + headless Dart daemon (`relayd`), shipped as one app

- Status: Accepted (2026-10-11). The M0 build met the performance budget; see Measured below.

## Context

Relay runs several coding agents at once (Claude Code, Codex, Gemini CLI, OpenCode with DeepSeek, Aider), on the plans the user already pays for. It also shows a board, live run streams, a terminal, a code view and a Git log, and syncs a team through the user's own Cloudflare account.

The owner's criteria are runtime speed, low RAM, a good UI, fast development, and **multiplatform** (macOS and iPhone first; Windows, Linux and Android must stay possible).

Measured on the owner's Mac (2026-10-11):

| Process | RAM | CPU |
|---|---|---|
| DevVault (Flutter, window open, idle) | ~125 MB RSS, 144 MB physical footprint | 0–10%, spiky |
| `devvault-mcp` (Dart, `dart compile exe`, no UI) | 8 MB | ~0% |
| One Claude Code CLI session | ~135 MB | varies |

The agents dominate memory. With four running they use about 540 MB, so the UI process is a small share of the total. Idle CPU in the UI is the real risk.

Options considered:
- **SwiftUI.** Lightest, with real Liquid Glass, but Apple only. Rejected because the app must be multiplatform.
- **Tauri.** Its UI is a web view (heavy on Windows), it has no native look, its mobile support is immature, and nothing from DevVault carries over.
- **A Rust core with a native UI per OS.** Best quality, but three UIs to build. Too slow to develop.
- **Compose Multiplatform.** Uses a JVM on desktop (RAM). **gpui** has no mobile support.
- **Flutter.** Covers every platform, and the owner already knows it. DevVault's per-OS kits (macos_ui, fluent_ui, yaru; ADR-0005 in DevVault) and its 5.8k-line native-look control set can be reused.

## Decision

1. **Two processes, one install.**
   - **UI:** a Flutter app for all platforms. Desktop uses the DevVault per-OS kits. The iPhone app draws the Liquid Glass look itself (blur and highlight on a few surfaces only).
   - **`relay`:** a single Dart binary (`dart compile exe`) with three roles:
     - `relay daemon` (*relayd*): owns agent processes, PTYs, git worktrees, file watching, SQLite and sync.
     - `relay mcp`: an MCP stdio server that agents use to read and update tasks.
     - `relay <cmd>`: a small CLI (`relay task add`, `relay status`).
   - The UI renders only what relayd reports. Closing the window never stops an agent.
2. **Same language on both sides.** Shared pure-Dart packages (`relay_core`, `relay_protocol`) are imported by the UI and the daemon. There is no FFI bridge between them.
3. **Transport.** JSON-RPC 2.0 over a local socket, with requests plus a server-pushed event stream:
   - macOS and Linux: a Unix domain socket in a 0700 directory. DevVault's ADR-0006 proved this works across the sandbox.
   - Windows: loopback TCP with a per-boot random token required on every request. To verify in M0: whether `dart:io` Unix sockets work on Windows.
   - On connect, the two sides exchange protocol versions.
4. **Agents.**
   - Drive each CLI in its machine-readable mode where one exists. For example, Claude Code's headless mode with streaming JSON output, and Codex's non-interactive JSON mode. The exact flags are verified per CLI version in M0 and M2.
   - Use a PTY only for the interactive terminal and *Take over*. It is built on `dart:ffi` (`forkpty` on macOS and Linux, ConPTY on Windows) unless a maintained pure-Dart package fits.
   - Plain Dart cannot use Flutter plugins. Anything OS-specific in the daemon goes through `dart:ffi` or a system CLI (`git`, `security`).
5. **Packaging per OS** (the user installs one thing):
   - **macOS:** the binary sits at `Relay.app/Contents/Helpers/relay`, is registered as a login item (`SMAppService`) on first run, and is not sandboxed because it runs CLIs. Distribution is Developer ID plus notarization; there is no Mac App Store build. The helper needs the hardened-runtime entitlements found in DevVault's ADR-0006.
   - **Windows:** `relay.exe` next to `Relay.exe` in the installer, with a Startup entry.
   - **Linux:** shipped inside the package, run as a background user service (systemd `--user`) or via autostart.
   - **iPhone and Android:** no daemon. Phones talk to the owner's desktop relayd through the Cloudflare Worker.
6. **Updates.** The app and the daemon update together. A new daemon takes over only when no agent run is active.

## Performance budget (checked by `tool/perf_check`, from M0 onward)

| Measure | Budget |
|---|---|
| UI idle, window open, nothing running | < 1% CPU (60 s average), < 150 MB RSS |
| UI while 3 runs stream | < 15% CPU on an M-series Mac |
| relayd idle | < 30 MB RSS, ~0% CPU |
| relayd per active run | < 10 MB on top of the agent process itself |
| Run output to screen | Batched, at most 30 frames/s, never one repaint per line |
| Cold start to board visible | < 1.0 s (macOS, release) |

## Measured (M0-07, 2026-10-11)

M1 Pro, macOS 27, release build, board open, no agent working, `tool/perf_check.sh 60`:

| Process | CPU (60 s avg) | RSS | Budget |
|---|---|---|---|
| Relay app | 0.18% | 122 MB | < 1%, < 150 MB ✓ |
| relayd | 0.03% | 12 MB | < 1%, < 30 MB ✓ |

Notes from the build:
- On macOS and Linux a Unix socket path is limited to about 104 bytes. When `$RELAY_HOME/relay.sock` would be longer, relayd uses `/tmp/relay-<hash>.sock`. The socket is mode 0600, and clients still need the token from `daemon.json` (also 0600).
- The app is not sandboxed. It starts relayd from `Contents/Helpers/relay` (detached) and talks to it over the socket.

## Consequences

- One language and one workspace keep development fast. relayd stays small (8 MB class) and keeps agents running with no window open.
- The UI keeps Flutter's ~100 MB baseline. That is accepted: on macOS the UI can be quit while agents run.
- The iPhone app shows an imitation of Liquid Glass, not the system material. If that falls short, only the iPhone shell gets swapped to SwiftUI. It is a thin client, so the change is contained.
- The daemon is outside the macOS sandbox, so there is no Mac App Store build.
- Agent CLIs change their output. Each adapter is versioned and tested against recorded transcripts (see PLAN §7).
