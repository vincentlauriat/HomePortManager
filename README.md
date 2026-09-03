# ⚓ HomePortManager

**Fleet manager for [Homeport](https://github.com/vincentlauriat/homeport) instances — full
life cycle over plain SSH.**

`hpm` installs, updates, backs up, restores, reconfigures and removes Homeport on any number
of Debian/systemd machines (Raspberry Pi or otherwise), from your Mac. Agentless: nothing to
install on the machines — your existing SSH config (and Tailscale) is the only transport.
The machines never need to reach GitHub: the Mac downloads release tarballs and pushes them.

## Install

```bash
git clone <this repo> && cd HomePortManager
swift build -c release
ln -s "$PWD/.build/release/hpm" /usr/local/bin/hpm
```

## Quick start

```bash
hpm machine add raspcorse --ssh raspcorse          # declare a machine (SSH alias or user@host)
hpm prereqs raspcorse --fix                        # check systemd, python3-venv, rsync, sudo
hpm install raspcorse                              # latest GitHub release, then healthz check
hpm status --all                                   # fleet table: version, service, health, last backup
```

## Commands

| Command | What it does |
|---|---|
| `hpm machine add/list/remove` | Manage the inventory (`~/.config/hpm/fleet.yaml`, no secrets); `add --exploit-port <port>` opts a machine into `hpm maintenance`/the app's Maintenance tab |
| `hpm status [m\|--all]` | Installed vs latest version, service state, healthz, last backup |
| `hpm releases` | List Homeport tags/releases on GitHub |
| `hpm prereqs <m> [--fix]` | Verify machine prerequisites, optionally apt-install them |
| `hpm install <m> [--version vX.Y.Z]` | Push tarball, run Homeport's `deploy/install.sh`, verify healthz |
| `hpm update [m\|--all] [--version]` | **Automatic backup first**, then the idempotent install pipeline |
| `hpm backup now [m\|--all]` | Archive `/etc/homeport` + `/var/lib/homeport` (SQLite-safe) right now — kept on the machine (3) **and** on the Mac (`~/HomePortBackups/<m>/`, 10) |
| `hpm backup apply <m> [--schedule expr] [--retention n]` | Declare/update the job (`~/.config/hpm/jobs/<m>.yaml`) and deploy it idempotently as `homeport-backup.service`/`.timer` — an autonomous root script that backs up on schedule, Mac reachable or not (precondition: passwordless sudo). Kept on the machine only (retention 3 by default) — these archives don't sync to the Mac yet (story 3.2) |
| `hpm restore <m> [--archive f]` | Restore config + data (newest local archive by default), restart, verify — works across machines |
| `hpm config pull/diff/push <m> [file]` | Edit `services.yaml` & co locally, diff before pushing; no restart needed |
| `hpm remove <m>` | Final backup, then complete uninstall (type the machine name to confirm) |
| `hpm logs <m> [-n 50] [-f]` | Service journal; `-f` streams live |
| `hpm restart <m>` | Restart the service, verify healthz |
| `hpm doctor <m>` | Full diagnosis: prereqs, service, healthz, version coherence, disk, config drift |
| `hpm unlock <m>` | Release a mutation lock left by a dead or expired process (refuses while its holder is alive and under the 30 min TTL) |
| `hpm maintenance actions\|plan\|run\|history <m>` | Machines with `exploitPort` set: HomePortExploit-delegated actions (`apt-update`, `reboot`/`poweroff`, `docker-update`) — `plan` dry-runs and shows the preview, `run` chains dry-run → confirm → execute, `history` shows what HomePortExploit recorded |

Destructive commands (`update`, `restore`, `config push`, `remove`) ask for confirmation; `--yes`
bypasses it for scripting. `--all` runs machines in parallel (output grouped per machine)
and ends with a per-machine summary. `status` shows uptime, disk usage of the effective
data dir and SSH latency.

## Menu bar app

`App/` contains **HomePort Manager.app** — a SwiftUI menu bar companion on the same
`HomePortKit`: fleet health at a glance (icon turns ⚠️ on any problem), per-machine rows
(version with "→ vX available", uptime, disk, backup age), safe actions (Backup, Restart,
Update — with confirmation and automatic pre-backup — Logs window), macOS notifications on
state transitions only, refresh every 5 min. Restore/remove stay CLI-only by design.

Build a signed, notarized DMG: `./Scripts/release.sh <version>` → `release/HomePortManager-<version>.dmg`.

## Roadmap — unified control center

In progress, on `main` but not yet cut into a release: a **control center window** opened from
the menu bar app — fleet dashboard, per-machine tabs (summary, embedded Homeport dashboard,
logs, events, metrics, backups, shell, updates, maintenance), a central task journal, scheduled
backups that run on the Pi itself via systemd timers, and historised metrics served by
Homeport's own API. Trilingual UI (French, English, Chinese).

- [x] Epic 1 — pilot the fleet from a single window (control center window, task journal,
      confirmed machine actions, embedded Homeport dashboard, centralized logs)
- [ ] Epic 2 — events and metrics: v1 API contract shipped and live on a test machine; the
      event feed client, notifications and historised metric charts are not built yet
- [ ] Epic 3 — scheduled backups, integrated shell; the Updates tab (installed version vs.
      latest tagged release, guided update) is built, taken out of order ahead of scheduled
      backups. `hpm backup apply` (story 3.1) deploys the Pi-side scheduled-backup job —
      `homeport-backup.service`/`.timer` + an autonomous root script that backs up on
      schedule, Mac reachable or not — kit + CLI only; the Backups tab and archive
      consolidation (story 3.2) and the integrated shell (3.4) remain

## Design notes

- One Swift package: `HomePortKit` (all logic, fully unit-tested against a mocked process
  runner) + `hpm` (thin CLI). A future macOS app can link `HomePortKit` directly.
- healthz is always checked from the machine itself (`curl localhost` over SSH), so it works
  whatever way the HTTP port is exposed.
- The installed version is tracked in `/opt/homeport/.hpm-version`, written at install time.
- Removal keeps `/var/backups/homeport` on the machine and every archive on the Mac.

## License

MIT.
