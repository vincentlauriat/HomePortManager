---
title: '2.2b — Notifications critiques et politique de repli'
type: 'feature'
created: '2026-08-28'
status: 'done'
baseline_revision: 'bd1bedf8c4fb61f424fd1cc335f8977e27980729'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/docs/build/epic-2-context.md'
  - '{project-root}/docs/api/homeport-api-v1.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Le sondage de fond des notifications, le gating single-policy et la navigation
      clic-notification (App/Sources) n'ont aucune vérification exécutable via swift test.
    evidence: |-
      App/Sources n'est pas dans le graphe SwiftPM (Package.swift ne déclare que
      HomePortKit, hpm et HomePortKitTests) ; voir DW-21 dans docs/build/deferred-work.md
      pour le détail complet (même parapluie que DW-17). La logique décidable (avance du
      marqueur, sévérité, disponibilité sticky) est extraite en fonctions pures dans
      HomePortKit et couverte par ManagerNotificationsTests ; ce qui reste ici est
      l'orchestration temps réel (timer, délégué UNUserNotificationCenterDelegate, bus
      ControlCenterCommands).
    location: >-
      App/Sources/FleetModel.swift, App/Sources/Notifier.swift,
      App/Sources/ControlCenterWindow.swift, App/Sources/MachineDetailView.swift
    severity: medium
  - summary: >-
      Perte silencieuse sur l'axe volume : la fenêtre est trimée aux `limit` (200)
      événements les plus récents, mais le marqueur avance quand même à `latestID`.
    evidence: |-
      `HomeportEventsReader.pull` fait `Array(events.suffix(limit))` (code de 2.2a,
      `Manager+Events.swift`, inchangé par cette story) : la tête est jetée. Si plus de
      200 événements s'accumulent entre deux sondages de 45 s, les `critical` de la
      tranche jetée ne notifient jamais, et `newMarker` passe au-delà d'eux — ils ne
      seront plus jamais réexaminés, sans aucune trace. Trouvé indépendamment par
      intent-alignment, blind-hunter, edge-case-hunter et verification-gap. Cette story
      ferme la perte silencieuse sur l'axe *epoch* ; celle-ci reste ouverte sur l'axe
      *volume*. Fermer proprement demande une lecture non trimée (que l'API du reader
      n'exprime pas) ou un signal de troncature dans `EventWindow` — une décision de
      conception, pas un correctif.
    location: >-
      Sources/HomePortKit/Manager+Events.swift (suffix(limit)),
      Sources/HomePortKit/Manager+Notifications.swift (notifiableCriticalEvents)
    severity: medium
  - summary: >-
      Le sondage de fond repagine tout l'epoch depuis 0, par machine, toutes les 45 s,
      sans backoff, gigue, ni cache négatif.
    evidence: |-
      `mode: .window` part toujours de 0 et pagine jusqu'à `has_more == false`
      (`Manager+Events.swift`), plus un appel `capabilities(of:)` par tour et par machine,
      dès le lancement de l'app et indéfiniment — y compris pour une machine qui répond
      `.unavailable` en permanence. Les N machines sont sondées en rafale au même instant,
      en phase avec le sondage propre de `EventsTabView` quand l'onglet est ouvert (deux
      lectures complètes de la même machine dans la même fenêtre de 45 s). Ce coût est
      la conséquence directe d'une contrainte de l'intent (`.window`,
      `advancingCursor: false`, jamais `event_cursors` — AD-6) : le réduire suppose de
      rouvrir cet arbitrage, pas de corriger le code.
    location: >-
      App/Sources/FleetModel.swift (pollEventsForNotifications)
    severity: medium
  - summary: >-
      Le corps de la notification passe par `String(localized:)` mais n'est pas
      réellement localisable.
    evidence: |-
      La clé est `"%@ — %@ — %@"` : trois substitutions, aucun mot traduisible, valeur
      identique en `en`, `fr` et `zh-Hans`. Elle est aussi générique au point que toute
      future chaîne à trois substitutions entrerait en collision avec elle sans qu'aucun
      outil ne le signale, et le repli `event.detail ?? "—"` code en dur un tiret cadratin
      hors localisation. La contrainte *procédurale* de l'intent (« passent par
      `String(localized:)` ») est respectée, et le titre porte bien de vrais mots traduits ;
      la lecture *substantielle* d'UX-DR9 (« localisée ») ne l'est pas. L'intent ne
      tranche pas entre les deux — arbitrage UX, pas défaut de code.
    location: >-
      App/Sources/Notifier.swift (notifyCriticalEvent), App/Sources/Localizable.xcstrings
    severity: low
  - summary: >-
      Un dépôt de notification refusé est compté comme délivré : le marqueur avance
      quand même.
    evidence: |-
      `Notifier.notify` appelle `UNUserNotificationCenter.add(request)` sans handler de
      complétion, donc une erreur de dépôt est jetée ; `pollEvents` écrit ensuite
      `setNotifiedMarker` inconditionnellement, si bien qu'un `critical` jamais affiché ne
      repassera plus. Le statut d'autorisation n'est consulté nulle part non plus
      (`requestAuthorization { _, _ in }`, préexistant 1.x) : un utilisateur ayant refusé
      les notifications voit le sondage avancer les marqueurs dans le vide. Corriger
      suppose de décider ce qu'on fait d'un dépôt échoué (réessayer, ne pas avancer,
      dégrader) — une décision, pas un correctif mécanique.
    location: >-
      App/Sources/Notifier.swift (notify, requestPermission), App/Sources/FleetModel.swift (pollEvents)
    severity: low
---

<intent-contract>

## Intent

