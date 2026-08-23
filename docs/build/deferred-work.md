- source_spec: `docs/build/spec-1-1-fenêtre-centre-de-contrôle-et-tableau-de-bord-global.md`
  summary: App/Sources n'est pas dans le graphe SwiftPM, donc swift test ne compile jamais le code de l'app.
  evidence: Package.swift ne déclare que HomePortKit, hpm et HomePortKitTests. MachineBlockStore (persistance UserDefaults), FleetModel (écriture des caches lastReachableStatus/lastSeenAt) et Color(hex:) n'ont aucun test possible ; seul xcodebuild les compile. Les 107 tests verts ne disent rien de ce code.

- source_spec: `docs/build/spec-1-1-fenêtre-centre-de-contrôle-et-tableau-de-bord-global.md`
  summary: reloadFleet() avale les erreurs de parsing YAML, rendant un fleet.yaml malformé indistinguable d'un fichier vide.
  evidence: `machines = (try? FleetStore().load().machines) ?? []` dans App/Sources/FleetModel.swift. L'état vide invite alors à déclarer une première machine à un utilisateur dont le fichier en contient déjà mais ne parse pas, et le bouton de rechargement ne rend ni succès ni échec.

- source_spec: `docs/build/spec-1-1-fenêtre-centre-de-contrôle-et-tableau-de-bord-global.md`
  summary: Aucune typographie dynamique — l'interface ne peut pas honorer un réglage de taille de texte agrandi.
  evidence: Theme.sans/mono construisent leurs Font en .custom(_, fixedSize:) ou .system(size:), et Metrics.tableRowHeight = 26, les largeurs de colonnes 55-100 px, frame(width: 170) des libellés de résumé et les lineLimit(1) généralisés figent la mise en page.

### DW-1: Aucun test n'exécute la couche CLI (dont TasksCmd) : le câblage --machine/--limit/--id vers HistoryStore n'est vérifié que par les tests kit et un contrôle manuel.
origin: spec-deferred 759e54980b3f
location: Sources/hpm/Commands.swift (TasksCmd)
source_spec: `spec-1-2-journal-des-tâches-et-socle-hpm-db.md`
severity: medium
reason: Motif pré-existant à tout le repo : aucun test target ne dépend de l'exécutable hpm (Package.swift), aucune commande n'a jamais été testée. TasksCmd.run instancie HistoryStore() au chemin réel, ce qui bloque aussi un futur test in-process — remplacer `store.tasks(machine: machine, ...)` par `machine: nil` passerait inaperçu de `swift test`.
status: open

### DW-2: Le site d'invocation de la purge (démarrage app, NFR7) n'est couvert par aucun test — seule la mécanique de purge du store l'est.
origin: spec-deferred 522245403933
location: App/Sources/FleetModel.swift (init)
source_spec: `spec-1-2-journal-des-tâches-et-socle-hpm-db.md`
severity: low
reason: Le seul appelant de purge() en production est FleetModel.init (Task.detached) ; le target App n'a aucun test (pré-existant au repo). Supprimer le bloc de purge de l'init laisserait toute la suite verte. Piste : un helper kit testable (p. ex. HistoryStore.openPurging()) adopté par FleetModel.
status: open

### DW-3: La documentation utilisateur ne mentionne ni `hpm tasks` (et ses options), ni la section Historique de l'app, ni l'emplacement de ~/.local/state/hpm/hpm.db.
origin: spec-deferred d4fdc71da89c
location: n/a
source_spec: `spec-1-2-journal-des-tâches-et-socle-hpm-db.md`
severity: low
reason: Aucun fichier de doc n'apparaît dans le diff de la story ; le README du projet liste les capacités CLI existantes et devra intégrer la nouvelle commande à la prochaine passe de doc.
status: open

### DW-4: Le câblage journal côté app (rechargement après une action, branche « journal indisponible » vs « aucune tâche », filtre par nom exact de machine) n'a aucune vérification exécutable.
origin: spec-deferred 3981dd9155bc
location: App/Sources/FleetModel.swift, App/Sources/FleetOverviewView.swift, App/Sources/MachineDetailView.swift
source_spec: `spec-1-2-journal-des-tâches-et-socle-hpm-db.md`
severity: low
reason: Le target App n'a aucun test (pré-existant au repo). Supprimer le reloadTasks() inconditionnel à la complétion d'une action — la régression corrigée par une passe précédente — ou inverser la branche !model.historyAvailable laisserait swift build, swift test et le build Xcode verts. Piste : extraire la logique de tranches et d'états vides dans un petit view-model testable par swift test.
status: open

