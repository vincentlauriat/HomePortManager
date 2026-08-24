- source_spec: `docs/build/spec-1-1-fenêtre-centre-de-contrôle-et-tableau-de-bord-global.md`
  summary: App/Sources n'est pas dans le graphe SwiftPM, donc son code n'est couvert par aucun test unitaire.
  evidence: Package.swift ne déclare que HomePortKit, hpm et HomePortKitTests. MachineBlockStore (persistance UserDefaults), FleetModel (écriture des caches lastReachableStatus/lastSeenAt) et Color(hex:) n'ont aucun test possible. La moitié « jamais compilé » est close depuis le 24/08 — le gate de vérification du loop lance xcodegen + xcodebuild après swift test — mais compiler n'est pas tester : la logique de ces trois types reste sans assertion. Piste : l'extraire vers HomePortKit, comme MachineBlock, FleetRow et MachineIssue.

- source_spec: `docs/build/spec-1-1-fenêtre-centre-de-contrôle-et-tableau-de-bord-global.md`
  summary: RÉSOLU le 24/08 — reloadFleet() avalait les erreurs de parsing YAML. Le modèle conserve désormais l'erreur dans fleetLoadError, et la vue Flotte affiche un état « fleet.yaml est illisible » qui prend le pas sur « aucune machine », avec le chemin du fichier, l'erreur brute et le bouton de rechargement.
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

### DW-12: La machine à états des sessions de log côté app (followEnabled, interrupted, activate/deactivate/suspendForWindow/resumeAfterWindow, reset du buffer au changement de mode, arrêt avant retrait dans pru
origin: spec-deferred ae2059b121ff
location: App/Sources/LogsTabView.swift
source_spec: `spec-1-5-logs-centralisés.md`
severity: medium
reason: Quatrième story consécutive sous le même parapluie (DW-7, DW-10) : Package.swift ne déclare que HomePortKitTests et App/project.yml une seule target application, donc Tests/ ne peut pas importer App/Sources. Supprimer la boucle `session.stop()` de LogSessionStore.prune, ou le `session.deactivate()` du onDisappear, laisse `swift test` entièrement vert tout en laissant un `ssh journalctl -f` orphelin. Piste : extraire l'état de cycle de vie (active/followEnabled/suspended + compteur d'arrêts) en type HomePortKit, la vue ne gardant que le câblage SwiftUI — la même opération que LogLines.swift a faite pour le buffer et le filtre.
status: open

### DW-13: Les lignes d'erreur du log-viewer ne sont distinguées que par la couleur, ce qui contredit le plancher d'accessibilité de l'epic.
origin: spec-deferred 4b3e55c8c570
location: App/Sources/LogsTabView.swift
source_spec: `spec-1-5-logs-centralisés.md`
severity: low
reason: rebuild() applique Theme.semanticCritical au run et rien d'autre ; l'epic exige que « la couleur ne soit jamais seule porteuse d'état », mais le token log-viewer de DESIGN.md:291 ne prévoit que la teinte, et l'AC de la story la nomme explicitement. Tension réelle entre deux sources, à trancher hors du périmètre de cette story. Le choix d'un seul Text (imposé par la sélection multi-ligne de l'AC) fait aussi de tout le viewer un unique élément VoiceOver sans libellé par ligne.
status: open

### DW-14: Sur une machine injoignable, l'onglet traverse brièvement l'empty-state « No log lines » avant de basculer sur « Unreachable ».
origin: spec-deferred 6ea75c1b79a6
location: App/Sources/LogsTabView.swift
source_spec: `spec-1-5-logs-centralisés.md`
severity: low
reason: runFollow met loading = false dès que startLogFollow retourne, c'est-à-dire dès que le ssh local est lancé et avant tout établissement de connexion ; le verdict n'arrive qu'à la fin du stream. Garder loading vrai jusqu'à la première ligne rouvrirait le spinner infini sur une unité silencieuse : le correctif propre demande une grâce temporisée dans un chemin déjà concurrent, disproportionnée pour un état transitoire dont l'état final est correct.
status: open

### DW-15: `LogsCmd` code en dur la chaîne « homeport.service » au lieu de lire `RemotePaths.unit`, seule source de vérité du nom d'unité.
origin: spec-deferred 47cbc1ec5a55
location: Sources/hpm/Commands.swift:274
source_spec: `spec-1-5-logs-centralisés.md`
severity: low
reason: Pré-existant : `LogsCmd` n'est pas touché par cette story (AC 4 est une contrainte de préservation). Mais le kit expose désormais deux chemins qui, eux, lisent `RemotePaths.unit` (`logs`, `followLogs`), tandis que la branche `-f` du CLI interpole sa propre chaîne. Renommer l'unité côté déploiement laisserait `hpm logs -f` cibler silencieusement une unité inexistante, et aucun test n'exécute la couche CLI (DW-1, DW-6). Correctif d'une ligne, mais il touche le CLI : hors périmètre d'une story dont l'AC 4 exige que `Sources/hpm/Commands.swift` ne soit pas modifié.
status: open

### DW-16: Follow-up review still recommended for 1-5-logs-centralisés after the damping cap was spent
origin: review-budget-followup
location: n/a
source_spec: `spec-1-5-logs-centralisés.md`
severity: low
reason: The follow-up-review damping cap (limits.max_followup_reviews = 1) was spent with the story finalized (status: done, verify green) while the review pass still recommended an independent follow-up. The work was committed by bmad-loop run 20260823-185918-2f6f; this entry preserves the lingering recommendation for a deliberate later review.
status: open

- source_spec: none
  summary: RÉSOLU le 24/08 — DefaultProcessRunner.run pouvait interbloquer sur une commande qui écrit beaucoup sur stderr. Les deux pipes drainent désormais concurremment, et les drains démarrent avant l'écriture de stdin (même forme de blocage côté entrée). Interblocage reproduit puis fermé : l'ancien code tourne encore après 16 s là où la suite complète prend 1,4 s. Couvert par testDefaultRunnerDrainsBothPipesWhenStderrOverflowsItsBuffer et testDefaultRunnerDrainsWhileWritingALargeStdin — deux tests qui, avant le correctif, n'échouent pas mais se bloquent.
  evidence: Sources/HomePortKit/ProcessRunner.swift lit `outPipe.readDataToEndOfFile()` puis `errPipe.readDataToEndOfFile()` séquentiellement. Le commentaire ne couvre que le deadlock contre waitUntilExit. Si l'enfant écrit plus que la capacité du buffer de pipe (~64 Kio) sur stderr pendant que le parent est bloqué sur stdout, l'enfant bloque en écriture, n'atteint jamais EOF sur stdout, et le parent l'attend indéfiniment — l'app se fige sans erreur. Code antérieur au run bmad-loop (présent dès e9a257a), mais le risque monte avec les commandes ajoutées par l'epic 1 (update, doctor, config-pull), dont apt et ssh sont verbeux sur stderr. Correctif : drainer les deux pipes concurremment (readabilityHandler ou deux files), comme le fait déjà ProcessFollow pour le streaming dans le même fichier.