**Problem:** L'onglet Événements (2.2a) affiche les événements mais ne notifie jamais rien, et
les transitions SSH historiques (`transitions(old:new:)` → `Notifier.notify`) tournent encore
pour toutes les machines même celles qui exposent déjà l'API — deux politiques de notification
actives à la fois sur une même machine, ce que l'epic interdit.

**Approach:** Un second marqueur `notified_up_to` (par machine, dans hpm.db, distinct du curseur
de lecture) plus un sondage de fond (indépendant de l'onglet, non lié au curseur de lecture)
décident quels événements `critical` notifient et avancent le marqueur. Une machine dont l'API
événements n'est pas servie retombe sur les transitions SSH existantes ; jamais les deux.

## Boundaries & Constraints

**Always:**
- `notified_up_to` vit dans hpm.db (table dédiée, migration `version < 3`, même style que
  `event_cursors`), décision portée par HomePortKit, jamais un frontend.
- Le sondage de notification lit en `mode: .window, advancingCursor: false` — jamais le curseur
  de lecture de l'onglet (AD-6, indépendance totale entre les deux marqueurs). Cadence 45 s
  (`EventsTabView.pollInterval`), tourne dès le lancement de l'app, pas seulement onglet ouvert.
- Seul `.critical` notifie. `id > notified_up_to` déclenche ; le marqueur avance ensuite au plus
  grand `id` vu, notifié ou non.
- Titre et corps de la notification passent par `String(localized:)` (UX-DR9 « localisée » ;
  gabarit `FleetModel.swift:408,417`), jamais du texte machine brut en titre.
- Marqueur absent (premier pull, ou machine qui vient de gagner `events`) → initialisation
  silencieuse au plus grand `id` reçu, aucune notification rétroactive.
- Une machine relève d'une politique à la fois : `events` disponible (au moins une fois observé
  via `.window`) → politique événements, transitions SSH taisantes pour elle ; sinon → transitions
  SSH (comportement actuel, inchangé).
- Disponibilité "sticky" : ne bascule sur événements qu'après un `.window` réussi, n'en ressort
  que sur un `.unavailable` explicite — un `.unreachable`/`.cancelled` transitoire ne fait pas
  flapper la politique.
- Clic sur la notification → Control Center s'ouvre/s'avance sur la fiche de la machine, onglet
  Événements (réutilise `ControlCenterWindow.open`, le bus `ControlCenterCommands`).
- `hpm machine remove` efface `notified_up_to` comme il efface déjà le curseur.

**Never:**
- Toucher au curseur de lecture (`event_cursors`) depuis le chemin de notification.
- Étendre le contrat v1 ou changer `hpm events` (reste `advancingCursor: false` — hors périmètre,
  DW-18 n'est pas rouvert : le découplage des deux marqueurs suffit à rendre l'AC vraie sans y
  toucher).
- Notifier une sévérité non-critique, ou notifier deux fois la même machine pour deux politiques.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Critical au-delà du marqueur | `id > notified_up_to` | notification macOS, marqueur avancé | — |
| Premier pull, marqueur absent | page contient déjà du `critical` | marqueur initialisé au plus grand `id`, silence | jamais rétroactif |
| API événements indisponible | 404 / hors plage / `events` absent | repli transitions SSH pour cette machine | jamais les deux politiques |
| Injoignable transitoire | erreur réseau/5xx sur le sondage | aucune notification ce tour, politique inchangée (sticky) | pas de flap vers SSH |
| Non-critique au-delà du marqueur | `info`/`warning`, `id > notified_up_to` | marqueur avance, aucune notification | — |
| Clic sur la notification | notification affichée | Control Center avant-plan, machine + onglet Événements sélectionnés | — |

</intent-contract>

## Code Map

- `Sources/HomePortKit/HistoryStore.swift:552-567` (`migrateToV2`, gabarit table + migration),
  `:472-515` (`eventCursor`/`setEventCursor`/`clearEventCursor`) -- gabarit direct pour le marqueur
  de notification, migration `version < 4` (v3 a existé le temps d'une tentative précédente de
  cette story, jamais publiée -- v4 porte directement la forme finale, il n'y a pas de base réelle
  à faire migrer depuis v3). Le marqueur stocke désormais `(epoch: String, notifiedUpTo: Int64)`,
  même forme que `EventCursor` (`Manager+Events.swift:13-21`) -- un type `NotifiedMarker` miroir,
  pas un tuple anonyme, pour la même raison que `EventCursor` existe déjà comme type nommé.
- `Sources/HomePortKit/Manager+Events.swift:83-134` (`HomeportEventsReader.read`, mode `.window`),
  `48-56` (`EventsRead`) -- réutiliser tel quel pour le sondage de fond (`advancingCursor: false`,
  même chemin que `EventsCmd`).
- `Sources/HomePortKit/Manager+Events.swift:59-71` (`EventWindow.epoch`) -- **la détection de reset
  du marqueur de notification se fait désormais contre `window.epoch`, jamais contre
  `EventWindow.cursorWasReset`.** `cursorWasReset` (`:181-197`) ne s'évalue que si le curseur de
  lecture de l'onglet (`event_cursors`) a déjà une ligne pour la machine -- c'est l'onglet, seul
  rédacteur de cette table, qui la crée à sa première ouverture. Une machine dont l'onglet n'a
  jamais été ouvert n'a donc jamais de ligne `event_cursors`, `cursorWasReset` y reste `false` pour
  toujours, et un restore/reflash qui la touche fait échouer silencieusement `id > notified_up_to`
  pour tout `critical` de la nouvelle génération -- trouvé à la 2ᵉ passe de revue de cette story
  (bad_spec, high), même violation de « Aucune perte silencieuse » que celle fermée par
  l'amendement de la 1ʳᵉ passe, rouverte par un chemin différent. `window.epoch` n'a pas ce
  problème : le contrat v1 le sert dans chaque `EventWindow`, `stored` ou non (§5), donc la
  comparaison `window.epoch != storedMarker.epoch` est autoportante -- elle ne dépend d'aucune
  autre table. Conséquence directe : le sondage de fond n'a plus besoin de lire `event_cursors` du
  tout pour sa propre décision ; `HomeportEventsReader.init(cursors:)` reçoit `cursors: nil` (comme
  `EventsCmd`, `Sources/hpm/Commands.swift:391-421`), ce qui referme aussi la dépendance que la 1ʳᵉ
  passe avait introduite entre le sondage de fond et le store de l'onglet.