### DW-5: Follow-up review still recommended for 1-2-journal-des-tâches-et-socle-hpm-db after the damping cap was spent
origin: review-budget-followup
location: n/a
source_spec: `spec-1-2-journal-des-tâches-et-socle-hpm-db.md`
severity: low
reason: The follow-up-review damping cap (limits.max_followup_reviews = 1) was spent with the story finalized (status: done, verify green) while the review pass still recommended an independent follow-up. The work was committed by bmad-loop run 20260823-185715-f540; this entry preserves the lingering recommendation for a deliberate later review.
status: open

### DW-6: Le câblage CLI `journal: false` des lectures pures (status, releases, config diff, logs) n'a aucune vérification exécutable : le ré-inverser recréerait hpm.db sur machine vierge sans qu'aucun test ne
origin: spec-deferred 409d772210bd
location: Sources/hpm/HPM.swift (makeManager), Sources/hpm/Commands.swift (lectures pures)
source_spec: `spec-1-2-journal-des-tâches-et-socle-hpm-db.md`
severity: medium
reason: Régression déjà survenue une fois (corrigée à la passe de review 3). Aucun test target ne dépend de l'exécutable hpm (Package.swift) ; testPureReadsNeverJournal épingle la règle au seam kit (un manager avec history ne journalise pas status), pas la construction du store par makeManager. Distinct du différé existant sur TasksCmd : même parapluie (couche CLI non testée), autre comportement, déjà régressé une fois.
status: open

### DW-7: La logique 1.3 côté app (gating destructif isDestructive → sheet, dispatch de run(_:on:), toast, inFlight par machine) n'a aucune vérification exécutable.
origin: spec-deferred c0bb65d14c52
location: App/Sources/FleetModel.swift, App/Sources/MachineDetailView.swift
source_spec: `spec-1-3-actions-machine-avec-confirmations.md`
severity: medium
reason: Le target App n'a aucun test (pré-existant au repo : Package.swift ne déclare que HomePortKitTests). Retirer `.remove` de la branche destructive d'isDestructive supprimerait la confirmation UX-DR6 du bouton le plus dangereux sans qu'aucun test ne rougisse. Piste : déplacer Action (pur, sans UI) dans HomePortKit, ou ajouter un bundle de tests app au xcodeproj.
status: open

### DW-8: Les peaux CLI de la story (UnlockCmd — garde fileExists, textes — et la confirmation --yes d'UpdateCmd) n'ont aucune vérification exécutable.
origin: spec-deferred 55397e912c0c
location: Sources/hpm/Commands.swift (UnlockCmd, UpdateCmd)
source_spec: `spec-1-3-actions-machine-avec-confirmations.md`
severity: low
reason: Même parapluie pré-existant que DW-1/DW-6 : aucun test target ne dépend de l'exécutable hpm. La logique testable (HistoryStore.unlock, refus/reprise) est volontairement dans le kit et couverte ; seuls le câblage ArgumentParser et les sorties texte restent non testés.
status: open

### DW-9: Follow-up review still recommended for 1-3-actions-machine-avec-confirmations after the damping cap was spent
origin: review-budget-followup
location: n/a
source_spec: `spec-1-3-actions-machine-avec-confirmations.md`
severity: low
reason: The follow-up-review damping cap (limits.max_followup_reviews = 1) was spent with the story finalized (status: done, verify green) while the review pass still recommended an independent follow-up. The work was committed by bmad-loop run 20260823-185918-2f6f; this entry preserves the lingering recommendation for a deliberate later review.
status: open

### DW-10: La machine à états du cache Dashboard (verdict d'échec, garde de rechargement, politique de navigation externe, prune) n'a aucune vérification exécutable.
origin: spec-deferred f8b7020d298c
location: App/Sources/DashboardTabView.swift
source_spec: `spec-1-4-dashboard-homeport-intégré.md`
severity: medium
reason: Même parapluie pré-existant que DW-7/DW-8 : le target App n'a aucun test (Package.swift ne déclare que HomePortKitTests, App/project.yml une seule target application). Inverser le filtre NSURLErrorCancelled de fail(_:) ou le prédicat de prune(keeping:) laisse `swift test` vert. Piste : extraire le réducteur de verdict (fail/didCommit/retry/terminate, filtres de codes) en type HomePortKit testable, la WKWebView restant côté app — ou ajouter un bundle de tests app au xcodeproj.
status: open

### DW-11: Follow-up review still recommended for 1-4-dashboard-homeport-intégré after the damping cap was spent
origin: review-budget-followup
location: n/a
source_spec: `spec-1-4-dashboard-homeport-intégré.md`
severity: low
reason: The follow-up-review damping cap (limits.max_followup_reviews = 1) was spent with the story finalized (status: done, verify green) while the review pass still recommended an independent follow-up. The work was committed by bmad-loop run 20260823-185918-2f6f; this entry preserves the lingering recommendation for a deliberate later review.
status: open
