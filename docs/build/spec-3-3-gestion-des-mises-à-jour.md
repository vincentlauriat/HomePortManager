---
title: 'Gestion des mises à jour'
type: 'feature'
created: '2026-08-26'
status: 'in-progress'
review_loop_iteration: 1
context: ['{project-root}/docs/build/epic-3-context.md']
baseline_commit: '3ed0e0c8c7d0485d3720ea5e45923dace7407d08'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** L'onglet Updates de la fiche machine n'affiche qu'un message d'attente
(`pendingMessage` nommant la story 3.3) : impossible de voir la version installée face à la
dernière release Homeport taguée, ni de déclencher une mise à jour sans quitter l'app pour le
CLI.

**Approach:** Construire le contenu réel de l'onglet en réutilisant la tuyauterie déjà en
place — action `FleetModel.Action.update`, verrou/journal via `journaled(...)` côté
`HomeportManager.update(on:version:)`, `ConfirmationSheet` — et étendre `ReleaseService` pour
exposer les notes de la dernière release, jusqu'ici absentes du modèle.

## Boundaries & Constraints

**Always:** Seules les releases GitHub taguées sont proposées (NFR5, déjà garanti par
`ReleaseService`, ne pas le redémontrer). Toute mutation déclenchée depuis l'onglet passe par
`HomeportManager.update(on:version:)` existant — même verrou (AD-12), même journal, même
parité CLI (FR11) que le bouton Update déjà câblé au Résumé. Confirmation destructive
obligatoire via `ConfirmationSheet` (UX-DR6) avant toute mutation. La comparaison de version
installée vs dernière taguée passe par une seule règle pure partagée entre `machineIssues`
(verdict live, `Sources/HomePortKit/MachineIssue.swift`) et l'onglet Updates (verdict
stale-aware, contre `model.displayStatus(for:)`) — jamais deux implémentations de la même
comparaison. `hpm releases` et `hpm update <machine>` continuent de fonctionner sans
régression.

**Ask First:** si l'ajout d'un champ notes à `Release`/`APIRelease` (ReleaseService.swift)
casse un test ou un consommateur existant non repéré par l'investigation, HALT et demander
plutôt que de contourner silencieusement.

**Never:** pas de sélecteur multi-versions (choisir une release autre que la plus récente) —
hors scope, l'action reste pinée sur `latestTag` comme le fait déjà le bouton Update du
Résumé. Pas de nouvel appel direct à `HistoryStore.acquireLock`/`releaseLock`. Ne pas modifier
`Manager+Install.swift`, `Manager+Journal.swift`, `HistoryStore.swift` ni
`Sources/hpm/Commands.swift` — leur comportement est déjà correct et hors scope de cette
story.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| À jour | `installedVersion == latestTag` | Badge « à jour », pas de notes affichées, bouton de mise à jour désactivé ou absent | N/A |
| Update disponible | `installedVersion != latestTag`, `issues.availableUpdate` non nil | Version installée + dernière version taguée + notes de release affichées, bouton « Mettre à jour maintenant » actif | N/A |
| Update déclenché et confirmé | Vincent confirme la sheet | `run(.update, on: machine)` s'exécute sous verrou, progression affichée, boutons de la machine désactivés (`busy`), résultat journalisé | Échec d'exécution → `lastError` affiché, comme les autres actions |
| Releases indisponibles | `ReleaseService.list()`/`.latest()` lève | Empty state d'erreur, pas de crash, bouton de mise à jour désactivé | Erreur non fatale, cohérente avec le pattern des autres onglets |
| Machine injoignable | `model.statuses[machine.name]` absent | Empty state « état indisponible » + Réessayer, cohérent avec Dashboard/Logs | N/A |
| Mutation déjà en cours (autre action) | `model.inFlight[machine.name] != nil` | Onglet cohérent avec le reste de la fiche : boutons désactivés, bandeau d'activité visible | N/A |

</frozen-after-approval>

## Code Map

- `Sources/HomePortKit/ReleaseService.swift` -- `Release`/`APIRelease` (ligne ~3-26) n'ont
  aucun champ notes ; `latest()` (ligne ~45) = `list().first`, `list()` (ligne ~35) tape
  `GET /repos/{repo}/releases` (fallback `/tags`) via `runner.run("/usr/bin/curl", …)`.
