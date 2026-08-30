- source_spec: `docs/build/spec-1-1-fenêtre-centre-de-contrôle-et-tableau-de-bord-global.md`
  summary: App/Sources n'est pas dans le graphe SwiftPM, donc son code n'est couvert par aucun test unitaire.
  evidence: Package.swift ne déclare que HomePortKit, hpm et HomePortKitTests. MachineBlockStore (persistance UserDefaults), FleetModel (écriture des caches lastReachableStatus/lastSeenAt) et Color(hex:) n'ont aucun test possible. La moitié « jamais compilé » est close depuis le 24/08 — le gate de vérification du loop lance xcodegen + xcodebuild après swift test — mais compiler n'est pas tester : la logique de ces trois types reste sans assertion. Piste : l'extraire vers HomePortKit, comme MachineBlock, FleetRow et MachineIssue.

- source_spec: `docs/build/spec-3-3-gestion-des-mises-à-jour.md`
  summary: 4 des 6 lignes de la matrice I/O de l'onglet Updates (affichage, déclenchement confirmé, machine injoignable, mutation en cours) ne sont couvertes par aucun test automatisé.
  evidence: Instance nouvelle du trou déjà noté ci-dessus (App/Sources hors bundle de tests) — UpdatesTabView.swift (App/Sources) encode ces branches en SwiftUI pur, vérifiables seulement à l'œil (cf. section Verification de la spec 3.3). Seules 2 lignes ont une couverture automatisée : le calcul « à jour / update disponible » via MachineIssueTests (préexistant) et le champ notes via ReleaseServiceTests (ajouté par cette story). Se referme naturellement si/quand la piste ci-dessus (extraction vers HomePortKit ou bundle de tests App) est traitée.

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

