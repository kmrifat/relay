# Performance notes

The budget lives in [ADR-0001](adr/0001-architecture.md). `tool/perf_check.sh` measures it against the running app and relayd.

## M0-03: why DevVault uses CPU while idle

**Measured (2026-10-11).** DevVault's release build on its lock screen used **2.4 s of CPU in 30 s (≈ 8%)**. The unlocked instance the owner had open earlier swung between 0% and 10%.

**Cause.** `sample` showed `Ticker._tick` → `handleBeginFrame` → `Rasterizer::Draw` running continuously. Something on screen was animating with a `Ticker`.
- On the lock screen it is the focused password field's caret. On Apple platforms Flutter's `TextField` defaults to `cursorOpacityAnimates: true`, so the caret fades in and out by redrawing every frame, for as long as the field has focus.
- Any always-on animation does the same: an indeterminate `LinearProgressIndicator` or `CircularProgressIndicator`, a looping `AnimationController`, or shimmer placeholders.

**Fix for DevVault.** Set `cursorOpacityAnimates: false` on its desktop text fields (bc_ui and the desktop kit). Check that nothing else animates while idle by running `tool/perf_check.sh`, or `sample <pid> 5` and searching the output for `Ticker._tick`.

## Rules for Relay (part of the Definition of Done)

1. **No animation while idle.** Nothing on screen may run a `Ticker` unless the user is interacting or something changed.
   - Text fields use `FieldInput`, which sets `cursorOpacityAnimates: false`.
   - Progress bars on running tasks are **determinate**: pipeline step, else tool calls so far. An indeterminate bar on every running card would repaint the board every frame.
   - The run stream marks an in-flight tool call with a static icon, not a spinner.
   - Spinners appear only while a request is loading, never as a resting state.
2. **Batch live data.** relayd sends entity changes, run events and terminal output at most ~30 times a second per client (`_Client._schedule`, `Terminals._flush`).
3. **Timers, not frames, for clocks.** The Timeline's "now" line updates once a minute with a `Timer`.
4. **Measure before merging UI work.** Run `tool/perf_check.sh 60` with the app idle on the board. It must report `ok` in both columns.

## Results

| Build | App idle CPU | App RSS | relayd idle CPU | relayd RSS |
|---|---|---|---|---|
| M0 release, 2026-10-11 | 0.18% | 122 MB | 0.03% | 12 MB |
