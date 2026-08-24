---
purpose: Inventory of the reusable UI components stories 2.x and 3.x must consume rather than redefine.
updated: 2026-08-24
source: App/Sources/DesignComponents.swift
---

# Design components — read this before writing a view

Story 1.1 created `DesignComponents.swift` so later stories would consume its components
instead of redefining them (UX-DR2). That intent lived in a paragraph of the spec, where no
later session ever saw it — and story 1.5 duly reimplemented the filter field byte-for-byte
(finding **D-1** of the epic 1 retrospective). This file is that intent made into an artifact.

**Rule.** Before writing a view, check this table. If a component fits, use it. If one nearly
fits, extend it here rather than copying it into your view. If you add a component, add its
row — an unrecorded component is the next D-1.

## Components

| Component | Use for | Notes |
|---|---|---|
| `StatusPill` | machine health | Colour **and** label — colour alone fails the accessibility floor |
| `PillButtonStyle` | any button | `.primary`, `.secondary`, `.destructive`, `.critical` |
| `TabPillStyle` | tab selection | Selected = ink surface; pair with `focusRing(onDark: true)` |
| `OverflowRow` | a one-line row of items that may not fit | Visible items + trailing `…` menu. See below |
| `FilterField` | filtering a list, focused by ⌘F | Pass your **own** `@FocusState` — ⌘F arrives from outside the field |
| `SidebarRow` | sidebar entries | |
| `MachineBanner` | a machine's pastel header | Block colour comes from `MachineBlockStore` |
| `ConfirmationSheet` | destructive confirmations | Names the consequence, not just the act |
| `ToastView` | transient feedback | |
| `DataTable` / `DataColumn` | any tabular data | |
| `EmptyStateView` | a tab with nothing yet | **Must name the story that fills it** |
| `focusRing(_:cornerRadius:onDark:)` | focus on a custom `ButtonStyle` | Custom styles suppress the system ring |
| `statusReasons(_:)` | rendering `[MachineIssue]` | The single health ladder — never re-derive it |

## `OverflowRow` — the one with a trap

Keeps a row on one line: what fits stays visible, the rest folds into a trailing `…` menu.
It replaced the horizontal `ScrollView` of the tab bar and the action bar, which hid its own
overflow (`showsIndicators: false`) and, at the nominal 1040pt width, left the last pill flush
against the edge, reading as a broken control.

Two things to know before reusing it:

- **The candidate splits are enumerated, not generated** — a `ForEach` inside `ViewThatFits`
  collapses to one candidate. Ten candidates are written out, which caps a row at **nine**
  visible items. A row that could hold more needs more candidates written by hand.
- **Pass a real `isActive`** when the row carries a selection. The `…` button takes the
  selected appearance when a folded item is the active one; without it, selecting a folded
  tab leaves the bar showing no selection at all — worse than the overflow it replaced.

## Where the pure logic lives

Anything testable belongs in `Sources/HomePortKit/`, not in a view: `MachineBlock`,
`FleetRow`, `MachineIssue`, `LogLines` are already there. `App/Sources` is compiled by the
verify gate but is covered by **no unit test** (retrospective action item 8) — logic placed
there ships unasserted.
