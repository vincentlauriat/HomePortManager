# HomePort Menu Bar App — Design Specification (v2)

**Date:** 2026-08-23
**Status:** Draft — pending Vincent's review
**Scope:** v2 — macOS menu bar app on top of `HomePortKit`. The CLI (`hpm`) remains the
full-featured interface; the app covers day-to-day supervision and safe actions.

## Purpose

A macOS menu bar app showing the Homeport fleet's health at a glance and offering the safe
life-cycle actions (backup, restart, update, logs) without opening a terminal. Destructive
operations (restore, remove) deliberately stay CLI-only.

## Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Form | Menu bar app (no main window) |
| UI stack | SwiftUI `MenuBarExtra` (macOS 13+) |
| Actions | Safe only: backup, restart, update (with confirmation), logs. No restore/remove |
| Refresh | Fleet status every 5 min + on menu open; macOS notifications on state change |
| Distribution | Signed + notarized DMG from day one (standard release.sh pipeline) |

## Architecture

A signed, notarized `.app` bundle cannot be a plain SwiftPM executable target, so the app
gets its own xcodegen project that consumes the package. Structure:

- The SwiftPM package keeps `HomePortKit` + `hpm` as-is.
- New `App/` directory with an xcodegen `project.yml` producing `HomePort Manager.app`
  (bundle id `fr.lauriat.homeport-manager`), which depends on the local SwiftPM package
  (`HomePortKit` only).
- `LSUIElement = true` (no Dock icon), single `MenuBarExtra` scene.

### Components

- **`FleetModel`** (`@MainActor ObservableObject`) — owns the fleet list (FleetStore),
  the latest `MachineStatus` per machine, the latest GitHub release tag, and a 5-minute
  timer. All `HomePortKit` calls run on a background queue (they are blocking ssh
  subprocesses); results are published back on the main actor.
- **`StatusIcon`** — menu bar symbol reflecting the aggregate: all green → `checkmark.circle`;
  any warning (unreachable, inactive, FAIL, update available) → `exclamationmark.triangle`;
  refresh in progress → subtle progress indicator.
- **Menu content** (SwiftUI):
  - One section per machine: name + colored dot, version (`v0.5.0 → v0.6.0 available` when
    behind), uptime, disk %, last backup age.
  - Per-machine submenu: Backup now, Restart (confirm), Update to latest (confirm sheet),
    Show logs (opens a scrollable window with the last 100 lines, refresh button).
  - Footer: "Backup all", "Refresh now", "Open fleet.yaml", "Quit".
- **`Notifier`** — `UserNotifications`: one notification when a machine transitions
  red↔green or becomes unreachable, and one when an update finishes (success/failure).
  No repeat-nagging: state transitions only.

### Long-running actions

Backup/update/restart run on a background task; the machine's menu row shows a spinner and
the action items are disabled for that machine while one is in flight. Errors surface as a
notification + a warning row in the menu (with the message), never a modal alert.

## Error handling

- Unreachable machine → row shows "unreachable" (grey), no notification storm (one on
  transition).
- GitHub unreachable → "latest" unknown; update action disabled with explanatory tooltip.
- All action errors carry the same actionable messages as the CLI (they come from
  `HomePortKit`'s `HPMError`).

## Testing

- `FleetModel` logic (aggregation, transition detection for notifications, in-flight
  bookkeeping) unit-tested with the existing `MockProcessRunner` via injected manager
  factories.
- UI states verified manually (menu bar apps have little UI-test value for this size).
- Real-world validation against raspcorse/raspyellow before the first DMG.

## Distribution

Standard pipeline from the shared conventions (`macos-app-release`): xcodegen, build
Release with manual signing, Developer ID `Vincent LAURIAT (KFLACS69T9)`, notarization
profile `AppliMacVincentGithub`, stapled DMG in `release/`. No Sparkle in v2.0 (updates
ship as new DMGs); Sparkle is a v2.x candidate.

## Out of scope (v2)

- Restore / remove from the app (CLI-only by design)
- Scheduled backups (separate feature, likely launchd + CLI, app-independent)
- iOS companion, widgets
