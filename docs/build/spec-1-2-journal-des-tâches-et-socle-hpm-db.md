---
title: '1.2 — Journal des tâches et socle hpm.db'
type: 'feature'
created: '2026-08-23'
status: 'done'
baseline_revision: 'e9a257aea7e6b56842e5486b2a4eb61a81014f7e'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/docs/build/epic-1-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      Aucun test n'exécute la couche CLI (dont TasksCmd) : le câblage --machine/--limit/--id
      vers HistoryStore n'est vérifié que par les tests kit et un contrôle manuel.
    evidence: |-
      Motif pré-existant à tout le repo : aucun test target ne dépend de l'exécutable hpm
      (Package.swift), aucune commande n'a jamais été testée. TasksCmd.run instancie
      HistoryStore() au chemin réel, ce qui bloque aussi un futur test in-process —
      remplacer `store.tasks(machine: machine, ...)` par `machine: nil` passerait inaperçu
      de `swift test`.
    location: >-
      Sources/hpm/Commands.swift (TasksCmd)
    severity: medium
  - summary: >-
      Le site d'invocation de la purge (démarrage app, NFR7) n'est couvert par aucun test —
      seule la mécanique de purge du store l'est.
    evidence: |-
      Le seul appelant de purge() en production est FleetModel.init (Task.detached) ; le
      target App n'a aucun test (pré-existant au repo). Supprimer le bloc de purge de
      l'init laisserait toute la suite verte. Piste : un helper kit testable
      (p. ex. HistoryStore.openPurging()) adopté par FleetModel.
    location: >-
      App/Sources/FleetModel.swift (init)
    severity: low
  - summary: >-
      La documentation utilisateur ne mentionne ni `hpm tasks` (et ses options), ni la
      section Historique de l'app, ni l'emplacement de ~/.local/state/hpm/hpm.db.
    evidence: |-
      Aucun fichier de doc n'apparaît dans le diff de la story ; le README du projet liste
      les capacités CLI existantes et devra intégrer la nouvelle commande à la prochaine
      passe de doc.
    severity: low
  - summary: >-
      Le câblage journal côté app (rechargement après une action, branche « journal
      indisponible » vs « aucune tâche », filtre par nom exact de machine) n'a aucune
      vérification exécutable.
    evidence: |-
      Le target App n'a aucun test (pré-existant au repo). Supprimer le reloadTasks()
      inconditionnel à la complétion d'une action — la régression corrigée par une passe
      précédente — ou inverser la branche !model.historyAvailable laisserait swift build,
      swift test et le build Xcode verts. Piste : extraire la logique de tranches et
      d'états vides dans un petit view-model testable par swift test.
    location: >-
      App/Sources/FleetModel.swift, App/Sources/FleetOverviewView.swift,
      App/Sources/MachineDetailView.swift
    severity: low
  - summary: >-
      Le câblage CLI `journal: false` des lectures pures (status, releases, config diff,
      logs) n'a aucune vérification exécutable : le ré-inverser recréerait hpm.db sur
      machine vierge sans qu'aucun test ne rougisse.
    evidence: |-
      Régression déjà survenue une fois (corrigée à la passe de review 3). Aucun test
      target ne dépend de l'exécutable hpm (Package.swift) ; testPureReadsNeverJournal
      épingle la règle au seam kit (un manager avec history ne journalise pas status),
      pas la construction du store par makeManager. Distinct du différé existant sur
      TasksCmd : même parapluie (couche CLI non testée), autre comportement, déjà
      régressé une fois.
    location: >-
      Sources/hpm/HPM.swift (makeManager), Sources/hpm/Commands.swift (lectures pures)
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Aucune action menée sur la flotte n'est historisée : impossible de savoir qui a fait quoi, quand, et avec quel résultat. Le socle d'état central du Mac (`hpm.db`) dont dépendent 1.3 (verrou), l'epic 2 (curseurs) et l'epic 3 (jobs) n'existe pas.

