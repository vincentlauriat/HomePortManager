# Changelog

## v1.0.0 — 2026-08-23

First release. Fleet manager for [Homeport](https://github.com/vincentlauriat/homeport)
instances over agentless SSH, driven from a Mac.

### CLI (`hpm`)
- Inventory: `machine add/list/remove` (`~/.config/hpm/fleet.yaml`, no secrets — SSH does auth).
- `status` — fleet table: version vs latest GitHub release, service state, healthz, uptime,
  data-dir disk usage, SSH latency, last backup. Machines queried in parallel.
- `releases`, `prereqs [--fix]`, `install`, `update` (automatic backup first, explicit
  service restart, healthz verification), `backup` (SQLite-safe, kept on the machine ×3
  and on the Mac ×10), `restore` (cross-machine capable), `config pull/diff/push`
  (sudo-staged for root-only files, no restart needed), `remove` (final backup, typed
  confirmation), `logs [-f]`, `restart`, `doctor` (prereqs, service, healthz, marker/runtime
  version coherence, disk, config drift).
- `--all` runs machines in parallel with per-machine grouped output and a summary.
- Data directory resolved from systemd (`HOMEPORT_DATA_DIR` drop-ins honoured).

### Menu bar app (`HomePort Manager.app`)
- SwiftUI `MenuBarExtra`: fleet health icon, per-machine rows (version with update hint,
  uptime, disk, backup age), safe actions (Backup, Restart, Update with confirmation and
  pre-backup, Logs window). Restore/remove stay CLI-only by design.
- Refresh every 5 minutes; macOS notifications on state transitions only.
- Distributed as a signed, notarized, stapled DMG (`Scripts/release.sh`).

### Internals
- One Swift package: `HomePortKit` library (all logic, 80 unit tests against a mocked
  process runner) + thin `hpm` CLI; the app links the same library.