- `Sources/hpm/Commands.swift:391-421` (`EventsCmd.run`) -- précédent exact de lecture
  `.window`/`advancingCursor: false` sans toucher au curseur.
- `Sources/HomePortKit/FleetHealth.swift:41-56` (`transitions(old:new:)`) -- lecture seule ; le
  point de gating est l'appelant (`FleetModel.refresh`), pas cette fonction.
- `App/Sources/FleetModel.swift:191-223` (`refresh()`, l.210-212 boucle `transitions`/`Notifier`),
  `:77` (`Notifier.requestPermission`), `:49-53` (`eventCursors`, gabarit pour exposer un accès
  équivalent au store du marqueur) -- ajouter le timer de sondage (gabarit : timer SSH l.95-97) et
  le `@Published var eventsAvailable: [String: Bool]` gating la boucle l.210.
- `App/Sources/EventsTabView.swift:168-188` (`pollInterval` = 45 s, boucle `.task`) -- même
  constante, à partager plutôt qu'à dupliquer.
- `App/Sources/Notifier.swift` -- ajouter `UNUserNotificationCenterDelegate` (identifiant de
  requête portant le nom de machine en `userInfo`) pour le clic ; aucun précédent délégué dans le
  Kit ou l'app.
- `App/Sources/ControlCenterWindow.swift:13-46` (`ControlCenterWindow.open`),
  `App/Sources/MachineDetailView.swift:105-117` (`commands.signal` → `.selectTab`, gabarit exact
  à étendre pour porter aussi le nom de machine) -- navigation clic-notification.
- `App/Sources/ControlCenterView.swift:161,204-206` (`selection` `@State`, seul `.refresh` géré
  par `onChange(commands.signal)`) -- brancher la sélection de machine sur le même bus.
- `Sources/hpm/Commands.swift:42-60` (`MachineCmd.Remove.run`, `clearEventCursor`) -- même geste
  pour `clearNotifiedUpTo`.
- `docs/build/deferred-work.md:DW-17` -- même trou de couverture (`App/Sources` hors graphe
  SwiftPM) s'étend au sondage de fond et à la navigation clic ; consigner sans dupliquer DW-17.

## Tasks & Acceptance

**Execution:**
- `Sources/HomePortKit/HistoryStore.swift` -- migration `version < 4` + `notifiedMarker`/
  `setNotifiedMarker`/`clearNotifiedUpTo` -- second marqueur, gabarit `event_cursors` **y compris
  sa garde de corruption** (`guard lastID >= 0` sur la lecture, même doctrine que `eventCursor`).
  Table `notified_markers(machine TEXT PRIMARY KEY, epoch TEXT NOT NULL, notified_up_to INTEGER NOT
  NULL, updated_at TEXT NOT NULL)` -- une colonne `epoch` de plus que la version tentée à la 1ʳᵉ
  passe, pour que la détection de reset soit portée par le marqueur lui-même (voir Code Map). Le
  type de retour est `NotifiedMarker(epoch: String, notifiedUpTo: Int64)?`, miroir d'`EventCursor`,
  pas un tuple anonyme.