**Approach:** Créer `HistoryStore` dans HomePortKit — propriétaire exclusif de `~/.local/state/hpm/hpm.db` (SQLite via l'API C système, WAL, `busy_timeout`, migrations `PRAGMA user_version`) — avec le schéma v1 : table journal des tâches + table de verrous (détenteur PID, horodatage de prise). Journaliser chaque action utilisateur **dans le kit** (seam commun aux méthodes publiques de `HomeportManager`) pour une parité CLI/app par construction : ligne ouverte au départ (`running`), close à la fin (statut + sortie capturée du `Reporter`). Exposer `hpm tasks [--machine]`, les tâches récentes dans le Résumé machine, l'historique global dans la vue Flotte, et la purge (1 an / 10 000) au démarrage de l'app seulement.

## Boundaries & Constraints

**Always:**
- `HistoryStore` est le **seul** code qui ouvre `hpm.db` (AD-2, AD-7). Frontends et `HomeportManager` passent par son API ; les lectures restent libres et parallèles.
- API C `sqlite3` du système (`import SQLite3`) — pas d'ORM, **aucune dépendance nouvelle**. WAL + `busy_timeout` posés à l'ouverture ; connexion protégée par verrou interne (les écrivains arrivent de `concurrentPerform` et de `Task.detached`).
- Horodatages **ISO 8601 UTC** en base ; la colonne machine porte le **nom d'inventaire `fleet.yaml`** ; identifiants d'action stables en anglais (`backup`, `update`, …) stockés tels quels.
- Toute extension future du schéma passe par migration `user_version`, jamais par table parallèle. Une base dont `user_version` dépasse la version connue du kit n'est jamais modifiée (erreur `HPMError` propre).
- Une action composée journalise **une seule entrée** au niveau invoqué par l'utilisateur (`update` → backup+install = 1 entrée) — garde de profondeur dans le seam.
- Logique (schéma, écriture, lecture, purge) dans le kit, testée par `swift test` (AD-1) ; frontends = présentation seulement. UI : tokens `Theme` + composants `DesignComponents` existants, i18n fr/en/zh-Hans via `Localizable.xcstrings`, contenu machine (action, sortie, horodatage) jamais traduit et rendu en mono, statut porté par couleur **et** libellé.
- L'indisponibilité du journal (répertoire d'état inaccessible) **dégrade sans bloquer** : l'action s'exécute, un avertissement est émis — jamais une action refusée parce que la base est inaccessible.

**Block If:**
- Satisfaire un critère exigerait d'implémenter la **sémantique** de verrou (acquisition, TTL 30 min, détection process mort, reprise, `hpm unlock`) — elle appartient à 1.3 ; seule la **table** est due ici.
- Le schéma de `fleet.yaml` devrait changer — fichier utilisateur possédé par `FleetStore`.

**Never:**
- Pas de journalisation des lectures pures (`status`, `logs`, `installedVersion`, `configDiff`, `releases`) — elles pollueraient le plafond de 10 000 entrées ; le journal ne consigne que les actions initiées par le Mac (AD-16).
- Pas de purge côté CLI (`hpm tasks` ne fait jamais le ménage) ; purge au démarrage de l'app uniquement (NFR7).
- Pas de modification de `docs/build/sprint-status.yaml`, ni des types existants du kit au-delà des points d'insertion du Code Map.
- Ne pas confondre `hpm.db` (état Mac) avec la `history.db` du Pi sauvegardée par `Manager+Backup` — objets distincts.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Première ouverture | `~/.local/state/hpm/` inexistant | Répertoires créés, base créée : `journal_mode=wal`, `user_version=1`, tables journal + verrous présentes | `HPMError` si création impossible |
| Action réussie | `journaled("backup", machine)` dont le corps réussit | 1 entrée : `started_at`/`finished_at` ISO 8601 UTC, statut `success`, sortie = lignes du `Reporter` | Aucune |
| Action échouée | corps qui `throw HPMError("boom")` | Entrée close en `failure`, sortie = lignes capturées + message d'erreur ; l'erreur est re-levée telle quelle | L'erreur d'origine remonte |
| Action composée | `update` (appelle `backup` puis `install`) | **Une seule** entrée `update` ; les appels imbriqués ne journalisent pas | Aucune |
| Tri | entrées multiples, machines mêlées | `tasks()` du plus récent au plus ancien (id décroissant) ; `tasks(machine:)` filtre sur le nom exact | Aucune |
| Machine inconnue du filtre | `tasks(machine: "ghost")` | Liste vide (le journal peut contenir des machines retirées de la flotte — pas de validation flotte) | Jamais d'erreur |
| Purge par âge | entrées > 1 an | Supprimées par `purge(now:)` ; les plus récentes restent | Aucune |
| Purge par volume | 10 001+ entrées, toutes < 1 an | Seules les 10 000 plus récentes survivent | Aucune |
| Base indisponible | init `HistoryStore` échoue (répertoire non inscriptible) | `HomeportManager` sans `history` : l'action s'exécute normalement, rien n'est journalisé, avertissement émis par le frontend | Jamais bloquant |
| Base plus récente | `user_version=99` à l'ouverture | `HPMError` explicite, base intouchée | Erreur propre |
| Réouverture | base déjà en v1 | Aucune re-migration ; `user_version` inchangé | Aucune |
| Écrivains concurrents | 2 `HistoryStore` (2 process) écrivent en même temps | Les deux entrées atterrissent (WAL + `busy_timeout`), pas de corruption | Aucune |

</intent-contract>

## Code Map

