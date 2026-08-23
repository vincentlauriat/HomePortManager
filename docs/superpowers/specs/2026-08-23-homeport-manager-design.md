# HomePortManager — Design Specification

**Date:** 2026-08-23
**Status:** Approved by Vincent (brainstorming session) — **v1 IMPLEMENTED and validated in
production on raspcorse + raspyellow (2026-08-23)**. See "Implementation deltas" at the end.
**Scope:** v1 — CLI + core library. The macOS app is v2 and out of scope here.

## Purpose

HomePortManager manages the full life cycle of multiple [Homeport](https://github.com/vincentlauriat/homeport)
instances (home server dashboard) running on Raspberry Pi or other Debian/systemd machines:
install, update, backup, restore, configuration management, removal, and a fleet status view.

It replaces the current manual deployment (`git archive | ssh … tar` + `install.sh`) with a
single tool driven from Vincent's Mac.

## Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Form | CLI + macOS app; **CLI first** (v1), app later (v2) on the same library |
| Stack | Swift — SwiftPM package: library `HomePortKit` + executable `hpm` |
| Install source | **GitHub releases/tags** of `vincentlauriat/homeport` |
| Execution model | **Agentless, pure SSH** from the Mac (Tailscale); nothing installed on the Pis |
| Backups | **Both**: local copy on the machine + pulled to the Mac |
| v1 scope | Lifecycle + restore + fleet status + config management + machine prerequisites |

## Architecture

One SwiftPM package, two targets:

- **`HomePortKit`** (library) — all the logic: inventory, GitHub release resolution,
  SSH orchestration, backup rotation, config diffing. Built around an injectable
  `ProcessRunner` protocol so everything is testable without a real machine.
- **`hpm`** (executable) — thin CLI over the library, using `swift-argument-parser`.

All remote work goes through `/usr/bin/ssh` / `scp` subprocesses, so the user's existing
SSH config and Tailscale network apply unchanged. The remote machine never needs to reach
GitHub: the Mac downloads the release tarball (cached in `~/.cache/hpm/`) and pushes it
over scp.

### Remote layout (as defined by Homeport's own `deploy/install.sh`)

- App: `/opt/homeport` (+ venv inside)
- Config: `/etc/homeport` (preserved by install.sh)
- Data: `/var/lib/homeport` (SQLite)
- Unit: `homeport.service`
- On-machine backups: `/var/backups/homeport/`

## Inventory

`~/.config/hpm/fleet.yaml` — the list of managed machines:

```yaml
machines:
  - name: raspcorse
    ssh: raspcorse        # anything `ssh <value>` accepts (host alias, user@host…)
    port: 80              # Homeport HTTP port for healthz checks
    notes: "Pi 5, Corse, Starlink LAN"
```

No secrets in this file — authentication is SSH's job. Managed with
`hpm machine add/list/remove`.

## Commands (v1)

- **`hpm status [--all|<machine>]`** — fleet view: installed version vs latest GitHub
  release, systemd service state, `/healthz` result, date of last backup (Mac side).
- **`hpm releases`** — list available GitHub tags/releases.
- **`hpm prereqs <machine> [--fix]`** — check systemd, python3-venv, rsync, sudo access;
  `--fix` installs missing packages via apt.
- **`hpm install <machine> [--version vX.Y.Z]`** — download release tarball on the Mac
  (cache), scp + extract to the machine, run `deploy/install.sh`, verify `/healthz`.
  Defaults to the latest release.
- **`hpm update [--all|<machine>] [--version]`** — automatic backup first, then the same
  pipeline as install (install.sh is idempotent), then `/healthz`. Recovery path on
  failure: `hpm restore`.
- **`hpm backup [--all|<machine>]`** — archive `/etc/homeport` + `/var/lib/homeport`
  (SQLite copied consistently via `sqlite3 .backup` when available, plain copy otherwise).
  Stored on the machine (`/var/backups/homeport/`, keep 3) **and** pulled to the Mac
  (`~/HomePortBackups/<machine>/`, keep 10, timestamped and tagged with the Homeport
  version).
- **`hpm restore <machine> [--latest|--archive <file>]`** — restore config + data,
  restart, verify `/healthz`. Works across machines (migration).
- **`hpm config pull|diff|push <machine> [file]`** — fetch `services.yaml` & co locally,
  show a diff before pushing, reload after push.
- **`hpm remove <machine>`** — final backup, then complete uninstall (service unit,
  `/opt/homeport`, `/etc/homeport`, `/var/lib/homeport`) with explicit confirmation.

## Behaviour and error handling

- Every command prints its steps as it goes and stops at the first failure with an
  actionable message — never a silent half-state.
- `/healthz` checks always run **through SSH** (`curl -fsS http://localhost:<port>/healthz`
  on the machine), never from the Mac directly — so they work regardless of LAN/Tailscale
  reachability of the HTTP port.
- Destructive operations (`remove`, `restore`, `config push`) require explicit
  confirmation.
- `--all` processes machines sequentially and ends with a per-machine summary.
- `update` always backs up before touching anything.

## Testing

- Unit tests on `HomePortKit` with a mocked `ProcessRunner`: fresh install, update with
  failing healthz, backup rotation, config diff, inventory round-trip, GitHub release
  parsing.
- Final real-world validation on raspcorse and raspyellow before declaring v1 done.

## Out of scope (v2 candidates)

- macOS app (AppKit/SwiftUI on top of `HomePortKit`)
- Scheduled backups
- Parallel `--all`
- Deploying from the local, unreleased Homeport repo

## Known constraint

Installing from GitHub releases means only tagged versions are deployable. (v0.5.0, tagged
2026-08-22, covered the previously unreleased Livebox module — constraint moot in practice.)

## Implementation deltas (learned during real-world validation, 2026-08-23)

The v1 implementation follows this spec, with four corrections the real machines forced:

1. **Data dir is resolved, not assumed.** A systemd drop-in may override
   `HOMEPORT_DATA_DIR` (raspcorse keeps data on `/mnt/ssd/homeport-data`;
   `/var/lib/homeport` is empty there). Backup/restore/remove read the effective value
   via `systemctl show homeport -p Environment` (last override wins).
2. **Config pull stages through sudo.** `/etc/homeport/mqtt.env` is root-only (600), so a
   direct scp fails. Files are copied with sudo to `/tmp/hpm-cfg-pull`, chowned to
   `$SUDO_USER`, pulled, then the staging is removed.
3. **Install/update restart the service explicitly.** Homeport's `install.sh` uses
   `systemctl enable --now`, which does NOT restart an already-running unit — without an
   explicit restart the old code keeps serving (observed: healthz said 0.4.0 with 0.5.0
   on disk).
4. **The inventory's `ssh` field earns its place.** raspyellow's Tailscale SSH policy only
   accepts user `vincent`, so its inventory entry is `ssh: vincent@raspyellow`.