### DW-17: Le câblage de l'onglet Événements (EventFeed, EventFeedStore, le poll scopé, la fusion incrémentale, le choix des trois états, le filtre de sévérité) n'a aucune vérification exécutable.
origin: spec-deferred 2-2a-ui-wiring
location: App/Sources/EventsTabView.swift, App/Sources/MachineDetailView.swift, App/Sources/ControlCenterWindow.swift
source_spec: `spec-2-2a-flux-d-événements-et-onglet-événements.md`
severity: medium
reason: Même parapluie pré-existant que DW-2/DW-4/DW-7/DW-10/DW-12 : `App/Sources` n'est pas dans le graphe SwiftPM (Package.swift ne déclare que HomePortKit, hpm et HomePortKitTests), donc `swift test` ne peut rien y assurer et `Scripts/verify-app-build.sh` ne fait que compiler. Concrètement : inverser la branche `window.isFullWindow` d'`EventFeed.apply` (remplacer au lieu de fusionner, ou l'inverse) ferait disparaître ou dupliquer des événements à chaque poll ; supprimer `unavailable = nil` de la branche `.unreachable` renverrait l'utilisateur vers Updates pour une machine simplement injoignable ; passer `advancingCursor: false` dans `EventFeed.read` rendrait chaque poll incrémental identique au précédent. Aucun de ces trois cas ne rougirait quoi que ce soit. La logique décidable est délibérément dans le kit (`HomeportEventsReader`, couverte par ManagerEventsTests) ; ce qui reste ici est de l'état d'affichage. Piste inchangée : un bundle de tests app dans le xcodeproj, ou extraire `EventFeed` (pur, sans SwiftUI hors des `@Published`) vers HomePortKit.
status: open

### DW-18: `hpm events` n'avance pas le marqueur de lecture, alors que le contexte d'epic prévoit qu'il le fasse.
origin: spec-deferred 2-2a-cli-cursor
location: Sources/hpm/Commands.swift (EventsCmd), Sources/HomePortKit/Manager+Events.swift (advancingCursor)
source_spec: `spec-2-2a-flux-d-événements-et-onglet-événements.md`
severity: medium
reason: `docs/build/epic-2-context.md` écrit « ce qui permet à `hpm events` d'avancer la lecture sans jamais escamoter une notification » — mais cette phrase ne tient que lorsque `notified_up_to` existe pour rester distinct du curseur de lecture, et la 2.2a le met explicitement hors périmètre. En 2.2a, un `hpm events` qui consommerait le curseur aveuglerait le poll incrémental de l'onglet : l'app ne verrait jamais les événements que le CLI vient d'imprimer. `EventsCmd` passe donc `advancingCursor: false` et l'app est l'unique rédacteur du curseur. À rouvrir en 2.2b, où le second marqueur rend le geste sûr : le paramètre `advancingCursor` existe déjà pour ça.
status: open

### DW-19: Le contrat épinglé reste sans lien exécutable sur son volet métriques (§7) et sur la fenêtre de restore que §5 laisse ouverte.
origin: spec-deferred 2-2a-contract-coverage
location: docs/api/homeport-api-v1.md §5, §7
source_spec: `spec-2-2a-flux-d-événements-et-onglet-événements.md`
severity: low
reason: La 2.2a ferme la moitié du trou signalé à la revue de la 2.1 : les sévérités, l'invalidation `(epoch, latest_id)`, la pagination et la table des échecs de §8 sont désormais décodées par du code que `HomeportAPIClientTests` et `ManagerEventsTests` contredisent si elles dérivent. Restent sans test : la grille de métriques et l'alignement `from`/`to` sur `step_s` (§7), qui appartiennent à la story 2.3 ; et la fenêtre que §5 accepte sciemment — un restore qui ramène l'ancien epoch puis regrossit au-delà du curseur avant le sondage suivant, que ni l'epoch ni `latest_id` ne distinguent. Cette seconde n'est pas testable côté client par construction : la parade vit dans l'outil qui restaure (voir la note « `hpm restore` devrait invalider l'epoch » plus bas).
status: open

- source_spec: none
  summary: RÉSOLU le 24/08 — DefaultProcessRunner.run pouvait interbloquer sur une commande qui écrit beaucoup sur stderr. Les deux pipes drainent désormais concurremment, et les drains démarrent avant l'écriture de stdin (même forme de blocage côté entrée). Interblocage reproduit puis fermé : l'ancien code tourne encore après 16 s là où la suite complète prend 1,4 s. Couvert par testDefaultRunnerDrainsBothPipesWhenStderrOverflowsItsBuffer et testDefaultRunnerDrainsWhileWritingALargeStdin — deux tests qui, avant le correctif, n'échouent pas mais se bloquent.
  evidence: Sources/HomePortKit/ProcessRunner.swift lit `outPipe.readDataToEndOfFile()` puis `errPipe.readDataToEndOfFile()` séquentiellement. Le commentaire ne couvre que le deadlock contre waitUntilExit. Si l'enfant écrit plus que la capacité du buffer de pipe (~64 Kio) sur stderr pendant que le parent est bloqué sur stdout, l'enfant bloque en écriture, n'atteint jamais EOF sur stdout, et le parent l'attend indéfiniment — l'app se fige sans erreur. Code antérieur au run bmad-loop (présent dès e9a257a), mais le risque monte avec les commandes ajoutées par l'epic 1 (update, doctor, config-pull), dont apt et ssh sont verbeux sur stderr. Correctif : drainer les deux pipes concurremment (readabilityHandler ou deux files), comme le fait déjà ProcessFollow pour le streaming dans le même fichier.

- source_spec: `spec-2-1-contrat-api-v1-et-flux-d-événements.md`
  summary: RÉSOLU le 28/08 — l'API v1 est servie. `raspcorse` et `raspyellow` répondent tous deux sur `/api/v1/capabilities` avec `contract 1.0.0`, `server 0.8.0` et `features: ["events","metrics"]`, et `hpm events` (story 2.2a) lit leur journal réel. Le libellé d'origine suit. — L'API v1 est écrite, pas servie. Le contrat `docs/api/homeport-api-v1.md` et la plage consommée par hpm existent et s'accordent, mais aucune machine ne répond sur `/api/v1/` — l'implémentation serveur reste entièrement à faire dans le dépôt Homeport, et le client (`HomeportAPIClient`, onglet Événements, `hpm events`) reste à écrire dans la story 2.2. La clé `2-1` est donc `in-progress`, pas `done`.
  evidence: Vérifié sur raspcorse le 24/08 : `/healthz` répond `{"status":"ok","version":"0.7.2"}`, aucune route `/api/v1/` n'existe. Le contrat décrit trois choses entièrement neuves côté serveur — l'epoch et sa régénération au restore, `latest_id`, et l'agrégation des métriques en quatre échelles plus la série `disk_pct`, absente de la collecte historisée actuelle (`homeport/collectors/history.py` ne stocke que cpu/mem/temp/nvme sur une seule échelle). Les critères d'acceptation 2 et 3 de la story commencent tous deux par « Given un Homeport exposant l'API » et resteront invérifiables jusque-là ; aucune story de l'epic 2 ne peut se clore avant.

- source_spec: `spec-2-1-contrat-api-v1-et-flux-d-événements.md`
  summary: Une seule ligne du contrat épinglé est liée à du code exécutable — la plage de versions. Tout le reste du document (correspondance des sévérités, règle d'invalidation du curseur epoch/latest_id, grille des métriques et alignement de `from`/`to` sur `step_s`, conduite face aux échecs) ne repose sur rien qu'un test puisse contredire.
  evidence: Relevé pendant la revue de la story 2.1. `testThePinnedContractStatesTheSameRangeAsTheCode` ne vérifie que les lignes contenant « Plage consommée par hpm ». Ce n'est pas un défaut de cette story : le client qui consommera ces règles n'existe pas encore, et la story 2.1 s'interdit de l'écrire. Le moment de fermer ce trou est la story 2.2, quand `HomeportAPIClient` décodera de vraies réponses — les tests de décodage deviendront alors le lien manquant entre le document et le code. À reprendre à ce moment-là, sans quoi le contrat restera un texte que rien ne contraint.

## `hpm restore` devrait invalider l'epoch de la machine restaurée

**Constaté** le 2026-08-24, en vérifiant ce que `Manager+Restore.swift` copie réellement.

Le restore fait `rm -rf /var/lib/homeport` puis `cp -a` du répertoire entier. La sentinelle
d'identité posée par `identity.py` vit dans ce répertoire : elle voyage donc dans l'archive avec la
base, les deux copies de l'epoch se retrouvent d'accord, et le serveur redémarre sans rien
constater. Le mécanisme de sentinelle attrape la base déposée seule (`scp history.db`, base
recréée) — pas le chemin de restauration normal.

Le contrat v1 a été corrigé pour dire cela (§5, §8) et le client s'appuie sur `latest_id`, qui
couvre le cas dès que l'historique restauré est plus court que le curseur. La fenêtre restante :
un historique qui regrossit au-delà du curseur avant le sondage suivant.

**Fermeture possible, hors périmètre v1** : faire invalider l'epoch par l'outil qui restaure, après
le `cp -a` — l'agent qui substitue la base est le seul à savoir qu'il l'a fait. Cela déplace une
obligation de Homeport vers HomePortManager et engage les deux dépôts, donc une décision de
conception à trancher, pas un correctif à appliquer.

### DW-20: Unreadable `deferred:` items in spec-2-2a-flux-d-événements-et-onglet-événements.md
origin: spec-deferred-malformed 851971cb9eb5
location: n/a
source_spec: `spec-2-2a-flux-d-événements-et-onglet-événements.md`
severity: low
reason: The dev session recorded deferred findings the orchestrator could not parse, so they were NOT filed as entries: item 1: not a mapping (got str); item 2: not a mapping (got str); item 3: not a mapping (got str). Read `spec-2-2a-flux-d-événements-et-onglet-événements.md`'s frontmatter and re-file them by hand.
status: open

### DW-21: Le sondage de fond des notifications, le gating single-policy et la navigation clic-notification (App/Sources) n'ont aucune vérification exécutable via swift test.
origin: spec-deferred 2-2b-background-poll
location: App/Sources/FleetModel.swift, App/Sources/Notifier.swift, App/Sources/ControlCenterWindow.swift, App/Sources/MachineDetailView.swift
source_spec: `spec-2-2b-notifications-critiques-et-politique-de-repli.md`
severity: medium
reason: Même parapluie que DW-17 : `App/Sources` n'est pas dans le graphe SwiftPM (Package.swift ne déclare que HomePortKit, hpm et HomePortKitTests). La détection de reset elle-même n'est *pas* concernée — `notifiableCriticalEvents` compare `notifiedMarker.epoch` contre `window.epoch` entièrement dans HomePortKit, et `ManagerNotificationsTests` la couvre directement, epoch changeant sans qu'aucune ligne `event_cursors` n'existe jamais y compris. Ce qui reste réellement non testable via `swift test` est l'orchestration temps réel autour de cette décision pure : `FleetModel.pollEventsForNotifications`/`pollEvents` (le timer 45 s, la lecture puis l'écriture de `NotifiedMarkerStore`, le gating de la boucle `transitions()`/`Notifier.notify` de `refresh()` sur `eventsAvailable`), le délégué `UNUserNotificationCenterDelegate` de `Notifier.swift` (le clic, la course avec `FleetModel.init` sur `Notifier.model`), et la chaîne de navigation (`ControlCenterCommands.pendingNavigation`, consommé par `ControlCenterView`/`MachineDetailView`). Concrètement, inverser la garde `eventsAvailable[name] != true` dans `refresh()` ferait notifier deux fois la même machine (événements et transitions SSH) sans qu'aucun test ne rougisse ; retirer le `guard machines.contains(...)` de `pollEvents` laisserait une entrée `eventsAvailable` fantôme pour une machine retirée de fleet.yaml, invisible aussi. Piste inchangée par rapport à DW-17 : un bundle de tests app dans le xcodeproj, ou extraire l'orchestration restante (au-delà des fonctions déjà pures) vers HomePortKit.
status: open

### DW-22: Le rendu du graphique de métriques diverge entre l'onglet de l'app et `hpm metrics` sur un segment à un seul point.
origin: review 2-3-métriques-historisées (finding #2)
location: App/Sources/MetricsTabView.swift (MetricCard.chart)
source_spec: `spec-2-3-métriques-historisées.md`
severity: low
reason: `LineMark`/`AreaMark` sans `.symbol` ne trace rien pour un segment réduit à un seul point de données (ex. fenêtre 1y avec un seul échantillon récent) — le point disparaît silencieusement au lieu d'apparaître comme dans `hpm metrics`, qui affiche la valeur en table quel que soit le nombre de points. Aucun test (Swift Charts non testable via `swift test`) ne rougirait si ce cas régressait. Piste : ajouter un `.symbol` conditionnel ou un `PointMark` de repli quand un segment ne contient qu'un point.
status: open

### DW-23: `MetricsTabView` n'est pas couvert par le render-probe du projet.
origin: review 2-3-métriques-historisées (finding #3)
location: Scripts/render-probe/main.swift
source_spec: `spec-2-3-métriques-historisées.md`
severity: low
reason: Le render-probe est le seul mécanisme du projet qui rend réellement une vue SwiftUI pour attraper les bugs de mise en page (ex. un `Chart` dont la hauteur s'effondre à zéro) que `swift test`/`xcodebuild` seuls ne détectent pas. `MetricsTabView`, nouvel onglet de cette story, n'y a pas été ajouté — une régression de layout sur cet onglet spécifiquement passerait inaperçue de toute la chaîne de vérification actuelle. Piste : ajouter un scénario `MetricsTabView` au probe, avec au moins un cas à segment unique (cf. DW-22).
status: open

### DW-24: Indexation non protégée dans `rows(for:)` (hpm) et invariant de longueur non imposé par `MetricsWindow.init`.
origin: review 2-3-métriques-historisées (finding #5)
location: Sources/hpm/Commands.swift (MetricsCmd.rows(for:), ligne ~591), Sources/HomePortKit/HomeportAPIClient.swift (MetricsWindow.init)
source_spec: `spec-2-3-métriques-historisées.md`
severity: low
reason: `rows(for:)` indexe les séries de `MetricsWindow` par position sans vérifier qu'elles ont toutes la même longueur que la grille, et `MetricsWindow.init` n'impose pas cet invariant à la construction — il repose entièrement sur la discipline de l'appelant (`window(from:)`, qui le respecte aujourd'hui). Un payload malformé où une série serait plus courte que la grille — ou un futur appelant qui construirait `MetricsWindow` sans passer par `window(from:)` — provoquerait un crash par accès hors bornes non couvert par un test existant. Piste : faire valider la longueur des séries dans `MetricsWindow.init` (fatalError ou init failable), ou borner `rows(for:)` par `min(grid.count, series.count)`.
status: open

### DW-25: `MetricsFeed.apply` conserve une fenêtre de métriques obsolète lors d'un échec de fetch déclenché par un changement de plage.
origin: review 2-3-métriques-historisées (finding #6)
location: App/Sources/MetricsTabView.swift (MetricsFeed.apply, cas .unreachable, lignes ~108-116)
source_spec: `spec-2-3-métriques-historisées.md`
severity: low
reason: Quand l'utilisateur change de plage (ex. 24h → 1y) et que le fetch de la nouvelle fenêtre échoue (`.unreachable`), `MetricsFeed.apply` continue d'afficher la fenêtre de l'ancienne plage plutôt que de refléter l'échec ou de vider l'affichage — l'utilisateur peut croire à tort qu'il regarde des données de la plage sélectionnée. Aucun test app (App/Sources hors graphe SwiftPM, cf. DW-17/DW-21) ne couvre ce chemin. Piste : faire porter l'état `.unreachable` sur la plage demandée plutôt que de le faire retomber silencieusement sur la dernière fenêtre servie.
status: open

## Deferred from: code review of story-3.3 (2026-08-30)

### DW-26: Le badge flèche de version du Résumé reste live, non stale-aware — le bug corrigé pour l'onglet Updates reste vivant sur la vue par défaut de la fiche machine.
origin: code review story-3.3 (verification-gap layer)
location: App/Sources/MachineDetailView.swift:83-85 (`issues`), 398-410 (`versionValue`)
source_spec: `spec-3-3-gestion-des-mises-à-jour.md`
severity: medium
reason: `versionValue` affiche `display.status?.installedVersion` (stale-aware, dernière valeur connue) mais sa flèche « → cible » vient de `issues.availableUpdate`, dérivé de `machineIssues(model.statuses[machine.name], ...)` — le statut *live*, qui retombe à `[.unreachable]` (aucun `.updateAvailable`) dès que la machine est injoignable. Une machine injoignable avec une vraie mise à jour en retard affiche donc « à jour » sur le Résumé — exactement le bug que cette story a corrigé pour l'onglet Updates via `updateTarget(installed:latest:)` appelé contre `display.status`. Le Spec Change Log de la story 3.3 a explicitement scindé le périmètre (`machineIssues` = verdict live, onglet Updates = verdict stale-aware) plutôt que d'étendre le correctif au Résumé — décision assumée mais qui laisse la vue la plus visitée de la fiche machine avec l'incohérence d'origine. Piste : faire lire `versionValue` sur `updateTarget(installed: display.status?.installedVersion, latest: model.latestTag)` au lieu de `issues.availableUpdate`, comme l'onglet Updates.
status: open