- `Sources/HomePortKit/HistoryStore.swift` — **à créer**. Modèle : `FleetStore` (`defaultPath` statique + init injectable + `expandPath`, cf. `FleetStore.swift:24-29`). `defaultPath = "~/.local/state/hpm/hpm.db"`. Porte : ouverture/migration, `begin`/`finish`, `tasks(machine:limit:)`, `task(id:)`, `purge`, `TaskEntry: Identifiable` (id = rowid, pour `DataTable`), enum statut (`running`, `success`, `failure`, `interrupted` — ce dernier réservé à 1.3, aucun écrivain ici), `ISO8601DateFormatter` dédié UTC (le `timestampFormatter` de `Manager+Backup.swift:100` est local-time, **non réutilisable**).
- `Sources/HomePortKit/Manager+Prereqs.swift:11-30` — déclaration de `HomeportManager` (les autres fichiers sont des extensions). Ajouter la propriété `history: HistoryStore?` + paramètre d'init (défaut `nil` — garde les ~12 fichiers de test compilables), et l'état interne du seam (profondeur + tampon de capture verrouillé). Le `report` fourni est enveloppé pour dupliquer chaque ligne vers le tampon pendant une action journalisée (`Reporter`, `HPMError.swift:9`).
- `Sources/HomePortKit/Manager+Journal.swift` — **à créer** : seam `journaled<T>(_ action: String, on: Machine, _ body:) throws -> T`. Profondeur > 0 ou `history == nil` → exécute le corps tel quel. Un manager journalise une action utilisateur à la fois (vrai de tous les sites d'appel : un manager par machine dans `forEachMachine`, un par `run` dans l'app).
- Actions à envelopper (le corps existant devient le closure) : `Manager+Backup.swift:31` (`backup`), `Manager+Restore.swift:6` (`restore`), `Manager+Install.swift:7` (`install`), `:38` (`update`), `Manager+Remove.swift:7` (`remove`), `Manager+Service.swift:16` (`restart`), `Manager+Doctor.swift:7` (`doctor`), `Manager+Prereqs.swift:32` (`prereqs`), `Manager+Config.swift:33` (`configPull`, action `config-pull`), `:73` (`configPush`, action `config-push`). **Pas** `status`, `logs`, `installedVersion`, `configDiff`, `checkHealth` (interne).
- `Sources/hpm/HPM.swift:20-28` — `makeManager` : point de câblage unique du CLI ; y construire le `HistoryStore` (do/catch → avertissement stderr et `nil` en échec). `:10-14` — enregistrer `TasksCmd` dans `subcommands`.
- `Sources/hpm/Commands.swift` — ajouter `TasksCmd` en fin de fichier. Rendu tabulaire : reprendre `StatusCmd.printTable(_:)` (`:93-100`). La commande `logs` (`:253-272`) montre le style d'options (`.customShort`/`.customLong`).
- `App/Sources/FleetModel.swift:35-48` — init = **le** hook de démarrage app (pas de `AppDelegate` ; `.onAppear` d'un `MenuBarExtra` ne se déclenche qu'à l'ouverture du menu) : y lancer la purge hors MainActor. `:36-41` — factory : injecter le `HistoryStore` partagé. `:142-173` — `run(_:on:)` : après complétion, recharger les tâches publiées. Publier `tasks: [HistoryStore.TaskEntry]` chargées hors MainActor.
- `App/Sources/MachineDetailView.swift:125-146` — `summary` : ajouter la section « Tâches récentes » (filtre `model.tasks` sur la machine, ~10 dernières) après le bloc `field(...)` ; le `ScrollView` du `body` (`:72-76`) absorbe déjà le débordement.
- `App/Sources/FleetOverviewView.swift:17-37` — historique global (~50) entre le `DataTable` flotte et le `Spacer` (`:28`) ; ⚠️ cette vue n'a **pas** de `ScrollView` — envelopper le contenu.
- `App/Sources/DesignComponents.swift:229-259` — `DataColumn`/`DataTable` (Row: Identifiable ; le titre `String` **est** la clé du catalogue), `:355` `EmptyStateView`, `:85` `StatusPill`. `App/Sources/Theme.swift:92-99` — rôles : `eyebrow` (en-têtes), `data` (mono — horodatages, actions, sortie), `body`.
- `App/Sources/Localizable.xcstrings` — catalogue **manuel** (`extractionState: manual`) : chaque nouvelle clé y entre à la main en en/fr/zh-Hans.
- `Tests/HomePortKitTests/PrereqsTests.swift:5-19` — `makeTestManager` : ajouter un paramètre de chemin de base temporaire. `MockProcessRunner.swift` — stubs par sous-chaîne. Convention XCTest, racines `NSTemporaryDirectory()` nettoyées en `tearDown` (WAL crée `-wal`/`-shm` → supprimer le répertoire).
- `Package.swift` — `import SQLite3` s'autolink sur Darwin ; **seulement si** le build échoue, ajouter `linkerSettings: [.linkedLibrary("sqlite3")]` au target HomePortKit.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/HomePortKit/HistoryStore.swift` — créer le propriétaire de `hpm.db` : ouverture (mkdir parents, WAL, `busy_timeout` 5 000 ms, verrou interne sur le handle), migration v1 (`tasks` : id, started_at, finished_at nullable, machine, action, status, output ; `locks` : machine PK, pid, acquired_at, task_id nullable), garde `user_version` supérieur, `begin(action:machine:) -> Int64`, `finish(id:status:output:)`, `tasks(machine:limit:)` tri id décroissant, `task(id:)`, `purge(now:)` (1 an puis plafond 10 000, retourne le nombre supprimé) — le socle AD-7 que 1.3, l'epic 2 et l'epic 3 étendront par migration.
- [x] `Sources/HomePortKit/Manager+Prereqs.swift` — ajouter `history: HistoryStore?` (init, défaut `nil`), le tampon de capture et l'enveloppe du `Reporter` — la sortie du journal vient du flux `report`, seul canal narratif commun aux actions.
- [x] `Sources/HomePortKit/Manager+Journal.swift` — créer le seam `journaled(_:on:_:)` : profondeur (pas de double entrée sur composition), `begin` au départ, `finish(success|failure + sortie [+ erreur])` à la fin, re-levée de l'erreur d'origine, no-op complet si `history == nil` — la parité CLI/app par construction (AD-13).
- [x] `Sources/HomePortKit/Manager+{Backup,Restore,Install,Remove,Service,Doctor,Prereqs,Config}.swift` — envelopper les 10 actions utilisateur listées au Code Map dans `journaled` avec leurs identifiants stables — chaque action initiée du Mac est historisée, les lectures jamais.
- [x] `Sources/hpm/HPM.swift` — construire le `HistoryStore` dans `makeManager` (avertissement stderr + dégradation si échec) et enregistrer `TasksCmd` — le CLI journalise sans autre changement.
- [x] `Sources/hpm/Commands.swift` — créer `TasksCmd` (`hpm tasks [--machine <nom>] [--limit N=50] [--id <n>]`) : table `printTable` (ID, DATE, MACHINE, ACTION, STATUS) du plus récent au plus ancien ; `--id` affiche l'entrée complète avec sa sortie ; jamais de purge — FR11.
- [x] `App/Sources/FleetModel.swift` — injecter le `HistoryStore` partagé dans la factory, publier `tasks` (chargées hors MainActor à l'init, après chaque `run` et à chaque `refresh`), lancer `purge()` à l'init en `Task.detached` — l'app seule fait le ménage (NFR7).
- [x] `App/Sources/MachineDetailView.swift` — section « Tâches récentes » du Résumé : `DataTable` (date, action, statut en pill couleur+libellé) des ~10 dernières tâches de la machine, `EmptyStateView` si aucune — l'AC app de FR6.
- [x] `App/Sources/FleetOverviewView.swift` — section « Historique » sous la table de flotte : `DataTable` global (date, machine, action, statut) des ~50 dernières, vue enveloppée d'un `ScrollView` — l'historique global de FR6.
- [x] `App/Sources/Localizable.xcstrings` — ajouter les clés des nouvelles surfaces (titres de section, en-têtes, statuts, états vides) en en/fr/zh-Hans — aucune chaîne en dur (UX-DR4).
- [x] `Tests/HomePortKitTests/HistoryStoreTests.swift` — couvrir la matrice côté store : création/PRAGMA (WAL, user_version, tables), begin/finish, format ISO 8601 UTC, tri, filtre machine (y compris inconnu), purge âge, purge volume, réouverture sans re-migration, `user_version` supérieur, deux stores concurrents — le socle doit être irréprochable avant que 1.3 s'y appuie.
- [x] `Tests/HomePortKitTests/JournalSeamTests.swift` — couvrir le seam via `makeTestManager` (+ chemin db temporaire) : action réussie, action échouée (statut + erreur dans la sortie + re-levée), `update` = une seule entrée, manager sans `history` = aucun fichier créé — les comportements que frontends et 1.3 tiennent pour acquis.

**Acceptance Criteria:**
- Given une flotte configurée et `hpm.db` inexistant, when une action kit s'exécute (CLI ou app), then `~/.local/state/hpm/hpm.db` existe avec `journal_mode=wal`, `user_version=1` et les tables journal + verrous (vérifiable au `sqlite3` CLI), créée exclusivement par `HistoryStore`.
- Given une action `hpm backup <machine>` terminée (succès ou échec), when `hpm tasks`, then l'entrée apparaît (horodatage ISO 8601 UTC, machine, action, statut) et `hpm tasks --id <n>` restitue sa sortie complète.
- Given des entrées pour deux machines, when `hpm tasks --machine <nom>`, then seules les entrées de cette machine s'affichent, du plus récent au plus ancien.
- Given `hpm update <machine>`, when la commande se termine, then le journal contient **une** entrée `update` — ni `backup` ni `install` imbriqués.
- Given un journal dépassant 10 000 entrées ou contenant des entrées de plus d'un an, when l'app démarre, then l'excédent est purgé ; when `hpm tasks` s'exécute, then rien n'est purgé.
- Given l'app ouverte sur une machine, when l'onglet Résumé s'affiche, then ses tâches récentes apparaissent (date, action, statut en couleur + libellé) ; la vue Flotte montre l'historique global ; en fr, en et zh-Hans sans chaîne en dur, contenu machine en mono non traduit.
- Given une action lancée depuis l'app qui échoue, when elle se termine, then l'entrée journal porte le statut `failure` et sa sortie contient le message d'erreur.

## Spec Change Log

## Review Triage Log

### 2026-08-23 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 7: (high 0, medium 4, low 3)
- defer: 3: (high 0, medium 1, low 2)
- reject: 14
- addressed_findings:
  - `[medium]` `[patch]` `TasksCmd --limit` non validé (trap `Int32` sur très grande valeur, LIMIT négatif = illimité) — guard 1...10 000 dans le CLI + clamp défensif dans `HistoryStore.tasks` + test `testWildLimitsAreClampedNotTrapped`.
  - `[medium]` `[patch]` `busy_timeout` armé après `PRAGMA journal_mode=WAL` dans l'init — déplacé immédiatement après `sqlite3_open`, une collision app+CLI à la première ouverture attend au lieu de dégrader.
  - `[medium]` `[patch]` `FleetModel.run` ne rechargeait le journal que via `refresh()` (gardé par `!refreshing`) — `reloadTasks()` appelé inconditionnellement à la complétion d'une action.
  - `[medium]` `[patch]` `reloadTasks` : cap 500 pouvait affamer le filtre client de « Tâches récentes » (limit → 10 000, plafond de rétention) ; une erreur de lecture transitoire publiait une liste vide (la liste précédente est conservée).
  - `[low]` `[patch]` `purge()` : finalize hors `defer` (fuite sur erreur) et DELETE hors transaction — `defer` + `BEGIN IMMEDIATE`…`COMMIT`/`ROLLBACK`.
  - `[low]` `[patch]` Tables journal sans annonce VoiceOver de ligne — `rowLabel` fourni sur les deux tables (action, machine, statut localisé, date) + support `rowLabel` hors `onSelect` dans `DataTable`.
  - `[low]` `[patch]` `history == nil` affichait « No tasks yet » (faux) — état distinct « Task journal unavailable » via `FleetModel.historyAvailable`, clés en/fr/zh-Hans ajoutées.

### 2026-08-23 — Review pass (2)
- intent_gap: 0
- bad_spec: 0
- patch: 7: (high 0, medium 3, low 4)
- defer: 1: (high 0, medium 0, low 1)
- reject: 20
- addressed_findings:
  - `[medium]` `[patch]` `HistoryStore.tasks`/`task(id:)` : une erreur `sqlite3_step` en cours d'itération (BUSY, CORRUPT) retournait une liste tronquée — ou un `nil` — comme un succès. Le code de retour final est vérifié : tout code ≠ `SQLITE_DONE` lève désormais.
  - `[medium]` `[patch]` `FleetModel.reloadTasks` chargeait la colonne `output` des 10 000 entrées à chaque refresh (5 min) alors qu'aucune surface de liste ne la rend — paramètre `includeOutput:` ajouté à `tasks()`, l'app lit sans les sorties.
  - `[medium]` `[patch]` 7 des 10 actions enveloppées (restore, install, remove, doctor, prereqs, config-pull, config-push) n'avaient aucun test de journalisation : retirer un wrapper `journaled` ou altérer un identifiant stable laissait la suite verte — test `testEveryOtherWrappedActionJournalsItsStableIdentifier` ajouté (une entrée par action, identifiants pinnés, imbrications remove→backup et doctor→prereqs silencieuses).
  - `[low]` `[patch]` Constante 10 000 dupliquée en quatre points (cap privé, clamp de lecture, reload app, guard CLI) — `HistoryStore.retentionCap` rendu public et référencé partout.
  - `[low]` `[patch]` Course de publication dans `reloadTasks` (rechargement post-action vs refresh périodique) : un instantané plus ancien pouvait écraser le plus récent — compteur de génération confiné au MainActor.
  - `[low]` `[patch]` `hpm tasks` créait la base sur une machine vierge (contraire à son commentaire « read-only » et à l'AC qui fait naître hpm.db à la première action) et `--id` combiné à `--machine` ignorait le filtre en silence — guard d'existence du fichier + exclusivité `--id`/`--machine`.
  - `[low]` `[patch]` `Spacer(minLength: 0)` inerte hérité de la version pré-`ScrollView` de `FleetOverviewView` — supprimé.

### 2026-08-23 — Review pass (3)
- intent_gap: 0
- bad_spec: 0
- patch: 11: (high 0, medium 3, low 8)
- defer: 0
- reject: 14
- addressed_findings:
  - `[medium]` `[patch]` Toute commande CLI — y compris les lectures pures (`status`, `releases`, `logs`, `config diff`) — créait `hpm.db` sur une machine vierge via le `HistoryStore` construit systématiquement par `makeManager`, contredisant le principe « la première *action* crée la base » posé par `TasksCmd` — paramètre `journal:` ajouté à `makeManager`, les lectures passent `journal: false` et ne construisent plus le store.
  - `[medium]` `[patch]` `tasks(includeOutput: false)` — l'unique chemin de lecture de l'app — n'était exercé par aucun test : une régression confinée à cette branche SQL laissait toute la suite verte pendant que l'UI journal restait vide — test `testListWithoutOutputKeepsEveryOtherField` ajouté.
  - `[medium]` `[patch]` Aucune vue ne rechargeait le journal à l'apparition : une action lancée du CLI n'apparaissait dans une app ouverte qu'au tick de 5 min — `model.reloadTasks()` ajouté au `onAppear` de `FleetOverviewView` et `MachineDetailView`.
  - `[low]` `[patch]` Message « Task journal unavailable » doublement inexact (« until this file becomes writable again » : l'app ne retente jamais avant relancement, et le cas version-de-schéma-trop-récente n'est pas une affaire de droits) — reformulé en en/fr/zh-Hans.
  - `[low]` `[patch]` `hpm tasks --id` rejetait `--machine` mais ignorait `--limit` en silence — `--limit` devenu optionnel (défaut 50) et exclusivité `--id`/`--limit` appliquée.
  - `[low]` `[patch]` L'annonce VoiceOver dictait l'ISO 8601 brut — le timestamp de `taskAnnouncement` passe par un format de date parlé ; l'affichage écran reste l'ISO mono non traduit.
  - `[low]` `[patch]` La section « History » s'empilait sous l'état vide d'onboarding (aucune machine, aucune tâche) — masquée tant que flotte et journal sont vides.
  - `[low]` `[patch]` `_ = try? history.purge()` avalait un échec durable de purge (NFR7 silencieusement non appliqué) — avertissement stderr en échec.
  - `[low]` `[patch]` `PRAGMA journal_mode=WAL` s'exécutait avant la garde `user_version` : ouvrir une base plus récente pouvait en réécrire le mode journal alors que l'intent dit « base intouchée » — garde déplacée avant le pragma.
  - `[low]` `[patch]` Aucun test ne vérifiait qu'une lecture pure sur un manager AVEC history ne journalise pas (AD-16) — test `testPureReadsNeverJournal` ajouté (`status` + `logs`, journal vide).
  - `[low]` `[patch]` La promesse de dégradation du seam (`begin` échoue → l'action s'exécute quand même) n'était vérifiée par rien — test `testJournalWriteFailureDegradesWithoutBlockingAction` ajouté (sabotage `DROP TABLE` par seconde connexion).

### 2026-08-23 — Review pass (4)
- intent_gap: 0
- bad_spec: 0
- patch: 7: (high 0, medium 1, low 6)
- defer: 0
- reject: 20
- addressed_findings:
  - `[medium]` `[patch]` L'ordre garde-`user_version`-avant-pragma-WAL (invariant « base plus récente intouchée », fixé en passe 3) n'était épinglé par aucun test — la fixture de `testNewerSchemaVersionRefusedAndUntouched` étant déjà en WAL, inverser l'ordre laissait la suite verte. Le test passe la base en `journal_mode=DELETE` avant le refus et vérifie que le mode survit.
  - `[low]` `[patch]` `entry(from:)` masquait une ligne corrompue (horodatage imparsable, statut inconnu) en la retirant des listes et en faisant dire à `task(id:)` « no task with id N » — la corruption lève désormais une `HPMError` nommant la ligne ; test `testCorruptRowSurfacesAsErrorNotAbsence`.
  - `[low]` `[patch]` `finish(id:)` sur une ligne absente (purgée en cours d'action, altération externe) était un UPDATE-0-ligne silencieux — garde `sqlite3_changes > 0` + test `testFinishOnMissingRowThrowsInsteadOfSilentNoOp` ; contrat de lecture `interrupted` épinglé pour 1.3 (`testInterruptedRowsReadBack`).
  - `[low]` `[patch]` Le seam avalait les échecs `begin`/`finish` (`try?`) sans aucune trace — une entrée pouvait ne jamais atterrir ou rester `running` sans que rien ne le signale — avertissement stderr émis, cohérent avec l'échec de purge.
  - `[low]` `[patch]` `TasksCmd` chargeait la colonne `output` des 50–10 000 entrées pour une table qui ne la rend jamais — `includeOutput: false` sur le chemin liste, comme l'app.
  - `[low]` `[patch]` Codes retour `sqlite3_bind_*` jamais vérifiés (un bind échoué laissait le paramètre NULL ou surfaçait en erreur `step` sans rapport) — helpers `bind` levants dans `begin`, `finish`, `tasks`, `task(id:)`, `purge`.
  - `[low]` `[patch]` `reloadTasks` republiait un instantané identique de 10 000 entrées à chaque tick de 5 min (re-diff SwiftUI des deux tables) — publication sautée quand `entries == tasks`.

### 2026-08-23 — Review pass (5)
- intent_gap: 0
- bad_spec: 0
- patch: 6: (high 0, medium 0, low 6)
- defer: 1: (high 0, medium 1, low 0)
- reject: 20
- addressed_findings:
  - `[low]` `[patch]` `entry(from:)` violait sa propre doctrine « corruption = erreur » pour `finished_at` : une valeur non vide imparsable devenait silencieusement `nil` (tâche close relue comme jamais terminée) — levée d'`HPMError` alignée sur `started_at`/`status` + test `testCorruptFinishedAtSurfacesAsErrorNotRunning`.
  - `[low]` `[patch]` `FleetModel.reloadTasks` avalait toute erreur de lecture (`try?`) sans aucune trace : une base durablement illisible laissait l'UI figée en silence — do/catch + avertissement stderr, cohérent avec les échecs de purge et d'écriture ; la liste précédente reste conservée.
  - `[low]` `[patch]` La moitié en échec de la garde de profondeur n'était pas testée (update dont le backup imbriqué échoue) — test `testComposedUpdateFailureJournalsSingleFailureEntry` : une seule entrée `update` close en `failure`, aucune ligne imbriquée orpheline.
  - `[low]` `[patch]` `printTable`, helper global partagé, trappait sur une liste vide (`rows[0]`) — guard sur `rows.first`.
  - `[low]` `[patch]` `hpm tasks --id N` sur machine vierge sortait en succès (« No tasks recorded yet. ») alors que le même id absent d'une base existante échoue — la garde d'existence du fichier lève la même erreur « no task with id N » quand `--id` est demandé (et le message vide liste mentionne le filtre machine, comme la branche liste).
  - `[low]` `[patch]` La condition d'onboarding de `FleetOverviewView` masquait aussi `TaskJournalUnavailableView` (flotte vide + `history == nil` → `tasks` forcément vide) : le seul signal visible d'un hpm.db inouvrable disparaissait — la section s'affiche dès que le journal est indisponible.

## Design Notes

**Lignes in-flight, pas INSERT-à-la-fin.** L'AC dit « enregistrée à sa fin », mais AD-12 (1.3) exige de clore en `interrupted` une tâche dont le process est mort — impossible si la ligne n'existe qu'au succès. Le seam ouvre donc la ligne en `running` au départ et la finalise à la fin : l'AC reste satisfait (l'entrée complète existe dès la fin), et 1.3 n'aura pas à changer le schéma. Un crash avant 1.3 laisse une ligne `running` orpheline — assumé, c'est précisément ce que 1.3 résorbera. `task_id` dans `locks` relie le futur verrou à sa tâche à clore.

**Table de verrous sans API.** 1.2 livre le schéma (`machine`, `pid`, `acquired_at`, `task_id`) ; acquisition, TTL, reprise et `hpm unlock` sont la story 1.3 (EPICS AC 1.3). N'écrire aucune ligne de `locks` ici.

**Choix libres tranchés** (aucun document ne les fixe) : `busy_timeout` = 5 000 ms ; noms de tables `tasks`/`locks` ; tri par `id DESC` (monotone, sans parse de date) ; pas d'index (NFR6 : < 10 machines, ≤ 10 000 lignes) ; limite CLI par défaut 50.

**Sortie = flux `Reporter`.** La plupart des actions retournent `Void` ; le narratif passe par `report`. Le manager enveloppe le reporter fourni pour dupliquer vers un tampon pendant l'action journalisée ; en échec, le message `HPMError` est appété à la sortie. L'app passe aujourd'hui `{ _ in }` (`FleetModel.swift:150`) — le journal capture quand même, dans le kit.

**Dégradation, jamais blocage.** Un Mac au répertoire d'état cassé doit rester administrable : `history` optionnel, avertissement au frontend, action inchangée. En revanche `TasksCmd` (lecture) propage l'erreur — pas de journal lisible, autant le dire.

**Affichage app.** Les identifiants d'action et horodatages sont des données (`Theme.data`, mono, non traduits) ; les libellés de statut sont des concepts d'app (localisés, pill couleur + libellé : success→ok, failure→critical, running→warning). La consultation de la sortie complète passe par `hpm tasks --id` — les surfaces app de cette story sont des listes (l'AC ne demande pas plus).

## Verification

**Commands:**
- `swift build` — expected: compilation sans erreur (y compris `import SQLite3` autolinké).
- `swift test` — expected: suite complète verte, dont `HistoryStoreTests` et `JournalSeamTests` couvrant chaque ligne de la matrice ; aucune régression.
- `cd App && xcodegen generate && xcodebuild -project HomePortMenu.xcodeproj -scheme HomePortMenu -configuration Debug build CODE_SIGNING_ALLOWED=NO` — expected: `BUILD SUCCEEDED`.
- `HPMTESTDB=$(mktemp -d)/hpm.db` puis `sqlite3 <db> "PRAGMA user_version; PRAGMA journal_mode; .tables"` après un premier usage — expected: `1`, `wal`, `locks tasks`.

**Manual checks (if no CLI):**
- Lancer une action depuis l'app (Backup) : l'entrée apparaît dans « Tâches récentes » du Résumé et dans l'historique de la vue Flotte sans relancer l'app.
- Basculer l'app en fr/zh-Hans : sections et statuts traduits, actions/horodatages en mono inchangés.

## Auto Run Result

**Passe de review de suivi (5) — 2026-08-23.** Story déjà `done` ; re-review complète du diff depuis `e9a257aea7e6b56842e5486b2a4eb61a81014f7e` par 4 couches parallèles (blind-hunter, edge-case-hunter, verification-gap, intent-alignment).

**Résumé du changement de cette passe :** durcissement de la lecture du journal (corruption `finished_at` désormais levée, erreurs de lecture app tracées), cohérence CLI (`--id` sur base absente = erreur, `printTable` sûr sur liste vide), visibilité de l'état « journal indisponible » sous onboarding, et deux tests de plus (composition en échec, corruption `finished_at`).

**Fichiers modifiés :**
- `Sources/HomePortKit/HistoryStore.swift` — `entry(from:)` lève sur un `finished_at` non vide imparsable (doctrine corruption = erreur complétée).
- `App/Sources/FleetModel.swift` — `reloadTasks` trace les échecs de lecture sur stderr au lieu de les avaler (`try?` → do/catch, liste précédente conservée).
- `App/Sources/FleetOverviewView.swift` — la section History s'affiche dès que le journal est indisponible, même flotte vide (l'avertissement n'est plus masqué par l'onboarding).
- `Sources/hpm/Commands.swift` — `printTable` guard sur liste vide ; `hpm tasks --id` sur base absente lève la même erreur qu'un id manquant ; message vide-liste avec filtre machine harmonisé.
- `Tests/HomePortKitTests/HistoryStoreTests.swift` — `testCorruptFinishedAtSurfacesAsErrorNotRunning`.
- `Tests/HomePortKitTests/JournalSeamTests.swift` — `testComposedUpdateFailureJournalsSingleFailureEntry`.

**Bilan des findings :** 6 patches appliqués (0 high, 0 medium, 6 low) ; 1 différé (medium : câblage CLI `journal: false` sans vérification exécutable — ajouté au `deferred` du frontmatter) ; 20 rejetés (dont : « data race » sur `reloadGeneration` — faux positif, `FleetModel` est `@MainActor` ; modifications de `sprint-status.yaml` et artefacts d'orchestration — propriété de l'orchestrateur ; items déjà consignés en DW-1…DW-4 ; choix d'intent explicites comme la purge au seul démarrage).

**Recommandation de re-review :** patched = 0 high, 0 medium, 6 low → score 3×0 + 1×6 = 6 ≥ 5 → `followup_review_recommended: true`.

**Vérification :** `swift build` OK ; `swift test` 136/136 verts (dont les 2 nouveaux tests, vérifiés individuellement) ; `xcodegen generate` + `xcodebuild -scheme HomePortMenu -configuration Debug` → `BUILD SUCCEEDED` ; frontmatter YAML revalidé (5 items `deferred` intacts).

**Risques résiduels :** les surfaces CLI exécutée et app rendue restent sans tests exécutables (consigné dans `deferred`, motif pré-existant au repo) ; la re-review recommandée découle du volume de petits patches, pas d'un doute sur un comportement précis.

