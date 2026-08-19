# Codex Guard — Keep Codex Desktop Running

A self-contained desktop watchdog for the **Codex / ChatGPT desktop app**. When the model reports
`Selected model is at capacity`, the goal auto-pauses, or a turn stalls, **Codex Guard restores the
goal with a single zero-input click** — no token spend, no context bloat.

![guarding](screenshots/state-1-guarding-running.png) ![stopped](screenshots/state-2-guard-stopped.png)
*Left: guard running · turn running (green). Right: guard stopped (grey).*

## Features

- **Goal auto-restore** — detects a paused/stalled goal in the desktop app and clicks `Restore Goal`
  (zero new input tokens). Model is locked to `gpt-5.6-sol`.
- **Live token monitor** — animated ring + stats: current context usage / window limit / cumulative
  tokens / compaction count / guard state (polled every 3s from the session JSONL).
- **Real-time work status** (top-right, via UI Automation): `guarding · running`, `goal paused`,
  `capacity error`, `idle`, `desktop not running`.
- **Guard gating** — cooldown, dedupe, hourly send cap and a context-budget gate (fail-closed) so the
  auto-pilot never burns input tokens or blows up the context window.
- **Anti double-start** — the Start button greys out while the guard is running; only Stop stays active.
- **Aesthetic UI** — dark gradient theme, breathing status light, glossy gradient buttons with
  per-button effects (blue shine / red rise-fill), click ripple, DPI-aware (PerMonitorV2), all
  content scales with the window (uniform factor k).
- **Self-contained EXE** — all scripts are embedded (Base64) into the single desktop EXE; nothing
  external is needed except PowerShell 7.

## Requirements

- Windows 10/11
- [PowerShell 7+](https://github.com/PowerShell/PowerShell) (`pwsh` on PATH)
- Codex / ChatGPT desktop app running (the app being watched)

## Quick Start (recommended)

1. Download `CodexGuard.exe` from [Releases](../../releases) and put it on your Desktop.
2. Double-click it. The guard auto-polls the desktop app every 3 seconds.
3. Click **Start Guard** — the button greys out, the top-right status turns green
   `guarding · running`.
4. Minimize the window; the guard keeps working (it restores/minimizes itself around actions).
5. Click **Stop Guard** when done.

> The EXE embeds all scripts and re-extracts them to `%USERPROFILE%` on first run if missing.

## Build from Source

```powershell
# 1) place the 5 scripts from src/ + build-exe.ps1 into %USERPROFILE%
# 2) build the desktop EXE
.\build-exe.ps1
# -> produces Desktop\CodexGuard.exe with all scripts embedded
```

## Scripts

| Script | Purpose |
|---|---|
| `src/codex-desktop-drive.ps1` | UIA driver: `status` / `send` / `model` / `goal` / `watch` (the guard loop) |
| `src/codex-watch-background.ps1` | Background launcher: `start` / `stop` / `status` / `logs`, loop mode |
| `src/codex-desktop-feeder.ps1` | Headless feeder via the local app-server (same engine as the desktop app, shared sessions) |
| `src/codex-relay-switch.ps1` | Upstream relay health probe + relay switch with auto-rollback (fixes `at capacity` at the source) |
| `src/codex-session-health.ps1` | Long-session degradation scanner: `scan` / `signals` / `mitigate` (compact or fresh thread) |
| `build-exe.ps1` | Builds the self-contained desktop EXE (embeds the scripts as Base64) |

## How the Guard Loop Works

```
capacity error / goal paused / turn stalled
        -> backoff (30s..300s exponential, sol only, no model switch)
        -> click "Restore Goal" (zero input tokens)
        -> goal resumes on gpt-5.6-sol
text "continue" is the ABSOLUTE last resort, and only when:
  no goal exists AND all four gates pass (cooldown / dedupe / hourly cap / context budget)
```

## License

MIT