- `Tests/HomePortKitTests/ReleaseServiceTests.swift` -- pattern `MockProcessRunner.stub(...)`
  à reproduire pour tester le nouveau champ notes.
- `App/Sources/FleetModel.swift` -- `Action.update` (ligne ~219, `needsConfirmation`/
  `isDestructive` = true) déjà déclaré ; `run(_:on:)` (ligne ~321) gère `inFlight`, pin de
  `latestTag` à la confirmation, appel manager en `Task` détachée, `reloadTasks()` +
  `refresh()` en fin ; `statuses[machine.name]`, `latestTag` rafraîchis en cycle (ligne ~185,
  ~193).
- `Sources/HomePortKit/MachineIssue.swift` -- `machineIssues(_:latest:)` (ligne ~40) produit
  `.updateAvailable(String)`.
- `App/Sources/DesignComponents.swift` -- `issues.availableUpdate` (ligne ~80) ; composants à
  réutiliser : `PillButtonStyle` (ligne ~107), `ConfirmationSheet` (ligne ~379, gère déjà
  `.update`), `StatusPill` (ligne ~85), `DataTable`/`DataColumn` (ligne ~446+) si besoin d'une
  liste, `EmptyStateView` (ligne ~578, rend aujourd'hui le placeholder story 3.3).
- `App/Sources/MachineDetailView.swift` -- `enum MachineTab` (ligne ~6) : `case updates`
  (ligne ~14) + `pendingMessage` (ligne ~41, à remplacer) ; `fillsSheet` (ligne ~51, `false`
  pour `.updates`) ; `content` (ligne ~262-269) route les onglets non pleine-fenêtre ;
  `versionValue` (ligne ~402-415) affiche déjà la comparaison sur le Résumé — modèle direct à
  reprendre pour l'onglet ; sheet + switches `sheetTitle`/`sheetConsequence`/
  `sheetConfirmTitle` (lignes ~179-215) déjà câblés pour `.update`, clé `confirm.update`
  (ligne ~210) ; `busy` guard sur `.disabled` (lignes ~131, ~158, ~175) à reprendre pour le
  bouton de l'onglet.
- `App/Sources/MachineBanner` (dans DesignComponents.swift, ligne ~340-363) -- `activity`/
  `progressLabel` déjà branchés sur `model.inFlight[machine.name]`, rien à ajouter.
- `App/Sources/Localizable.xcstrings` -- nouvelles clés de l'onglet (titre, libellé « à jour »,
  libellé notes, bouton) en `en`/`fr`/`zh-Hans` ; le pattern `confirm.update` existe déjà.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/HomePortKit/ReleaseService.swift` -- ajouter un champ notes (`body`) à
      `APIRelease` et `Release`, parsé depuis la réponse GitHub -- l'AC 1 exige les notes de la
      dernière release, absentes du modèle actuel.
- [x] `Tests/HomePortKitTests/ReleaseServiceTests.swift` -- couvrir le nouveau champ (présent,
      absent/`null`, release sans notes) -- garantir la non-régression de `list()`/`latest()`.
- [x] `App/Sources/MachineDetailView.swift` -- retirer le `pendingMessage` de `.updates`,
      router vers le nouveau contenu de l'onglet -- remplace le placeholder par le vrai
      comportement.
- [x] `App/Sources/UpdatesTabView.swift` (nouveau) -- vue de l'onglet : version installée vs
      `latestTag`, notes de la dernière release, bouton de mise à jour réutilisant
      `pendingAction`/`ConfirmationSheet` et le guard `busy`, empty states (erreur releases,
      machine injoignable) via `EmptyStateView` -- cœur de la story, toute la tuyauterie
      d'action est déjà fournie par `FleetModel`.
- [x] `App/Sources/Localizable.xcstrings` -- clés de l'onglet en `en`/`fr`/`zh-Hans`, aucune
      chaîne en dur (UX-DR4).
- [x] `Tests/HomePortKitTests/` ou app -- test couvrant l'I/O Matrix côté modèle (au minimum le
      champ notes de `ReleaseService` ; la logique UI SwiftUI non testable unitairement se
      vérifie manuellement, cf. Verification).

**Acceptance Criteria:**
- Given l'onglet Updates d'une machine joignable, when il s'affiche, then la version installée
  et la dernière release taguée (avec ses notes) sont visibles, et seules des versions taguées
  sont proposées comme cible.
- Given un update déclenché depuis l'onglet, when Vincent confirme la sheet destructive, then
  l'update s'exécute sous verrou (AD-12), sa progression s'affiche, les boutons de la machine
  sont désactivés le temps de la mutation, et le résultat atterrit dans le journal des tâches.
- Given le CLI, when `hpm releases` et `hpm update <machine>` s'exécutent, then leur
  comportement existant (verrou, journal, confirmation) est inchangé.

### Review Findings

- [x] [Review][Decision→Patch] `.releasesUnavailable` conflate « pas encore chargé » et « échec du
      fetch », masquant la version installée d'une machine par ailleurs joignable. **Résolu** :
      `FleetModel.releasesUnavailable` (nouveau `@Published`) distingue désormais « le dernier
      fetch a réellement levé » de « pas encore résolu » ; `UpdatesTabView.State` gagne un cas
      `.checkingReleases(installed:)` qui affiche la version installée sans revendiquer de
      verdict de mise à jour. [`App/Sources/FleetModel.swift`, `App/Sources/UpdatesTabView.swift`]
- [x] [Review][Patch] `.upToDate(installed: "unknown")` était atteignable — badge « à jour » trompeur
      pour une machine dont la version n'a pas pu être lue. **Résolu** : nouveau cas
      `.versionUnknown`, intercepté avant la comparaison, routé vers un empty state dédié
      [`App/Sources/UpdatesTabView.swift`]
- [x] [Review][Patch] Les notes de release perdaient leur structure (sauts de ligne) au rendu —
      `AttributedString(markdown:)` par défaut traite `\n` comme un soft break et le collapse en
      espace. **Résolu** : parsing explicite `.inlineOnlyPreservingWhitespace`
      [`App/Sources/UpdatesTabView.swift`]
- [x] [Review][Patch] Le commentaire au-dessus de `content` promettait un échec visible sur un
      invariant de routage rompu, mais les deux branches du switch retombaient silencieusement sur
      un rendu vide. **Résolu** : `assertionFailure` ajouté aux deux branches
      [`App/Sources/MachineDetailView.swift`]
- [x] [Review][Patch] `versionRow` n'avait pas de libellé d'accessibilité descriptif. **Résolu** :
      `accessibilityLabel` explicite (« Installed X » / « Installed X, update to Y »)
      [`App/Sources/UpdatesTabView.swift`]
- [x] [Review][Defer] Le badge flèche de version du Résumé (`versionValue`/`issues.availableUpdate`)
      utilise toujours le verdict live, non stale-aware — le bug exact que cette story a corrigé pour
      l'onglet Updates (une machine injoignable avec du retard réel affiche « à jour ») reste vivant
      sur la vue par défaut de la fiche machine [`App/Sources/MachineDetailView.swift:83-85,398-410`]
      — deferred, pre-existing (hors du périmètre gelé de cette story, qui a explicitement scindé
      `machineIssues`=verdict live / onglet Updates=verdict stale-aware dans le Spec Change Log)

## Spec Change Log

- **2026-08-27 — intent_gap (revue step-04, `blind-hunter` + `edge-case-hunter`).** La
  première implémentation lisait `issues.availableUpdate` (dérivé du statut *live*
  `model.statuses[machine.name]`) pour décider « à jour » vs « mise à jour disponible ».
  `machineIssues` retombe à `[.unreachable]` (aucun `.updateAvailable`) dès qu'une machine est
  injoignable — donc une machine injoignable mais réellement en retard affichait « à jour »,
  juste à côté de la notice « données obsolètes ». Root cause : la contrainte gelée
  (« réutilise `issues.availableUpdate`, aucune logique dupliquée ») interdisait la seule
  façon correcte de faire ce calcul en restant stale-aware. **Amendement :** la contrainte
  « Always » de comparaison de version a été reformulée pour exiger une règle pure partagée
  (`updateTarget(installed:latest:)` dans `Sources/HomePortKit/MachineIssue.swift`, appelée
  par `machineIssues` pour le verdict live et par l'onglet Updates pour le verdict
  stale-aware) plutôt que la réutilisation littérale d'`issues.availableUpdate`. **KEEP :**
  tout le reste de l'implémentation d'origine (tuyauterie d'action, ConfirmationSheet,
  empty states, extraction de `LastActionErrorView`/`StaleDataNotice`, champ notes sur
  `ReleaseService`) était correct et a été conservé tel quel — seul `UpdatesTabView.state` et
  `machineIssues` ont été retouchés pour passer par la règle partagée.

## Design Notes

**Aucune nouvelle mécanique d'action.** `FleetModel.Action.update` existe déjà avec
confirmation, verrou et progression câblés depuis story 1.3 — cette story est presque
entièrement une story de *présentation* (contenu de l'onglet + notes de release), pas de
plomberie neuve. Résister à la tentation d'ajouter un sélecteur de version ou un chemin
d'exécution parallèle : le scope de l'AC est « comparer et déclencher », pas « choisir ».

## Verification

**Commands:**
- `swift build` -- expected: compilation sans erreur.
- `swift test` -- expected: suite verte, dont les tests `ReleaseService` étendus, aucune
  régression.
- `cd App && xcodegen generate && xcodebuild -project HomePortMenu.xcodeproj -scheme HomePortMenu -configuration Debug build CODE_SIGNING_ALLOWED=NO` -- expected: `BUILD SUCCEEDED`.
- `git status --porcelain` -- expected: seuls les fichiers de la story modifiés.

**Manual checks (if no CLI):**
- Machine à jour : badge « à jour », pas de bouton actif.
- Machine avec update disponible : versions + notes affichées, bouton actif, sheet de
  confirmation nommant la machine et la version cible, mise à jour visible dans Tâches
  récentes après exécution.
- Machine injoignable : empty-state cohérent avec Dashboard/Logs, pas de trace brute.
- Bascule fr/zh-Hans : libellés traduits.

## Suggested Review Order

**Le bug corrigé en revue — verdict stale-aware**

- Le comparateur pur que `machineIssues` et l'onglet Updates partagent désormais — root cause
  de l'intent_gap : une machine injoignable avec du retard réel affichait « à jour ».
  [`MachineIssue.swift:58`](../../Sources/HomePortKit/MachineIssue.swift#L58)

- `machineIssues` délègue au comparateur au lieu de répéter la comparaison en ligne.
  [`MachineIssue.swift:40`](../../Sources/HomePortKit/MachineIssue.swift#L40)

- Le verdict de l'onglet, calculé contre `display.status` (stale-aware) et non `issues` (live).
  [`UpdatesTabView.swift:45`](../../App/Sources/UpdatesTabView.swift#L45)

- Le test qui aurait dû exister avant l'implémentation initiale — couvre les trois règles.
  [`MachineIssueTests.swift:70`](../../Tests/HomePortKitTests/MachineIssueTests.swift#L70)

**Cœur de la story — l'onglet Updates**

- Le point d'entrée : quatre états (injoignable, releases indisponibles, à jour, disponible),
  chacun routé vers l'empty state ou le contenu attendu.
  [`UpdatesTabView.swift:12`](../../App/Sources/UpdatesTabView.swift#L12)

- Le routage explicite par `switch tab` qui remplace le `pendingMessage` générique — le seul
  point d'intégration dans la fiche machine.
  [`MachineDetailView.swift:265`](../../App/Sources/MachineDetailView.swift#L265)

- Les notes de la dernière release, rendues en Markdown plutôt qu'en source brute, publiées
  dans le même cycle que `latestTag` — pas de second appel réseau.
  [`FleetModel.swift:20`](../../App/Sources/FleetModel.swift#L20)

**Réutilisation — pas de nouvelle mécanique d'action**

- `LastActionErrorView` et `StaleDataNotice`, extraits de `MachineDetailView` pour être
  partagés par le Résumé et l'onglet Updates sans divergence de rendu.
  [`DesignComponents.swift:454`](../../App/Sources/DesignComponents.swift#L454)

**Périphériques**

- Le champ notes ajouté à `Release`/`APIRelease`, seule extension du modèle réseau.
  [`ReleaseService.swift:8`](../../Sources/HomePortKit/ReleaseService.swift#L8)

- Ses tests (notes présentes, `null`, absentes, fallback `/tags`).
  [`ReleaseServiceTests.swift:29`](../../Tests/HomePortKitTests/ReleaseServiceTests.swift#L29)
