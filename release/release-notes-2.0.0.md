## HomePort Manager 2.0.0

The menu bar app becomes a full unified control center: a dedicated window for
administering the whole fleet, plus in-app auto-update.

### Control center window
- Open from the menu bar (or click the Dock icon): a fleet sidebar and a
  per-machine detail view, keyboard-driven (⌘R refresh, ⌘F filter, ⌘1…⌘8 tabs).
- **Task journal** — every action taken from the console is tracked, with a
  shared mutation lock so concurrent actions on the same machine queue safely
  instead of racing.
- **Machine actions with confirmation** — backup, restart, update; destructive
  by design, never silent.
- **Embedded Homeport dashboard** — the machine's own web dashboard, right
  inside its tab.
- **Centralized logs** — live-tailed `journalctl`, searchable, multi-line
  selection.
- **Updates tab** — installed version vs. the latest tagged GitHub release,
  release notes rendered as Markdown, guided update from the console.
- Trilingual UI (French, English, Chinese).

### Dock presence
- The app now also shows in the Dock, with its own icon, alongside the menu
  bar extra. Clicking the Dock icon reopens the control center.

### Auto-update (Sparkle)
- The app checks for updates in the background and offers them in place —
  "Check for Updates…" from the menu bar footer triggers a check on demand.
- Updates are downloaded from tagged GitHub releases and verified with an
  EdDSA signature before installing.
- Note: installs of 1.0.0 are not on this update channel yet — this first
  2.0.0 download is manual, auto-update takes over from here on.

### Internals
- `HomePortKit` gained a stale-aware update comparator shared between the
  live fleet view and the Updates tab, so an unreachable machine that is
  actually behind no longer reads as "up to date".
- The Homeport API v1 contract (capabilities, events, metrics) is written and
  live in production on the reference machine — the events client and
  historised metrics land in a follow-up release.
