---
title: '1.3 — Actions machine avec confirmations'
type: 'feature'
created: '2026-08-23'
status: 'done'
baseline_revision: '43d226d40c4c41530cb26d25dcfb5e6f70ec818b'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/docs/build/epic-1-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      La logique 1.3 côté app (gating destructif isDestructive → sheet, dispatch de
      run(_:on:), toast, inFlight par machine) n'a aucune vérification exécutable.
    evidence: |-
      Le target App n'a aucun test (pré-existant au repo : Package.swift ne déclare que
      HomePortKitTests). Retirer `.remove` de la branche destructive d'isDestructive
      supprimerait la confirmation UX-DR6 du bouton le plus dangereux sans qu'aucun test
      ne rougisse. Piste : déplacer Action (pur, sans UI) dans HomePortKit, ou ajouter un
      bundle de tests app au xcodeproj.
    location: >-
      App/Sources/FleetModel.swift, App/Sources/MachineDetailView.swift
    severity: medium
  - summary: >-
      Les peaux CLI de la story (UnlockCmd — garde fileExists, textes — et la
      confirmation --yes d'UpdateCmd) n'ont aucune vérification exécutable.
    evidence: |-
      Même parapluie pré-existant que DW-1/DW-6 : aucun test target ne dépend de
      l'exécutable hpm. La logique testable (HistoryStore.unlock, refus/reprise) est
      volontairement dans le kit et couverte ; seuls le câblage ArgumentParser et les
      sorties texte restent non testés.
    location: >-
      Sources/hpm/Commands.swift (UnlockCmd, UpdateCmd)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Aucune action hpm n'est déclenchable depuis la fiche machine — l'administrateur retombe au terminal — et rien n'empêche deux mutations concurrentes (app + CLI) de se marcher dessus : le verrou AD-12 n'existe qu'à l'état de table vide, et un crash laisse une tâche `running` orpheline pour toujours.

**Approach:** Implémenter la sémantique du verrou persistant dans `HistoryStore` (acquisition atomique, TTL 30 min, détection process mort par PID, reprise auto avec clôture de l'orphelin en `interrupted`), l'acquérir dans le seam `journaled` pour la parité CLI/app par construction, livrer `hpm unlock <machine>`, et poser la barre d'actions du Résumé (Backup, Restart, Doctor, Config + Restore/Remove/Update destructives derrière une sheet UX-DR6), avec boutons désactivés + « … en cours » au bandeau pendant une mutation et résultat affiché (toast succès / erreur visible).

## Boundaries & Constraints

**Always:**
- Le verrou vit dans la table `locks` de `hpm.db`, **schéma v1 inchangé** (`machine PK, pid, acquired_at, task_id` — gelé par `HistoryStoreTests`) ; toute la sémantique s'écrit dans `HistoryStore`, seul code à toucher la base (AD-2, AD-7). Aucune migration, aucun bump de `user_version`.
- Périmé = process détenteur mort (`kill(pid, 0)` → `ESRCH` ; `EPERM` = vivant) **ou** `acquired_at` vieux de plus de 30 min — même si le détenteur vit encore. Un verrou périmé est repris automatiquement à la prochaine acquisition ; sa tâche orpheline (`task_id` → ligne `running`) est close en `interrupted` avec une sortie explicative ; une ligne absente ou déjà close est tolérée sans erreur.
- Acquisition atomique via SQL (`BEGIN IMMEDIATE`, modèle `purge()`) — jamais via le `NSLock` interne : `hpm update --all` ouvre N stores dans un même process, et app + CLI sont deux process.
- L'acquisition se fait dans `journaled`, **avant** `begin`, gardée par la même profondeur (une composition = un seul verrou) ; libération en `defer`, y compris sur erreur du corps. Le refus de contention lève une `HPMError` nommant le détenteur (PID) et depuis quand, **avant** toute écriture journal — une action refusée n'est pas journalisée.
- Classification par site d'appel : prennent le verrou `backup`, `restore`, `install`, `update`, `remove`, `restart`, `config-push`, et `prereqs` seulement si `fix == true` ; ne le prennent pas `doctor`, `config-pull`, `prereqs(fix: false)` — lectures et écritures purement locales restent libres et parallèles (AD-12, AD-16).
- `history == nil` (répertoire d'état inutilisable) : ni journal **ni verrou** — l'action s'exécute, avertissement émis ; la doctrine 1.2 « jamais une action refusée parce que la base est inaccessible » prime.
- `hpm unlock <machine>` : refuse (erreur, exit ≠ 0) tant que le détenteur est vivant **et** dans le TTL, en affichant PID et horodatage de prise ; ne libère qu'un verrou périmé (même routine de reprise : orphelin clos en `interrupted`) ; base ou verrou absents = « rien à déverrouiller », succès. Comme `TasksCmd`, ne fait jamais naître `hpm.db`. La logique vit dans un point d'entrée `HistoryStore` testable par `swift test` ; la commande reste une peau.
- UI : tokens `Theme` + composants existants ; sheet de confirmation = seul endroit à fond `semanticCritical` (bouton), scrim natif de `.sheet` ; toast conforme au token DESIGN.md (fond `inverseCanvas`, texte `inverseInk`, `rounded.md`, coin bas droit, transitoire) ; toutes les chaînes app en en/fr/zh-Hans dans `Localizable.xcstrings` (catalogue manuel), contenu machine jamais traduit.
- CLI : `hpm update` (destructif d'après l'epic) obtient la confirmation explicite manquante, alignée sur le style `RestoreCmd` (`--yes` + `confirm()`).

**Block If:**
- Satisfaire un critère exigerait de modifier le schéma `locks`/`tasks` (migration v2) — le schéma v1 posé par 1.2 doit suffire.
- Le refus de contention devrait être journalisé comme entrée de tâche — le journal ne consigne que des actions exécutées ; changer cela est une décision produit.

**Never:**
- Pas de verrou côté Pi (`flock` timer/actions = epic 3), pas de file d'attente, pas de retry automatique après refus.
- Ne pas restyler le menubar (`MenuContent`) au-delà de l'adaptation `inFlight` : ses confirmations `NSAlert` existantes restent ; la sheet UX-DR6 est celle du centre de contrôle.
- Pas de bouton Config-push ni de sélection d'archive dans l'app : le bouton Config = `config-pull` ; Restore = archive la plus récente (`archive: nil`).
- Pas de modification de `docs/build/sprint-status.yaml` ni des invariants 1.2 (purge app seule, lectures pures non journalisées, `interrupted` réservé à la reprise de verrou).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Mutation libre | `backup` sur machine sans verrou | Verrou pris (pid, acquired_at, puis task_id), action exécutée, journalisée, verrou libéré (ligne supprimée) | Aucune |
| Contention | mutation pendant qu'un autre process vivant tient le verrou (< 30 min) | `HPMError` « held by pid N since <ISO 8601> » ; aucune entrée journal ; verrou intact | Refus propre, erreur re-levée au frontend |
| Course d'acquisition | 2 process acquièrent simultanément | Un seul gagne (atomicité SQL), l'autre reçoit le refus de contention | Aucune corruption |
| Verrou mort | détenteur au PID inexistant (`ESRCH`) | Reprise auto : orphelin `running` clos en `interrupted`, nouveau verrou pris, action continue | Aucune |
| Verrou TTL | `acquired_at` > 30 min, détenteur même vivant | Même reprise auto | Aucune |
| Orphelin introuvable | `task_id` NULL, purgé, ou déjà clos | Reprise sans clôture, aucune erreur | Tolérée silencieusement |
| Échec du corps | l'action verrouillée `throw` | Entrée close en `failure`, verrou libéré, erreur d'origine re-levée | Inchangé vs 1.2 |
| Non-verrouillante | `doctor` pendant un `backup` CLI | S'exécute sans contention ; aucune ligne `locks` créée | Aucune |
| `hpm unlock` détenteur vivant | verrou < 30 min, process vivant | Refus : PID + depuis quand affichés, exit ≠ 0, verrou intact | `HPMError` |
| `hpm unlock` périmé | verrou mort ou > 30 min | Verrou libéré, orphelin clos `interrupted`, confirmation affichée | Aucune |
| `hpm unlock` sans verrou | pas de ligne, ou `hpm.db` absent | « rien à déverrouiller », exit 0, base jamais créée | Aucune |
| Journal indisponible | `history == nil` | Action sans verrou ni journal, avertissement stderr/UI | Jamais bloquant |
| Sheet annulée | action destructive déclenchée puis Annuler | Rien : ni verrou, ni journal, ni exécution | Aucune |
| App refusée | action app pendant un verrou CLI | Échec visible (erreur affichée dans la fiche + notification), boutons réactivés | `HPMError` du kit |

</intent-contract>

## Code Map

- `Sources/HomePortKit/HistoryStore.swift` (351 l.) — table `locks` déjà créée (`:252-257`), **aucune API locks** ; `TaskStatus.interrupted` existe sans écrivain (`:19-23`) ; modèle transactionnel `BEGIN IMMEDIATE`…`COMMIT`/`ROLLBACK` dans `purge()` (`:208-229`) ; helpers `bind` levants, `sqliteError(_:)` (`:314`), `iso8601String(from:)` (`:56`), `finish(id:status:output:)` jette sur ligne absente (`:138-140`) — la reprise d'orphelin doit passer par une clôture tolérante, pas par `finish` nu. Ajouter : TTL public (30 min), sonde de vie injectable (`(pid_t) -> Bool`, défaut `kill(pid,0)`/`ESRCH`), acquisition/libération/rattachement `task_id`, consultation + reprise pour unlock.
- `Sources/HomePortKit/Manager+Journal.swift` (88 l.) — seam `journaled<T>(_:on:_:)` (`:51`) : `guard history` (`:52`), profondeur `journal.enter()` (`:53-55`), `begin` dégradant (`:60-66`), `finish` + re-levée (`:68-82`). Point d'insertion du verrou : après le garde de profondeur, avant `begin` ; libération en `defer`. Ajouter un paramètre de verrouillage au seam (les imbriqués passent tout droit — réentrance gratuite).
- `Sources/HomePortKit/Manager+Prereqs.swift` (`:11-44`) — déclaration de `HomeportManager` (ssh, releases, runner, report enveloppé, `history`, `journal`) ; `prereqs(on:fix:)` (`:46-48`) → verrou ssi `fix`.
- Sites d'appel `journaled` à classifier : `Manager+Backup.swift:33`, `Manager+Restore.swift:7` (archive nil = plus récente locale, `:11-17`), `Manager+Install.swift:8` (`install`), `:44` (`update`), `Manager+Remove.swift:8`, `Manager+Service.swift:17` (`restart`), `Manager+Doctor.swift:8` (sondes lecture seule), `Manager+Config.swift:34` (`config-pull`, local seul), `:78` (`config-push`). Compositions : `update`→`backup`+`install`, `remove`→`backup`, `doctor`→`prereqs` — couvertes par la profondeur.
- `Sources/hpm/HPM.swift` — subcommands (`:10-15`) : enregistrer `UnlockCmd` ; `makeManager(journal:report:)` (`:21-33`) inchangé ; `confirm(_:assumeYes:)` (`:44-49`) réutilisable ; ⚠️ `forEachMachine` = un manager par machine sous un même PID via `concurrentPerform` (`:69-109`).
- `Sources/hpm/Commands.swift` (387 l.) — `UpdateCmd` (`:145-157`) : **aucune confirmation aujourd'hui** ; ajouter `--yes` + `confirm()` (modèle `RestoreCmd` `:175-195`). `TasksCmd` (`:302-366`) : doctrine « une lecture ne fait pas naître la base » via `fileExists` (`:323`) — `UnlockCmd` l'hérite. `printTable` (`:95-101`). Erreurs : `HPMError` propagé (rendu ArgumentParser) ou `ExitCode(1)`.
- `App/Sources/FleetModel.swift` (255 l.) — `enum Action` limité à backup/restart/update (`:196-209`) : ajouter doctor, config (pull), restore, remove ; `run(_:on:)` (`:211-246`) : garde silencieuse `inFlight` (`:212`), switch (`:220-224`), résultat = `Notifier` + `lastError` (`:228-244`), puis `reloadTasks()`/`refresh()`. `inFlight: Set<String>` (`:13`) → porter l'action en cours (dict) pour le bandeau ; publier l'état de toast. Le kit refuse la contention inter-process ; la garde UI reste pour l'intra-app.
- `App/Sources/MenuContent.swift` — call-sites `inFlight` à adapter : `:47` (`!isEmpty`), `:73` (`contains`) ; boutons existants backup/restart/update (`:109-147`) avec `NSAlert confirm()` (`:197-204`) — conservés tels quels.
- `App/Sources/DesignComponents.swift` (396 l.) — `PillButtonStyle` (`:107-138`) : fond hard-codé `:135-137`, le commentaire `:105-106` réserve le fond rouge à la sheet 1.3 → ajouter la variante à fond `semanticCritical` ; `MachineBanner` (`:200-225`) : insérer l'indicateur « … en cours » (paramètre optionnel, zone `:216-217`) ; créer la sheet de confirmation et le toast (aucun `.sheet`/toast n'existe dans l'app).
- `App/Sources/MachineDetailView.swift` (281 l.) — `summary` (`:129-150`) : barre d'actions à insérer (après `unreachableNotice`/champs) ; seul bouton existant : Retry (`:203-206`) ; `lastError` jamais rendu ici — l'échec doit devenir visible dans la fiche. Présentation `.sheet` sur cette vue ; ⌘-raccourcis restent routés par `ControlCenterNSWindow.performKeyEquivalent` (`ControlCenterWindow.swift:46-51`) pendant la sheet.
- `App/Sources/ControlCenterWindow.swift` (`:24-25`) — racine `ControlCenterView(model:commands:)` : ancre de l'overlay toast (coin bas droit).
- `App/Sources/Theme.swift` — `semanticCritical #d2372f` (`:30`), `inverseCanvas`/`inverseInk` (`:18-19`), `Rounded.md/pill`, `Spacing` ; aucun littéral de style hors de ce fichier.
- `App/Sources/FleetOverviewView.swift` — réutiliser `taskStatusLabel` (`:234-241`, `interrupted` déjà libellé), `TaskStatusPill` (`:261-287`).
- `App/Sources/Localizable.xcstrings` — catalogue manuel, clé = texte source anglais, namespacing points seulement en collision ; chaque clé nouvelle en en + fr + zh-Hans.
- `Tests/HomePortKitTests/` — `makeTestManager` (`PrereqsTests.swift:6-21`, `historyPath:`), `MockProcessRunner` (stubs par sous-chaîne), `rawQuery`/`rawExec` (`HistoryStoreTests.swift:26-47`) pour fabriquer verrous périmés ; patron concurrence 2 stores (`:267-282`) ; `testInterruptedRowsReadBack` (`:195-205`) épingle la relecture ; assertion schéma `locks` (`:59-60`) à ne pas casser ; sabotage `DROP TABLE` (`JournalSeamTests.swift:132-146`).
- `App/project.yml` — dossier source : nouveau fichier Swift = `xcodegen generate`, rien à éditer.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/HomePortKit/HistoryStore.swift` — implémenter la sémantique du verrou : acquisition atomique (INSERT sur PK `machine` sous `BEGIN IMMEDIATE` ; détection périmé = sonde de vie injectable + TTL public 30 min ; reprise = clôture tolérante de l'orphelin en `interrupted` + remplacement de la ligne), rattachement `task_id`, libération par détenteur, consultation du verrou, et point d'entrée unlock (refus détenteur vivant avec PID + horodatage / libération si périmé) — le socle AD-12 que seam, CLI et app consomment.
- [x] `Sources/HomePortKit/Manager+Journal.swift` — étendre le seam : paramètre de verrouillage, acquisition avant `begin` (contention re-levée sans écriture journal), `task_id` rattaché après `begin`, libération en `defer` — parité app/CLI par construction (FR11), une composition = un verrou.
- [x] `Sources/HomePortKit/Manager+{Backup,Restore,Install,Remove,Service,Doctor,Config,Prereqs}.swift` — classifier les 10 sites d'appel : verrouillants backup/restore/install/update/remove/restart/config-push, `prereqs` ssi `fix` ; non-verrouillants doctor/config-pull — les lectures restent libres (AD-16).
- [x] `Sources/hpm/Commands.swift` — créer `UnlockCmd` (peau sur le point d'entrée kit ; doctrine `fileExists` de `TasksCmd` ; refus = erreur affichant qui/depuis quand, périmé = libération + confirmation) et ajouter la confirmation manquante d'`UpdateCmd` (`--yes` + `confirm()`, modèle `RestoreCmd`) — parité et garde-fou CLI.
- [x] `Sources/hpm/HPM.swift` — enregistrer `UnlockCmd` dans `subcommands` — la jumelle CLI exigée par l'epic.
- [x] `App/Sources/FleetModel.swift` — étendre `Action` (doctor, config=pull, restore=archive la plus récente, remove), porter l'action en cours par machine (remplace `inFlight: Set`), router les nouveaux cas dans `run(_:on:)`, publier le résultat (toast succès au passé ; échec visible fiche + notification conservée) — l'état unique que bandeau, boutons et toast observent.
- [x] `App/Sources/MenuContent.swift` — adapter les deux call-sites `inFlight` (`:47`, `:73`) au nouveau type — compilation du menubar, comportement inchangé.
- [x] `App/Sources/DesignComponents.swift` — variante de bouton à fond `semanticCritical` (seul emplacement autorisé : sheet), indicateur « … en cours » dans `MachineBanner`, composant sheet de confirmation UX-DR6 (titre au verbe, conséquence en une phrase, nom de machine répété, bouton critique, Annuler) et composant toast conforme au token DESIGN.md — les briques réutilisables des stories suivantes.
- [x] `App/Sources/MachineDetailView.swift` — barre d'actions du Résumé (Backup, Restart, Doctor, Config directs ; Update…, Restore…, Remove… via sheet), boutons désactivés pendant la mutation de la machine, erreur de dernière action visible dans la fiche — l'AC central de FR2.
- [x] `App/Sources/ControlCenterView` (via `ControlCenterWindow.swift:24-25`) — overlay toast coin bas droit sur la racine — le résultat s'affiche sans chercher.
- [x] `App/Sources/Localizable.xcstrings` — clés des boutons, titres/conséquences des trois sheets, « … en cours », toasts, états d'erreur, en en/fr/zh-Hans — aucune chaîne en dur (UX-DR4).
- [x] `Tests/HomePortKitTests/LockTests.swift` — couvrir la matrice côté store : acquisition/libération, contention vivante (message PID + depuis), course entre 2 stores (un seul gagne), reprise TTL et process mort (orphelin clos `interrupted`), orphelin absent toléré, unlock (vivant refusé / périmé libéré / absent), schéma v1 intact — le verrou doit être irréprochable avant que l'UI s'y fie.
- [x] `Tests/HomePortKitTests/JournalSeamTests.swift` — étendre : action verrouillante prend puis libère (y compris sur échec du corps), contention → aucune entrée journal, composition = un seul verrou, doctor/config-pull sans ligne `locks`, `history == nil` = ni verrou ni refus — les invariants que frontends et epic 3 tiennent pour acquis.

**Acceptance Criteria:**
- Given une machine sélectionnée et joignable, when Vincent déclenche Backup, Restart, Doctor ou Config depuis le Résumé, then l'action s'exécute via HomePortKit avec l'identité SSH de `fleet.yaml`, son résultat s'affiche dans le centre de contrôle (toast succès / erreur visible dans la fiche) et l'entrée apparaît dans « Tâches récentes » sans relancer l'app.
- Given une action destructive (Restore, Remove, Update) déclenchée depuis le Résumé, when la sheet s'affiche, then elle porte un titre au verbe, la conséquence en une phrase, le nom de la machine répété et un bouton de confirmation à fond `semanticCritical` — et Annuler n'exécute rien.
- Given une mutation en cours sur une machine (app ou CLI), when une autre mutation est tentée sur cette machine depuis l'autre frontend, then elle est refusée proprement avec un message nommant le détenteur (PID) et depuis quand, et rien n'est journalisé pour la tentative.
- Given une mutation en cours depuis l'app, when la fiche de la machine est affichée, then ses boutons d'action sont désactivés, le bandeau montre « <action> en cours… », et les lectures (statuts, tâches, autres machines) restent actives.
- Given un verrou laissé par un process mort ou pris depuis plus de 30 min, when une nouvelle mutation est tentée sur cette machine, then le verrou est repris automatiquement, la tâche orpheline est close en `interrupted` (visible dans `hpm tasks` et l'app), et l'action s'exécute.
- Given un verrou dont le détenteur est vivant et dans le TTL, when `hpm unlock <machine>`, then la commande refuse (exit ≠ 0) en affichant qui tient le verrou et depuis quand ; given un verrou périmé, then elle le libère et clôt l'orphelin en `interrupted` ; given aucun verrou ni base, then elle sort en succès sans créer `hpm.db`.
- Given le CLI, when `hpm update <machine>` s'exécute sans `--yes`, then une confirmation explicite est demandée ; when une commande mutante s'exécute, then elle acquiert le même verrou et journalise comme l'app (parité par construction).

## Spec Change Log

## Review Triage Log

### 2026-08-23 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 10: (high 0, medium 5, low 5)
- defer: 2: (high 0, medium 1, low 1)
- reject: 14
- addressed_findings:
  - `[medium]` `[patch]` Le résultat de doctor/config était jeté par l'app (`_ = try manager.doctor(...)`) : un doctor aux checks ✗ toastait « Doctor finished » — le toast porte désormais l'issue (tous OK / N en échec, détail dans `lastError`), config toaste le nombre de fichiers rapatriés.
  - `[medium]` `[patch]` `interrupted` n'était pas collant : le `finish()` tardif d'un détenteur dépassé par un takeover TTL réécrivait `interrupted` en `success` — UPDATE gardé par `AND status = 'running'` + test `testFinishCannotRewriteAnInterruptedTask`.
  - `[medium]` `[patch]` 6 des 8 sites verrouillants sans épingle de contention (passer `locking: false` sur remove laissait la suite verte) — test `testEveryLockingActionIsRefusedUnderAForeignLock` (8 actions, refus « held by pid », zéro entrée journal, zéro exécution du corps).
  - `[medium]` `[patch]` L'appel `attachTask` du seam n'était vérifié par rien (le supprimer laissait tout vert, cassant la clôture d'orphelin au takeover) — tests `testSeamAttachesTheJournalEntryToTheLock` (lecture du verrou pendant le corps via `report`) et `testAttachTaskAfterTakeoverIsANoOp`.
  - `[medium]` `[patch]` Un verrou au timestamp corrompu était indéverrouillable (`lockRow` jette → `acquireLock` et `unlock` échouaient à jamais) — ligne corrompue traitée comme périmée par acquire et unlock (`releasedCorrupt`), orphelin clos si `task_id` lisible ; `currentLock` garde corruption = erreur ; 2 tests.
  - `[low]` `[patch]` `defaultProcessProbe` sans garde : `kill(0,0)` sondait le groupe de process de l'appelant — `guard pid > 0`.
  - `[low]` `[patch]` `acquired_at` dans le futur rendait le verrou inexpirable (âge négatif jamais > TTL) — âge négatif = périmé + test.
  - `[low]` `[patch]` La sonde de production n'était exercée par aucun test (tous injectaient des closures) — `testDefaultProcessProbe` (getpid vivant, 0/-1 faux, enfant attendu mort).
  - `[low]` `[patch]` Confirmation de sheet pendant machine occupée = drop silencieux (`guard inFlight`) — refus publié dans `lastError` (clé en/fr/zh-Hans).
  - `[low]` `[patch]` La sheet Update n'annonçait pas la version cible pourtant connue (`latestTag`) — conséquence interpolée (%1$@/%2$@ dans les 3 langues), phrase générique conservée si tag inconnu.

### 2026-08-23 — Review pass (follow-up)
- intent_gap: 0
- bad_spec: 0
- patch: 11: (high 0, medium 2, low 9)
- defer: 0
- reject: 14
- addressed_findings:
  - `[medium]` `[patch]` Une panne d'infrastructure pendant `acquireLock` (ex. table `locks` détruite) refusait l'action, contredisant la doctrine 1.2 « jamais refusée parce que la base est inaccessible » — la contention a désormais son type `LockContentionError` (re-levé tel quel), toute autre erreur du verrou dégrade en avertissement et l'action s'exécute sans verrou ; test seam `testLockInfrastructureFailureDegradesWithoutBlockingAction`.
  - `[medium]` `[patch]` La notification système disait toujours « Action terminée : Diagnostic » même avec des checks en échec — son corps porte désormais le même verdict que le toast (clés partagées : verdict doctor, nombre de fichiers config, « … finished » par action).
  - `[low]` `[patch]` Le refus intra-app (« Une autre action est déjà en cours… ») écrit dans `lastError` pendant une action restait affiché après le succès de celle-ci — la branche succès écrit `outcome.problem` (nil efface).
  - `[low]` `[patch]` La sheet Update annonçait `latestTag` mais `run(.update)` installait `version: nil` (la dernière release au moment de l'exécution) — le tag est gelé à la confirmation et passé à `update(version:)`.
  - `[low]` `[patch]` `hpm unlock` affirmait « its orphaned task was closed as interrupted » dès que `task_id` était non-NULL, même si la ligne était déjà close ou purgée — `UnlockOutcome.released` porte `orphanClosed` (issu de `reclaim`), la ligne ne s'affiche que si la clôture a réellement eu lieu ; 2 tests.
  - `[low]` `[patch]` Un échec de `releaseLock` dans le `defer` du seam était rapporté comme « task journal write failed » — avertissement dédié nommant la machine, le TTL de 30 min et `hpm unlock`.
  - `[low]` `[patch]` `testAcquisitionRaceHasExactlyOneWinner` absorbait l'erreur du perdant par `try?` — il capture désormais les refus et asserte type `LockContentionError` + message « held by pid » (jamais un SQLITE_BUSY brut ; le `busy_timeout` de 5 s couvre la transaction courte du gagnant).
  - `[low]` `[patch]` Le finish tardif d'un détenteur dépassé par un takeover n'était épinglé qu'au niveau store — test seam `testLateFinishAfterTakeoverDegradesAndKeepsInterrupted` : l'action retourne son résultat, le verdict `interrupted` survit, le verrou du repreneur reste intact.
  - `[low]` `[patch]` Boutons de confirmation des sheets en français = noms (« Désinstallation ») — clés dédiées `confirm.update/restore/remove` à l'impératif (« Mettre à jour », « Restaurer », « Désinstaller ») en en/fr/zh-Hans.
  - `[low]` `[patch]` Un toast né d'une action menubar avant la première ouverture du centre de contrôle n'était jamais auto-dismissé (timer côté vue) — le timer vit désormais dans `FleetModel.showToast`.
  - `[low]` `[patch]` README : `hpm unlock` absent de la table des commandes, `update` absent de la liste des commandes à confirmation — ajoutés.

### 2026-08-23 — Review pass (follow-up 2)
- intent_gap: 0
- bad_spec: 0
- patch: 8: (high 0, medium 1, low 7)
- defer: 0
- reject: 16
- addressed_findings:
  - `[medium]` `[patch]` Un doctor réussi mais aux checks ✗ s'affichait sous le titre « Last action failed » (fiche) et en rouge/xmark au menubar — `lastError` devient `[String: LastReport]` avec `kind` (failure/finding) : le constat titre « Last action reported problems » en `semanticWarning` (clé en/fr/zh-Hans), le menubar passe au triangle orange ; seul un vrai échec s'annonce comme tel.
  - `[low]` `[patch]` Un même PID reprenant son propre verrou TTL-périmé pouvait voir le `defer` de l'action dépassée supprimer le verrou repris (`releaseLock` scopé (machine, pid) seulement) — `releaseLock` accepte `acquiredAt`, le seam passe son horodatage d'acquisition ; test `testScopedReleaseDoesNotFreeASamePidReacquiredLock`.
  - `[low]` `[patch]` `UnlockOutcome.releasedCorrupt` jetait le retour de `reclaim` : la clôture réelle d'un orphelin n'était jamais rapportée pour un verrou corrompu — `releasedCorrupt(orphanClosed:)`, `UnlockCmd` affiche la même ligne que `.released`, test corrupt renforcé.
  - `[low]` `[patch]` L'overlay toast interceptait les clics sous lui pendant ses 4 s — `.allowsHitTesting(false)`.
  - `[low]` `[patch]` Le commentaire de l'overlay affirmait honorer `prefers-reduced-motion` sans qu'aucun mécanisme n'existe — commentaire corrigé (aucune revendication d'accessibilité non tenue).
  - `[low]` `[patch]` L'absence délibérée de `.defaultAction` sur le bouton critique de la sheet n'était pas actée — commentaire de contrainte posé (Retour ne confirme jamais une destruction).
  - `[low]` `[patch]` `warnLockStuck` codait « 30 min » en dur à côté de la constante publique `HistoryStore.lockTTL` — le message dérive de la constante.
  - `[low]` `[patch]` Pluriels « (s) » ad hoc des toasts doctor/config — variations plurielles du catalogue (`one`/`other` en en/fr, zh-Hans invariant), clés inchangées.

## Design Notes

**Verrou dans le seam, gated par site d'appel.** « Mutation » n'est pas « action journalisée » : doctor (sondes lecture seule) et config-pull (écrit côté Mac uniquement) sont journalisés mais ne mutent pas la machine — les verrouiller contredirait « les lectures restent libres et parallèles » (AD-12). La classification est déclarée à chaque site d'appel, pas déduite : elle reste visible, testable et stable.

**Config = config-pull.** L'AC groupe Config avec les actions sans confirmation ; `config-push` exige déjà une confirmation côté CLI et demanderait un choix de fichier côté UI. Le bouton rapatrie donc la config (`configPull`), résultat affichable et journalisé (`config-pull`). Push et diff restent CLI.

**Pas de verrou sans base.** Le verrou vit dans `hpm.db` par décision d'architecture ; si la base est inutilisable, la doctrine 1.2 (« dégrade sans bloquer ») prime : action sans verrou ni journal, avertissement. Un Mac au répertoire d'état cassé reste administrable.

**PID recyclé accepté.** L'identité du détenteur est PID + horodatage (schéma v1 gelé) : un PID recyclé est indiscernable d'un détenteur vivant, borné par le TTL de 30 min — l'arbitrage de l'intent, pas un oubli. La sonde de vie est injectable pour les tests (un PID mort réel n'est pas fabricable de façon déterministe).

**Refus non journalisé.** Le journal consigne des actions exécutées ; une tentative refusée n'a ni début ni fin. Le refus se voit dans le message d'erreur (CLI) ou la fiche (app).

**Menubar conservé.** Ses boutons backup/restart/update confirment déjà via `NSAlert` ; la sheet UX-DR6 est la voix du centre de contrôle. Restyler le menubar serait du scope gratuit — seule l'adaptation `inFlight` le touche.

**Toast + erreur, pas toast seul.** DESIGN.md définit le toast comme confirmation transitoire (« confirme au passé ») ; un échec mérite un foyer persistant — l'erreur de dernière action devient visible dans la fiche (elle n'existait que dans le menubar), la notification système est conservée.

## Verification

**Commands:**
- `swift build` — expected: compilation sans erreur.
- `swift test` — expected: suite complète verte, dont `LockTests` et les extensions `JournalSeamTests` couvrant chaque ligne de la matrice ; aucune régression (l'assertion de schéma `locks` et `testInterruptedRowsReadBack` restent verts).
- `cd App && xcodegen generate && xcodebuild -project HomePortMenu.xcodeproj -scheme HomePortMenu -configuration Debug build CODE_SIGNING_ALLOWED=NO` — expected: `BUILD SUCCEEDED`.

**Manual checks (if no CLI):**
- Depuis la fiche : Backup direct → toast « … terminé » + entrée dans Tâches récentes ; Update → sheet conforme (verbe, conséquence, nom répété, bouton rouge) ; pendant l'action : boutons grisés + « Update en cours… » au bandeau, sidebar et autres onglets actifs.
- Pendant un `hpm backup <machine>` CLI : la même action depuis l'app échoue avec un message nommant le PID CLI ; `hpm unlock <machine>` refuse tant que le backup tourne.
- Basculer en fr/zh-Hans : boutons, sheets et toasts traduits, actions/horodatages mono inchangés.

## Auto Run Result

**Passe de review de suivi nº 2 (2026-08-23).** Story déjà implémentée et revue deux fois ; cette passe (déclenchée par `followup_review_recommended: true`) a audité le diff complet depuis `43d226d` via quatre reviewers parallèles (blind hunter, edge-case hunter, verification-gap, intent-alignment) et appliqué 8 correctifs.

**Résumé du changement de cette passe :** distinction honnête échec/constat dans l'app (un doctor réussi aux checks ✗ ne s'annonce plus « Last action failed »), durcissement du verrou (libération scopée par horodatage d'acquisition contre l'auto-reprise même-PID ; `releasedCorrupt` rapporte la clôture d'orphelin), toast non bloquant pour la souris, pluriels corrects du catalogue, TTL du warning dérivé de la constante, deux commentaires de contrainte.

**Fichiers modifiés :**
- `Sources/HomePortKit/HistoryStore.swift` — `releasedCorrupt(orphanClosed:)` ; `releaseLock(machine:pid:acquiredAt:)` scopable par acquisition.
- `Sources/HomePortKit/Manager+Journal.swift` — le seam horodate son acquisition et libère scopé ; warning TTL dérivé de `lockTTL`.
- `Sources/hpm/Commands.swift` — `UnlockCmd` affiche la clôture d'orphelin aussi pour un verrou corrompu.
- `Tests/HomePortKitTests/LockTests.swift` — test corrupt renforcé (`orphanClosed: true`) ; nouveau `testScopedReleaseDoesNotFreeASamePidReacquiredLock`.
- `App/Sources/FleetModel.swift` — `LastReport` (`kind` failure/finding) remplace la String nue de `lastError`.
- `App/Sources/MachineDetailView.swift` — titre, couleur et bordure du foyer persistant selon `kind`.
- `App/Sources/MenuContent.swift` — icône/couleur menubar selon `kind`.
- `App/Sources/ControlCenterWindow.swift` — `.allowsHitTesting(false)` sur le toast ; commentaire reduced-motion corrigé.
- `App/Sources/DesignComponents.swift` — contrainte « pas de `.defaultAction` » actée en commentaire.
- `App/Sources/Localizable.xcstrings` — variations plurielles doctor/config ; clé « Last action reported problems » (en/fr/zh-Hans).

**Répartition des findings (cette passe) :** 8 patch appliqués (1 medium, 7 low), 0 deferred (les gaps de vérification app/CLI relevés par verification-gap et intent-alignment sont déjà consignés — DW-7/DW-8 du ledger, entrées `deferred` de ce spec), 16 rejetés (dont : E1 « Task hors MainActor » — faux, `FleetModel` est `@MainActor` ; zombie vivant et SQLITE_BUSY-dégrade — arbitrages conformes au contrat ; modification de `sprint-status.yaml` — bookkeeping de l'orchestrateur, hors périmètre).

**Recommandation de re-review :** patched = 0 high, 1 medium, 7 low → score 3×1 + 1×7 = 10 ≥ 5 → `followup_review_recommended: true`.

**Vérification :** `swift build` OK ; `swift test` : 168 tests, 0 échec (dont le nouveau test de libération scopée) ; `xcodegen generate` + `xcodebuild … Debug build CODE_SIGNING_ALLOWED=NO` : `BUILD SUCCEEDED` (warning Swift 6 pré-existant à `FleetModel.swift:189`, hors périmètre de cette passe).

**Risques résiduels :** la logique UI app et les peaux CLI restent sans vérification exécutable (DW-7/DW-8, assumé) ; le score de re-review reste ≥ 5 mécaniquement tant que des passes trouvent ≥ 5 low — les findings restants sont d'ampleur décroissante (cette passe : 1 medium contre 2 à la précédente).