- `Sources/HomePortKit/Manager+Notifications.swift` -- créer -- fonction pure
  `notifiableCriticalEvents(in: EventWindow, notifiedMarker: NotifiedMarker?) -> (toNotify: [HomeportEvent], newMarker: NotifiedMarker)`,
  testable sans réseau ni base. **Traite `notifiedMarker == nil` ou `notifiedMarker.epoch != window.epoch`
  exactement de la même façon** (ré-initialisation silencieuse au plus grand `id` vu dans `window`,
  aucune notification rétroactive) -- les deux cas sont "ce marqueur ne dit rien sur l'epoch
  courant". C'est cette comparaison d'epoch, autoportante sur le marqueur, qui remplace
  `window.cursorWasReset` de la 1ʳᵉ passe (celui-ci restait `false` en permanence pour une machine
  dont l'onglet Événements n'a jamais été ouvert, puisqu'il dépend d'une ligne `event_cursors` que
  seul l'onglet écrit -- voir Code Map). Le nouveau marqueur (`newMarker`) porte toujours
  `window.epoch`, jamais l'ancien epoch stocké. Doc comment attaché à la déclaration de la fonction.
- `Sources/HomePortKit/Manager+Notifications.swift` -- `eventsPolicyAvailability(for: EventsRead) -> Bool?`
  -- décision pure de la disponibilité sticky (fonction déjà extraite et testée à la 2ᵉ passe de
  revue ; aucun défaut trouvé contre elle, à garder telle quelle) : `.window` → `true`,
  `.unavailable` → `false`, `.unreachable`/`.cancelled` → `nil` (pas de changement).
- `App/Sources/FleetModel.swift` -- timer de sondage 45 s par machine (`.window`,
  `advancingCursor: false`, **`cursors: nil` -- le sondage de fond n'a plus besoin du store de
  l'onglet, la détection de reset est autoportante sur le marqueur (Code Map)**), `eventsAvailable`
  sticky via `eventsPolicyAvailability`, notifie via `Notifier`, avance le marqueur via
  `notifiableCriticalEvents`, gate la boucle `transitions()`/`Notifier.notify` de `refresh()` sur
  `!eventsAvailable[name]`. La constante de cadence (45 s) vit ici ou dans un fichier neutre, pas
  dans `EventsTabView` (un type modèle ne doit pas dépendre d'un type vue pour sa propre cadence).
  Le sondage doit vérifier que la machine est toujours déclarée (`model.machines`) avant d'écrire
  `eventsAvailable[name]` -- une machine retirée de fleet.yaml pendant un sondage en vol ne doit
  pas laisser réapparaître une entrée après le nettoyage de `reloadFleet()`. **La lecture du
  marqueur stocké ne doit pas avaler silencieusement une erreur de lecture (base corrompue) via
  `try?` en la traitant comme "jamais notifié"** -- `notifiedMarker(machine:)` documente
  explicitement qu'une corruption doit surfacer comme une erreur, pas comme une absence (2ᵉ passe
  de revue, patch) ; tracer l'échec sur le canal d'avertissement existant (même geste que l'échec
  d'écriture déjà tracé) et sauter la notification de ce tour pour cette machine plutôt que de
  traiter silencieusement l'erreur comme un premier pull.
- `App/Sources/Notifier.swift` -- délégué de clic, `userInfo["machine"]` ; **titre et corps de la
  notification passent tous deux par `String(localized:)`** (pas seulement le titre). Le délégué
  doit tolérer `Notifier.model` encore nil au moment du clic (course avec `FleetModel.init` au
  lancement) sans échouer silencieusement -- au minimum une trace sur le canal d'avertissement
  existant. `Notifier.model` annoté `@MainActor` (écrit et lu uniquement depuis l'acteur principal).
  Aucun défaut trouvé contre ce fichier aux deux passes de revue -- à re-dériver à l'identique.
- `App/Sources/ControlCenterWindow.swift`, `ControlCenterView.swift`, `MachineDetailView.swift` --
  route "ouvrir machine X, onglet Événements" depuis le délégué jusqu'à la sélection + `.selectTab`.
  Si la machine visée n'existe plus dans `model.machines` au moment où la requête en attente est
  consommée, la vider plutôt que la laisser en suspens (elle ne serait sinon jamais nettoyée par
  l'`onChange` de la liste des machines, qui ne réagit qu'aux *changements* de la liste). Aucun
  défaut trouvé contre ce mécanisme (`pendingNavigation`, bus `ControlCenterCommands`) aux deux
  passes de revue -- à re-dériver à l'identique.
- `App/Sources/Localizable.xcstrings` -- ajouter les clés du titre/corps de notification (fr, en,
  zh-Hans), gabarit des clés `events.*` ajoutées en 2.2a.
- `Sources/hpm/Commands.swift` (`MachineCmd.Remove`) -- `clearNotifiedUpTo` à côté de
  `clearEventCursor` ; message d'avertissement distinct si l'un échoue sans l'autre (ne pas
  laisser un message qui ne nomme que le curseur alors que c'est le marqueur qui a échoué, ou
  l'inverse). **Le message d'avertissement de l'échec d'ouverture de hpm.db doit rester lisible
  une fois le nom de machine interpolé** -- pas de guillemet simple collé à un autre (ex. écrire
  « could not open hpm.db to clear notified/event markers for '\(name)' », jamais un gabarit qui
  produit `'\(name)''s markers` ; défaut trouvé et corrigé à la 2ᵉ passe de revue, patch).
- `Tests/HomePortKitTests/ManagerNotificationsTests.swift` -- créer -- les 3 scénarios ACs
  (init silencieuse, critical > marqueur notifie, non-critique n'notifie pas) + migration v4 +
  `notifiedMarker.epoch != window.epoch` traité comme marqueur absent (silencieux, pas de perte),
  **y compris le cas où aucun marqueur n'a jamais existé pour la machine et où l'epoch change entre
  deux sondages successifs sans qu'aucune ligne `event_cursors` n'existe jamais** (c'est exactement
  la démonstration du finding bad_spec de la 2ᵉ passe -- la garder comme régression). Ajouter aussi
  les tests de `eventsPolicyAvailability` (les 4 cas : `.window`/`.unavailable`/`.unreachable`/
  `.cancelled`) et un test couvrant `HistoryStore.notifiedMarker`/`setNotifiedMarker`/
  `clearNotifiedUpTo` directement (lecture/écriture/effacement, garde de corruption, migration
  v2→v4 sans perte du curseur d'événements).
- `Tests/HomePortKitTests` -- ajouter un test couvrant `MachineCmd.Remove` (précédent :
  `EventsCmdTests.swift`, qui exerce déjà des commandes `hpm` sous test) qui seed `notified_up_to`
  et `event_cursors` pour une machine puis vérifie que les deux sont effacés après la commande
  (patch trouvé à la 2ᵉ passe de revue : ce chemin n'avait aucun test à aucun niveau).
- `docs/build/deferred-work.md` -- consigner le sondage de fond, le gating single-policy et la
  navigation clic comme non testables (même trou que DW-17, `App/Sources` hors graphe SwiftPM).
  **Ne pas répéter l'affirmation « non testable par construction » pour la détection de reset
  elle-même** -- avec l'epoch porté par le marqueur, cette détection vit entièrement dans
  HomePortKit et est directement testée par `ManagerNotificationsTests` ; ce qui reste réellement
  non testable via `swift test` est l'orchestration temps réel autour (timer, délégué, bus).

**Acceptance Criteria:**
- Given un événement `critical` reçu et un `notified_up_to` déjà établi pour cette machine, when
  son `id` dépasse `notified_up_to`, then une notification macOS localisée part, le clic ouvre la
  fiche machine sur l'onglet Événements, et les non-critiques n'en produisent aucune.
- Given une machine sans `notified_up_to` stocké (premier pull, ou `events` qui vient d'apparaître
  dans `features`), when ce premier pull s'exécute même avec du `critical` en première page, then
  `notified_up_to` s'initialise silencieusement au plus grand `id` reçu, sans notification.
- Given une machine dont Homeport n'a pas l'API ou dont `events` est absent de `features`, when ses
  notifications sont évaluées, then elles retombent sur les transitions SSH existantes — jamais
  les deux politiques à la fois pour la même machine.

## Spec Change Log

**2026-08-28 — sondage de fond sourd aux resets d'epoch (bad_spec, high).** La revue (4 couches,
1ʳᵉ passe) a trouvé qu'en passant `cursors: nil` au lecteur du sondage de fond, `cursorWasReset`
ne peut jamais s'évaluer (il dépend d'un curseur stocké non-nil, `Manager+Events.swift:181-197`) :
un restore/reflash côté Pi fait alors échouer silencieusement la notification de tout `critical`
survenu dans la fenêtre qui suit le reset -- comparaison `id > notified_up_to` contre un marqueur
d'une génération d'événements révolue. État connu-mauvais évité : perte silencieuse de
notification `critical`, en violation de la doctrine « Aucune perte silencieuse » de l'epic. Amendé
: Code Map (passer le vrai `EventCursorStore` en lecture seule au sondage) + Tasks
(`notifiableCriticalEvents` traite `cursorWasReset == true` comme marqueur absent) + Design Notes
(justification : même doctrine que le premier pull). KEEP : l'architecture en fonctions pures
(`notifiableCriticalEvents`, `eventsPolicyAvailability`) dans HomePortKit, la migration hpm.db v3
mirroir de `event_cursors`, le bus `ControlCenterCommands`/`pendingNavigation` pour la navigation
clic, et la découverte que ce chemin de lecture ne doit jamais faire avancer `event_cursors` --
tout cela a fonctionné et doit survivre à la re-dérivation. La même passe a aussi trouvé sept
défauts mineurs (localisation incomplète du corps de notification, garde de corruption manquante
sur `notifiedUpTo`, dépendance de `FleetModel` à une constante de `EventsTabView`, commentaire de
doc orphelin, message d'avertissement trompeur si `clearNotifiedUpTo` échoue seul,
`pendingNavigation` qui peut rester en suspens pour une machine retirée, absence de garde sur
`Notifier.model` encore nil au lancement) : regroupés dans les Tasks ci-dessus pour la
re-dérivation plutôt que traités en boucle de patch séparée, puisque le code entier est de toute
façon re-dérivé par ce loopback.

**2026-08-28 — la détection de reset du marqueur de notification rouvre le même trou de perte
silencieuse par un chemin différent (bad_spec, high).** La 2ᵉ passe de revue (4 couches) a trouvé
que l'amendement de la 1ʳᵉ passe -- faire dépendre `cursorWasReset` du vrai store `event_cursors`
de l'onglet -- ne ferme le trou que pour une machine dont l'onglet Événements a déjà été ouvert au
moins une fois (seul rédacteur de cette table). Une machine jamais ouverte a `stored == nil` en
permanence pour le sondage de fond : `cursorWasReset` y reste `false` pour toujours, et un
restore/reflash côté Pi qui la touche fait à nouveau échouer silencieusement `id > notified_up_to`
pour tout `critical` de la nouvelle génération -- même violation de « Aucune perte silencieuse »
que celle fermée à la 1ʳᵉ passe, rouverte ici. Trouvé indépendamment par le reviewer
verification-gap (démonstration concrète, suite de test proposée entièrement dans HomePortKit) ;
contredit aussi l'affirmation « non testable par construction » du brouillon de DW-21 pour ce
mécanisme précis, puisque la détection de reset elle-même ne dépend d'aucun code `App/Sources`.
État connu-mauvais évité : perte silencieuse de notification `critical` après un reset d'epoch sur
une machine dont l'onglet n'a jamais été ouvert. Amendé : Code Map (le marqueur porte désormais son
propre `epoch`, comparé directement contre `window.epoch` -- plus de dépendance à `event_cursors`
ni à `cursorWasReset` pour cette décision) + Tasks (migration `notified_markers` v4 avec colonne
`epoch`, `notifiableCriticalEvents` prend un `NotifiedMarker?` et compare les epochs) + Design
Notes (justification : `EventWindow.epoch` est une propriété de la réponse serveur, servie que le
curseur de lecture existe ou non -- contrairement à `cursorWasReset`, qui dépend d'un état
accumulé par un autre composant). KEEP : l'architecture en fonctions pures dans HomePortKit
(`eventsPolicyAvailability`, et `notifiableCriticalEvents` une fois reforgée avec l'epoch) ; le
store `NotifiedMarkerStore` mirroir d'`EventCursorStore` (juste étendu d'un champ `epoch`) ; toute
la chaîne de navigation clic (`Notifier.Delegate`/`UNUserNotificationCenterDelegate`,
`ControlCenterWindow.navigate(to:)`, le bus `ControlCenterCommands.pendingNavigation` consommé aux
trois points -- window `onAppear`, sheet `onAppear`, sheet `onChange`) : aucun défaut trouvé contre
elle aux deux passes, à re-dériver à l'identique ; la politique sticky `eventsAvailable` et son
gating de `refresh()` (le "silence des deux canaux sur une machine totalement injoignable" reste un
comportement assumé et documenté, pas un défaut) ; le timer de fond 45 s partagé via
`FleetModel.eventsPollInterval` avec `EventsTabView` ; les clés de localisation ajoutées dans
`Localizable.xcstrings`. La même passe a aussi trouvé deux défauts mineurs indépendants du bad_spec
(lecture du marqueur qui avale silencieusement une erreur de corruption via `try?` au lieu de la
tracer ; message d'avertissement avec guillemet doublé dans `Commands.swift`) et un trou de
couverture (`MachineCmd.Remove` n'a de test à aucun niveau pour l'effacement des deux marqueurs) :
les trois regroupés dans les Tasks ci-dessus pour la re-dérivation, même raisonnement que la 1ʳᵉ
passe -- le code entier est de toute façon re-dérivé par ce loopback.

## Review Triage Log

### 2026-08-28 — Review pass
- intent_gap: 0
- bad_spec: 1: (high 1, medium 0, low 0)
- patch: 7: (high 0, medium 2, low 5)
- defer: 2: (high 0, medium 0, low 2)
- reject: 4: (high 0, medium 0, low 4)
- addressed_findings:
  - `high` `bad_spec` Le sondage de fond ne peut pas détecter un reset d'epoch côté Pi
    (`cursors: nil` empêche `cursorWasReset` de s'évaluer) : `critical` survenu juste après un
    restore/reflash n'est jamais notifié. Spec amendée (Code Map + Tasks + Design Notes) ; code
    reverté au baseline pour re-dérivation via step-03 avec la correction incluse.

### 2026-08-28 — Review pass (2)
- intent_gap: 0
- bad_spec: 1: (high 1, medium 0, low 0)
- patch: 3: (high 0, medium 1, low 2)
- defer: 0
- reject: 15: (high 0, medium 0, low 15)
- addressed_findings:
  - `high` `bad_spec` La détection de reset dont dépend `notifiableCriticalEvents` (amendement
    du 28/08) est portée par `event_cursors` (`EventWindow.cursorWasReset`,
    `Manager+Events.swift:181-197`), qui n'existe que si l'onglet Événements a déjà été ouvert au
    moins une fois pour la machine — c'est l'onglet, seul rédacteur de ce curseur, qui crée la
    ligne. Une machine dont l'onglet n'a jamais été ouvert a `stored == nil` en permanence pour le
    sondage de fond : `cursorWasReset` reste `false` pour toujours, et un restore/reflash côté Pi
    qui la touche fait échouer silencieusement `id > notified_up_to` pour tout `critical` de la
    nouvelle génération — exactement la perte que l'amendement du 28/08 a fermée pour le cas
    testé, rouverte ici pour le cas où aucune ligne `event_cursors` n'existe encore. Trouvé
    indépendamment par le reviewer verification-gap (avec démonstration concrète et suite de test
    proposée, entièrement dans HomePortKit) et par l'avis pris avant la re-dérivation. Contredit
    aussi l'affirmation « non testable par construction » du brouillon de DW-21 pour ce mécanisme
    précis : la détection de reset elle-même vit dans HomePortKit, dans le graphe SwiftPM testé.
    Spec amendée (Code Map + Tasks + Design Notes) ; code reverté au baseline pour re-dérivation
    via step-03 avec la correction incluse.

### 2026-08-29 — Review pass (3)

Première passe de revue exercée contre le code réellement livré : les passes 1 et 2 ont
toutes deux fini par un revert au baseline, et la re-dérivation (`a729881827eb60bab3cda9d6e1dace35672f585c`)
a été committée à la main après un timeout de session, avec `status: done` posé sans revue.

- intent_gap: 0
- bad_spec: 0
- patch: 7: (high 0, medium 5, low 2)
- defer: 4: (high 0, medium 2, low 2)
- reject: 14: (high 0, medium 0, low 14)
- addressed_findings:
  - `medium` `patch` `reloadFleet()` élaguait `statuses`/`lastReachableStatus`/`lastSeenAt`/
    `lastError` mais pas `eventsAvailable`, alors que son propre commentaire affirme « everything
    keyed by machine name is dropped » et que la garde de `pollEvents` s'appuie explicitement
    dessus. Une machine retirée de fleet.yaml puis ré-ajoutée héritait de la politique événements
    d'une vie antérieure — transitions SSH muettes jusqu'au prochain sondage concluant, et
    définitivement si elle est injoignable (`.unreachable` ne change rien, sticky). Élagage ajouté.
    Trouvé indépendamment par les trois couches de revue de code.
  - `medium` `patch` `notifiedMarkers == nil` (hpm.db inouvrable) produisait un silence *total* :
    la lecture optionnelle rendait `nil` sans lever, la décision se lisait comme un premier pull,
    l'écriture était un no-op — donc aucune notification événements ne partait jamais, pendant que
    `eventsAvailable` passait quand même à `true` et taisait les transitions SSH. Le sondage sort
    désormais du tour avant toute écriture de politique, avec une trace unique, laissant les
    machines sur le repli SSH.
  - `medium` `patch` Une lecture double-stale (`Manager+Events.swift` : l'epoch bascule pendant
    deux pulls complets consécutifs) rend une génération jamais lue sous la forme d'un historique
    vide à `latestID` 0. Le marqueur s'initialisait donc à 0, et le sondage suivant notifiait
    rétroactivement tout le `critical` de la nouvelle génération — ce que « jamais rétroactif »
    interdit explicitement. Garde ajoutée dans `pollEvents` (avec `cursors: nil`, `cursorWasReset`
    ne peut venir que de ce chemin, c'est donc un signal exact ici).
  - `medium` `patch` `migrateToV4` faisait `CREATE TABLE IF NOT EXISTS` : une base laissée en v3
    par la tentative non publiée porte un `notified_markers` sans colonne `epoch`, que le
    `IF NOT EXISTS` conservait tel quel avant d'estampiller `user_version = 4` dessus — après quoi
    chaque lecture de marqueur lève et les notifications sont mortes pour de bon. `DROP TABLE IF
    EXISTS` ajouté (cette étape ne tourne que sur une base sous v4, et aucune version publiée n'a
    jamais écrit une ligne ici) + test partant d'une vraie base v3.
  - `medium` `patch` La règle d'avance du marqueur — `window.latestID` plutôt que le plus grand id
    servi, et la garde `max(...)` contre une régression intra-epoch — était inversable en laissant
    la suite entièrement verte (démontré par mutation par le reviewer verification-gap : toutes les
    fixtures faisaient coïncider les deux valeurs). Trois tests discriminants ajoutés, eux-mêmes
    validés par mutation : la même inversion les fait rougir tous les trois.
  - `low` `patch` `setNotifiedMarker` était écrit à chaque tour même quand la décision n'avait rien
    changé — une écriture SQLite par machine toutes les 45 s pour ne rafraîchir qu'`updated_at`.
    Garde `decision.newMarker != stored` ajoutée.
  - `low` `patch` La raison d'être annoncée de `MachineCmd.Remove.clearMarkers` (« l'un qui échoue
    ne masque pas l'autre », et chaque avertissement nomme le bon marqueur) n'était vérifiée par
    aucun test : les deux cas couverts étaient nominaux et la closure `report` n'était jamais
    exercée. Test du chemin d'échec asymétrique ajouté.

## Design Notes

**Pourquoi le sondage de fond ignore le curseur de lecture.** `event_cursors` reste la propriété
exclusive de l'onglet (2.2a) : le faire lire ou avancer par un second chemin réintroduit la course
que 2.2a a explicitement évitée entre l'onglet et le CLI. En lisant toujours la fenêtre complète
(`.window`, `advancingCursor: false` — le chemin déjà exercé par `hpm events`) et en décidant
uniquement contre `notified_up_to`, le sondage de notification devient indépendant de qui lit ou
avance le curseur — CLI compris. C'est ce qui rend vraie, sans y toucher, la phrase de l'epic
« `hpm events` peut avancer la lecture sans jamais faire perdre une notification » : DW-18 reste
ouvert par choix, pas par oubli, la garantie ne dépend plus de son issue.

**Pourquoi la disponibilité événements est sticky.** Une machine qui bascule vers la politique
événements ne doit pas y perdre parce qu'un sondage rate une fois (réseau). Ne redescendre que sur
un `.unavailable` explicite (version incompatible ou `events` retiré de `features` — un
changement de configuration, pas un accident réseau) évite un flap qui ferait tantôt les deux
politiques taisantes, tantôt les deux actives sur le même tour.

**Conséquence assumée : une machine totalement injoignable (HTTP et SSH) ne notifie plus rien.**
Sur la politique événements, un sondage HTTP en échec laisse `eventsAvailable` inchangé (sticky) et
la boucle SSH reste taisante (gating) — donc silence des deux côtés le temps que l'un des deux
canaux réponde à nouveau. C'est l'effet voulu du single-policy (jamais les deux politiques actives
à la fois), pas un oubli, mais c'est un changement réel de comportement par rapport à avant 2.2b où
`transitions()` seule notifiait déjà une machine devenue injoignable en SSH. Non testable
(DW-21) ; à surveiller si une coupure réseau complète d'une machine s'avère silencieuse en usage
réel.

**Pourquoi un reset se traite comme un marqueur absent, pas comme une comparaison contre l'ancien.**
Un restore/reflash côté Pi change d'epoch et fait repartir les `id` à zéro (2.2a, §5) : sans détection,
`id > notified_up_to` compare une nouvelle génération de petits `id` contre un marqueur qui appartient
à l'ancienne, et échoue toujours -- y compris pour du `critical` réel survenu juste après le reset,
en violation directe de « Aucune perte silencieuse » (contexte d'epic). La doctrine du premier pull
(« aucune notification rétroactive sur un historique déjà peuplé ») s'applique mot pour mot à ce
cas : un reset produit, du point de vue de ce marqueur, un historique tout aussi neuf qu'un premier
pull. Ré-initialiser silencieusement plutôt que de tenter de rattraper rétroactivement les
événements de la fenêtre de transition est donc la même règle, pas une nouvelle.

**Pourquoi la détection de reset porte son propre epoch plutôt que d'emprunter celui de l'onglet
(2ᵉ passe de revue).** La 1ʳᵉ passe a fermé la perte silencieuse pour le cas où `event_cursors` a
déjà une ligne pour la machine, en passant le vrai store de l'onglet au lecteur du sondage de fond
pour que `cursorWasReset` s'évalue. Mais cette ligne n'existe que si l'onglet Événements a déjà été
ouvert au moins une fois -- c'est l'onglet, seul rédacteur de `event_cursors`, qui la crée. Une
machine dont personne n'a jamais ouvert l'onglet a donc `stored == nil` en permanence pour ce
sondage, `cursorWasReset` y reste `false` pour toujours, et le même trou de perte silencieuse
rouvre par un chemin différent -- trouvé indépendamment par le reviewer verification-gap à la 2ᵉ
passe, avec démonstration concrète. `EventWindow.epoch` n'a pas ce défaut : le contrat v1 le sert
dans chaque fenêtre lue, `stored` ou non (§5) -- c'est une propriété de la réponse serveur, pas
d'un état côté client accumulé par un autre composant. Stocker cet epoch à côté de `notified_up_to`
rend la détection de reset entièrement autoportante sur le marqueur lui-même : elle ne dépend plus
de si, quand, ou par qui `event_cursors` a été peuplé. Bénéfice de bord : le sondage de fond n'a
plus besoin de lire `event_cursors` du tout (`cursors: nil`), ce qui referme aussi la dépendance
que la 1ʳᵉ passe avait introduite entre les deux marqueurs -- AD-6 (indépendance totale) devient
une garantie structurelle plutôt qu'une discipline de lecture-seule à respecter.

## Verification

**Commands:**
- `swift build` -- expected: compile sans avertissement.
- `swift test --filter ManagerNotificationsTests` -- expected: les 3 scénarios ACs passent.
- `swift test` -- expected: aucune régression sur la suite existante.
- `bash Scripts/verify-app-build.sh` -- expected: rc 0.

**Manual checks (if no CLI):**
- Sur `raspcorse`/`raspyellow` (API événements servie) : provoquer un événement `critical` côté
  Homeport, vérifier la notification macOS et que le clic ouvre la fiche machine sur Événements.
- Sur une machine sans API événements : vérifier que les transitions SSH notifient toujours
  (repli), et qu'aucune notification événements ne part pour elle.

## Auto Run Result

Status: done
Blocking condition: aucune

### Changement implémenté

Story 2.2b : notifications des événements `critical` et politique de repli unique. Un second
marqueur `(epoch, notified_up_to)` par machine dans hpm.db (migration v4), distinct du curseur de
lecture de l'onglet (AD-6), plus un sondage de fond à 45 s indépendant de l'onglet, décident quels
`critical` notifient. Une machine dont l'API événements répond relève de la politique événements et
voit ses transitions SSH taisantes ; sinon elle garde le comportement actuel — jamais les deux.

Cette passe est la **première revue exercée contre le code réellement livré** : les passes 1 et 2
ont toutes deux fini par un `bad_spec` et un revert au baseline, et la re-dérivation
(`a729881827eb60bab3cda9d6e1dace35672f585c`) a été committée à la main après un timeout de session,
avec `status: done` posé sans revue. Le `done` d'origine était de la comptabilité de sauvetage, pas
une preuve de vérification.

### Fichiers modifiés depuis `bd1bedf8c4fb61f424fd1cc335f8977e27980729`

- `Sources/HomePortKit/Manager+Notifications.swift` — créé : `NotifiedMarker`,
  `NotifiedMarkerStore`, `notifiableCriticalEvents` et `eventsPolicyAvailability`, toutes pures.
- `Sources/HomePortKit/HistoryStore.swift` — marqueur `notified_markers` + migration v4 (avec
  `DROP TABLE IF EXISTS`, ajouté par cette passe).
- `App/Sources/FleetModel.swift` — sondage de fond 45 s, drapeau sticky `eventsAvailable`, gating
  des transitions SSH ; élagage de `eventsAvailable`, garde hpm.db absent, garde double-stale et
  garde d'écriture no-op ajoutés par cette passe.
- `App/Sources/Notifier.swift` — notification de `critical` localisée + délégué de clic.
- `App/Sources/ControlCenterWindow.swift`, `MachineDetailView.swift`, `EventsTabView.swift` —
  navigation « ouvrir machine X, onglet Événements » et cadence partagée.
- `App/Sources/Localizable.xcstrings` — clés titre/corps (fr, en, zh-Hans).
- `Sources/hpm/Commands.swift` — `hpm machine remove` efface les deux marqueurs.
- `Tests/HomePortKitTests/` — `ManagerNotificationsTests.swift` (créé), `MachineCmdRemoveTests.swift`
  (créé), `HistoryStoreTests.swift` et `LockTests.swift` (schéma v4).
- `docs/build/deferred-work.md` — DW-21.

### Revue

7 patches appliqués (medium 5, low 2), 4 éléments différés (medium 2, low 2), 14 rejetés,
0 `intent_gap`, 0 `bad_spec`. Détail dans le Review Triage Log ci-dessus ; les différés sont dans
le frontmatter `deferred`.

Recommandation de revue de suivi : **true** — aucun patch `high`, mais 3 × 5 medium + 1 × 2 low =
17, au-delà du seuil de 5.

### Vérification effectuée

- `swift build` — succès, sans avertissement.
- `swift test` — **316/316**, 0 échec (311 avant cette passe, +5 tests).
- `swift test --filter ManagerNotificationsTests` — 15/15, les 3 ACs comprises.
- `bash Scripts/verify-app-build.sh` — **rc 0** (le script ne produit de sortie qu'en échec ;
  vérifié en le lisant avant de croire son silence).
- Contrôle par mutation des trois tests ajoutés sur la règle d'avance du marqueur : la mutation que
  verification-gap avait démontrée verte les fait maintenant rougir tous les trois. Source
  restaurée et vérifiée (`git diff` vide sur le fichier).
- Manuel non exécuté : les vérifications sur `raspcorse`/`raspyellow` demandent du matériel réel et
  un clic — DW-21, même parapluie que DW-17 pour tout `App/Sources`.

### Risques résiduels

- Perte silencieuse sur l'axe volume (plus de 200 événements entre deux sondages) — différé,
  medium : cette story ferme l'axe epoch, pas celui-là.
- Coût du sondage : repagination complète de l'epoch par machine toutes les 45 s, sans backoff ni
  gigue — différé, medium ; conséquence directe d'une contrainte de l'intent (AD-6).
- Conséquence assumée et documentée dans les Design Notes : une machine injoignable en HTTP *et* en
  SSH ne notifie plus rien, le temps qu'un des deux canaux réponde.
- Toute l'orchestration temps réel d'`App/Sources` (timer, délégué, bus de navigation) reste hors
  du graphe SwiftPM et n'est couverte par aucun test exécutable — DW-21.
