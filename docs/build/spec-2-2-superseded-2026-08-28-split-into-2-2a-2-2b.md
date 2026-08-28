---
title: '2.2 — Notifications critiques et dégradation sans API (SUPERSEDED)'
type: 'feature'
created: '2026-08-28'
status: 'superseded'
baseline_commit: '3ed0e0c8c7d0485d3720ea5e45923dace7407d08'
review_loop_iteration: 1
followup_review_recommended: false
context:
  - '{project-root}/docs/build/epic-2-context.md'
  - '{project-root}/docs/api/homeport-api-v1.md'
warnings: []
deferred: []
---

> **SUPERSEDED (28/08).** Story 2.2 a été scindée en **2.2a** (flux d'événements + onglet, voir
> `docs/specs/epics.md`) et **2.2b** (notifications + dégradation, dépend de 2.2a) après que ce
> périmètre unifié a épuisé `session_timeout_min` (90 min) et `max_tokens_per_story` (2M) sous
> `bmad-loop`, sans rien committer. Ce document n'est plus la spec active — gardé pour son Code Map,
> son I/O Matrix et son Review Triage Log (2 bugs `bad_spec` déjà trouvés : notification rétroactive
> sur le premier pull, pagination `has_more` non suivie), à réutiliser en écrivant les specs de
> 2.2a/2.2b plutôt qu'à redécouvrir.

<intent-contract>

## Intent

**Problem:** L'onglet Événements affiche encore le message générique de la story 2.1 ("arrive avec
2.1", obsolète depuis que 2.1 est `done`), et aucun mécanisme ne notifie un événement `critical` ni
ne distingue une machine dont Homeport ne sert pas encore l'API (l'état réel de toute la flotte
aujourd'hui) d'une machine réellement injoignable.

**Approach:** Écrire `HomeportAPIClient` (capabilities + events, décodage conforme au contrat v1
§4/§6/§8) et la décision de notification dans HomePortKit, avec deux marqueurs distincts en base
(curseur de lecture, `notified_up_to`) ; gater les transitions menubar existantes par machine selon
que `events` figure dans `features` ; remplacer le placeholder de l'onglet par les trois états du
contrat (disponible / non disponible / injoignable).

## Boundaries & Constraints

**Always:**
- La décision de notifier (franchissement de `notified_up_to`) vit dans HomePortKit, jamais dans
  `App/Sources` (AD-5).
- Curseur de lecture et `notified_up_to` sont deux marqueurs distincts en base, ajoutés par une
  migration `PRAGMA user_version` — jamais une table parallèle, jamais l'un dérivé de l'autre.
- Une machine relève d'une seule politique de notification à la fois : `events` ∈ `features` →
  notifications sur `critical` uniquement ; sinon → fallback sur `transitions(old:new:)` existant —
  jamais les deux en même temps pour une même machine.
- Les trois états de l'onglet Événements suivent exactement le contrat §8 ; jamais présentés comme
  une erreur.
- Curseur invalidé si l'`epoch` reçu diffère du curseur OU si `latest_id` < id du curseur (§5) —
  repart du début de l'epoch courant, sans exception levée.
- Sévérité inconnue (hors `info`/`warning`/`critical`) → traitée comme `warning`, jamais invisible,
  jamais notifiante.
- `hpm events` sert le même contenu filtré que l'onglet correspondant (AD-13).

**Block If:**
- Le contrat épinglé (`docs/api/homeport-api-v1.md`) doit être révisé pour couvrir un besoin de
  cette story — interdit par AD-4 (rédacteur unique = story 2.1) ; toute lacune constatée est à
  consigner en `deferred`, jamais une extension à la volée.
- Un comportement observé côté API contredit le contrat d'une façon que la conduite documentée en
  §8 ne couvre pas — décision d'architecture, pas un détail d'implémentation.

**Never:**
- Étendre le contrat v1 (AD-4).
- Toucher au repo Homeport — l'implémentation serveur est un chantier miroir distinct.
- Introduire un stream (SSE/WebSocket) — le pull à curseur reste le mécanisme de vérité en v1.
- Persister côté Mac une copie durable d'événements — seuls un curseur et un marqueur (AD-6).
- Écrire ou modifier `sprint-status.yaml` — propriété exclusive de l'orchestrateur.
- Toucher au volet métriques du contrat — hors périmètre, réservé à la story 2.3.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| 404 sur `capabilities` | Homeport sans API v1 | État « non disponible », pill vers Updates | jamais une erreur |
| `contract` hors plage consommée | ex. `"2.0.0"` | idem, en nommant la version rencontrée | jamais une erreur |
| `events` absent de `features` | `capabilities` OK, `features: ["metrics"]` | « non disponible » sur l'onglet Events seulement | jamais une erreur |
| Erreur réseau / délai dépassé | machine injoignable | « injoignable », derniers événements connus + « Vu pour la dernière fois à HH:MM » | distinct de « non disponible » |
| `5xx` | défaillance serveur | « injoignable », retry plus tard | rien n'est invalidé |
| `epoch` changé | epoch reçu ≠ curseur | curseur réinitialisé au début du nouvel epoch | pas une erreur |
| `latest_id` < curseur, même epoch | régression d'identifiant | curseur réinitialisé, comme un changement d'epoch | pas une erreur |
| Événement `critical`, id > `notified_up_to` | notification non encore envoyée | notification macOS part, `notified_up_to` avance | N/A |
| Événement `info`/`warning` | — | aucune notification | N/A |
| Sévérité inconnue (v1.1+) | valeur hors des trois connues | traitée comme `warning`, jamais notifiante | pas une exception |
| Machine sans `events` dans `features` | fallback | notification sur `transitions()` menubar existant, jamais les deux politiques | N/A |

</intent-contract>

## Code Map

- `docs/api/homeport-api-v1.md` -- lecture seule (AD-4). §4 `capabilities`, §5 epoch/`latest_id`,
  §6 `events`, §8 « ce qu'un client conclut d'un échec » (table à reprendre telle quelle).
- `Sources/HomePortKit/HomeportAPIContract.swift` -- existant (2.1). `HomeportAPIContract.compatibility(with:)`
  distingue déjà compatible/tooOld/tooNew/preRelease/unreadable ; 2.2 s'y branche pour séparer
  « contract hors plage » d'un 404 pur.
- `Sources/HomePortKit/Dashboard.swift:16-35` -- `dashboardURL(for:)`, modèle exact de dérivation
  `http://<host>:<port>/` depuis `machine.ssh`/`machine.port` (tailnet, AD-3). Même dérivation
  host/port pour la base de `HomeportAPIClient`, path changé vers `/api/v1/...`.
- `Sources/HomePortKit/FleetHealth.swift:41-56` -- `transitions(old:new:)`, la politique de repli
  menubar existante (AC2) ; à gater par machine selon que `events` ∈ `features`.
- `App/Sources/FleetModel.swift:185-217` (`refresh()`), L.204-206 -- appelle aujourd'hui
  `transitions` + `Notifier.notify` sans condition : point d'édition du gate « une seule politique
  par machine ».
- `App/Sources/Notifier.swift` (17 lignes, complet) -- `notify(title:body:)` sans `userInfo` ni
  `categoryIdentifier`, aucun `UNUserNotificationCenterDelegate` nulle part. À étendre pour porter
  machine + tab cible, et ajouter le délégué de clic.
- `Sources/HomePortKit/HistoryStore.swift:469-493` (`migrate`) -- schéma v1 = `tasks`+`locks`
  seulement, aucun curseur/marqueur. 2.2 ajoute une migration `PRAGMA user_version = 2` pour le
  curseur `(epoch, id)` et `notified_up_to`, par machine, deux états distincts (AD-5). Style à
  reprendre : `struct Equatable, Sendable`, `now: Date = Date()` injectable, méthodes `throws`.
- `App/Sources/MachineDetailView.swift:6-46` (`MachineTab`) -- L.37 `pendingMessage` de `.events`
  obsolète (« arrives with story 2.1 ») à remplacer par les 3 états contrat ; L.262-269 switch sur
  `pendingMessage` à étendre ; L.368-384 `unreachableNotice` = gabarit direct pour « injoignable ».
- `App/Sources/DashboardTabView.swift:190-213` -- gabarit à 3 branches (unreachable / échec /
  contenu) pour le même triptyque, appliqué ici à Events.
- `App/Sources/DesignComponents.swift:578-613` -- `EmptyStateView(title:message:detail:actionTitle:action:)`,
  réutilisable tel quel pour « non disponible » (pill vers Updates) et « injoignable » (pill Retry).
- `Sources/HomePortKit/FleetRow.swift:8-12,57-65` -- seul vocabulaire de sévérité
  (`Severity.ok/warning/critical`) et seule porte d'entrée `severity(of:)` ; la sévérité Events doit
  passer par ce même vocabulaire, jamais en recréer un.
- `Sources/hpm/Commands.swift:308-345` (`TasksCmd`) -- gabarit direct pour `EventsCmd`
  (`hpm events [--machine] [--severity]`) : options facultatives de filtrage, lecture seule, erreur
  propagée si le store est illisible (AD-13).
- `App/Sources/ControlCenterWindow.swift:270-282` (`selection: .machine(name)`) et
  `MachineDetailView.swift:70` (`tab: MachineTab`, `@State` local sans entrée externe) -- le clic
  sur une notification a besoin d'un chemin de navigation neuf (sélection machine + tab Events) ;
  aucun état de ce genre n'existe encore, à câbler ici.
- `Tests/HomePortKitTests/HomeportAPIContractTests.swift`, `FleetHealthTests.swift`,
  `MachineIssueTests.swift` -- gabarits de test pour fonctions pures ; `HistoryStoreTests.swift` --
  gabarit d'intégration SQLite réelle pour les nouvelles tables curseur/marqueur.
- `docs/specs/architecture/architecture-HomePortManager-2026-08-23/ARCHITECTURE-SPINE.md:61-71,141-152` --
  lecture seule. AD-5 (curseur, deux marqueurs, décision côté Kit), AD-6 (propriétaire unique),
  table des conventions : Notifications macOS (L.147), Erreurs (L.149), Événements (L.146).
- `docs/build/epic-2-context.md:98` -- **incohérence à noter, pas à corriger** : dit « 2.1 = contrat
  + client d'événements », contredit par les boundaries figées de 2.1 (« Never : écrire
  `HomeportAPIClient`… c'est la story 2.2 ») et par `deferred-work.md`. C'est bien cette story qui
  écrit le client ; le fichier de contexte epic est daté sur ce point précis.
- `docs/build/deferred-work.md` (entrées liées à `spec-2-1-...md`) -- DW ouvert : une seule ligne du
  contrat pinné est liée à du code exécutable (la plage semver). 2.2 ferme ce trou par des tests de
  décodage sur fixtures conformes au contrat.
- `docs/api/homeport-api-v1.md:184,210,212,216` -- lecture seule (AD-4). `latest_id` = plus grand
  `id` de l'epoch, indépendant de `limit`/du filtre ; `has_more` vrai s'il reste des événements après
  la page reçue ; le client rappelle avec `since_id` = dernier `id` reçu tant que `has_more` est vrai.
  Ces trois champs sont la seule façon d'atteindre la fin d'un historique en pull ascendant-only --
  aucun paramètre « les N plus récents » n'existe côté contrat.
- `Sources/HomePortKit/FleetHealth.swift:` `transitions(old:new:)` -- `guard let old else { return [] }` :
  la première observation n'alerte jamais, elle établit seulement une base. C'est le précédent direct
  pour le premier pull d'événements (voir Tasks ci-dessous) -- même doctrine, deux implémentations.

## Tasks & Acceptance

**Execution:**
- `Sources/HomePortKit/HomeportAPIClient.swift` -- créer -- GET `capabilities`/`events`, décodage
  JSON conforme au contrat, classification 404/contract-hors-plage/features-absent/erreur
  réseau/5xx en un état `APIAvailability` (available/unavailable(reason)/unreachable) -- c'est la
  moitié « réseau » du contrat, jusqu'ici seulement écrite (§8).
- `Sources/HomePortKit/HistoryStore.swift` -- migration v2 -- curseur `(epoch, id)` et
  `notified_up_to`, par machine -- deux marqueurs distincts (AD-5), jamais dérivés l'un de l'autre.
- `Sources/HomePortKit/Manager+Events.swift` -- créer -- pull depuis le curseur stocké, règle
  d'invalidation (epoch changé OU `latest_id` < curseur), décision de notifier (`critical` non lu
  depuis `notified_up_to`) -- pure, testable sans réseau via un client injecté.
  - **Premier pull (aucun marqueur stocké pour cette machine) : `notified_up_to` s'initialise au plus
    grand `id` reçu dans la page (0 si la page est vide), jamais à 0 face à un historique déjà
    peuplé.** `toNotify` est systématiquement vide sur ce premier pull, quelle que soit la sévérité
    des événements déjà présents -- symétrique à `transitions(old: nil) -> []` (Code Map). Un test
    dédié doit couvrir : première page contenant déjà un `critical` -> `toNotify == []` et
    `notifiedUpTo == id du critical`, pas de notification rétroactive.
  - `fetchEventsForDisplay` (affichage Events tab + `hpm events`, AD-13) doit refléter les événements
    les plus récents, pas rester bloqué sur les plus anciens d'un epoch qui a dépassé `limit`. Tant
    que `has_more` est vrai, poursuivre la pagination (`since_id` = dernier `id` reçu) jusqu'à
    `has_more == false`, puis ne retenir que la fenêtre la plus récente (taille `limit`) avant de
    retourner le résultat -- accumulation en mémoire pour la durée de l'appel uniquement, jamais une
    copie durable (AD-6 reste respecté : rien n'est écrit en base). Un test dédié doit couvrir : plus
    d'événements que `limit` dans l'epoch -> le résultat retourné correspond à la fenêtre la plus
    récente, pas à `since_id=0` tronqué.
- `Sources/HomePortKit/FleetHealth.swift` -- gater `transitions(old:new:)` (ou son point d'appel)
  par la présence de `events` dans `features` de la machine -- une seule politique par machine (AC2).
- `App/Sources/FleetModel.swift` -- brancher le pull d'événements dans `refresh()`, remplacer
  l'appel inconditionnel (L.204-206) par le gate ci-dessus.
- `App/Sources/Notifier.swift` -- porter `userInfo` (nom machine) sur la notification `critical`,
  ajouter le `UNUserNotificationCenterDelegate` qui route le clic vers la fiche machine / onglet
  Événements.
- `App/Sources/MachineDetailView.swift` -- remplacer le `pendingMessage` obsolète de `.events` par
  les 3 états du contrat, en réutilisant `EmptyStateView` et `unreachableNotice` comme gabarits.
- `App/Sources/ControlCenterWindow.swift` / la vue qui porte `selection` -- câbler la navigation
  programmatique déclenchée par le clic sur une notification (sélection machine + tab Events).
- `Sources/hpm/Commands.swift` -- ajouter `EventsCmd` (`hpm events [--machine] [--severity]`),
  gabarit `TasksCmd`.
- `Tests/HomePortKitTests/HomeportAPIClientTests.swift` -- créer -- décodage de fixtures conformes
  au contrat pour chaque ligne de §8 -- ferme le DW « une seule ligne du contrat liée à du code ».
- `Tests/HomePortKitTests/ManagerEventsTests.swift` -- créer -- couvrir la table I/O ci-dessus
  (invalidation curseur, décision de notifier, sévérité inconnue → `warning`).
- `docs/build/deferred-work.md` -- consigner le câblage UI non testé (clic notification →
  navigation ; `App/Sources` sans cible de test) sous l'ombrelle DW-7/DW-8 existante.

**Acceptance Criteria:**
- Given un événement `critical` reçu et non encore notifié (`id` > `notified_up_to`), when le pull
  d'événements s'exécute, then une notification macOS localisée part, le clic ouvre la fiche
  machine sur l'onglet Événements, et `hpm events` peut avancer la lecture sans jamais faire perdre
  cette notification (curseur et `notified_up_to` restent deux marqueurs distincts, AD-5).
- Given une machine dont `capabilities` répond 404 ou une version hors plage, when l'onglet
  Événements s'ouvre, then l'empty-state « non disponible » s'affiche avec une pill vers Updates,
  jamais une erreur, et les notifications de cette machine retombent sur les transitions menubar
  existantes (jamais les deux politiques à la fois).
- Given une machine injoignable (erreur réseau ou 5xx), when l'onglet Événements s'ouvre, then
  l'état « injoignable » (pill critical) s'affiche, distinct de « non disponible », avec les
  derniers événements connus et « Vu pour la dernière fois à HH:MM ».
- Given `hpm events --machine <nom> --severity critical`, when la commande s'exécute, then le
  contenu filtré correspond exactement à ce que l'onglet Événements montrerait pour la même machine
  et le même filtre (AD-13).

## Spec Change Log

### 2026-08-28 — Amendement bad_spec (revue, itération 1)

- **Findings déclencheurs** : (1) `decideEventsPull` notifie rétroactivement tout l'historique
  `critical` déjà présent lors du tout premier pull d'une machine (aucun marqueur stocké ->
  `notified_up_to` par défaut à `0`) ; (2) `fetchEventsForDisplay` lit toujours `since_id=0, limit=200`
  sans jamais suivre `has_more`, donc reste bloqué sur les 200 événements les plus anciens dès que
  l'historique d'un epoch dépasse `limit`.
- **Amendé** : Code Map (deux entrées ajoutées : contrat `latest_id`/`has_more`/pagination, précédent
  `transitions(old: nil)`), Tasks & Acceptance (deux sous-puces normatives sous la tâche
  `Manager+Events.swift`), Design Notes (deux nouvelles sous-sections + liste KEEP). Le contenu du
  `<intent-contract>` n'a pas été touché -- la Boundaries `Always` et l'I/O Matrix restent correctes
  à la lettre ; le manque était dans le niveau de détail d'implémentation, pas dans l'intention.
- **État connu-mauvais évité** : app qui spamme des notifications pour un historique déjà ancien dès
  qu'une machine gagne la fonctionnalité `events` ; onglet Events (et `hpm events`) figé sur de
  l'historique ancien pour toute machine dont l'epoch dépasse 200 événements, sans jamais l'indiquer.
- **KEEP instructions** : voir la liste `KEEP` dans `## Design Notes` -- design stateless de
  `fetchEventsForDisplay`, schéma v2 `HistoryStore` à deux marqueurs, `EventsPullOutcome` comme gate
  pur, `checkEventsCapability` partagé, structure de test existante.

## Review Triage Log

### 2026-08-28 — Review pass

- intent_gap: 0
- bad_spec: 2: (high 2, medium 0, low 0)
- patch: 5: (high 1, medium 3, low 1)
- defer: 6: (high 0, medium 2, low 4)
- reject: 3
- addressed_findings:
  - `high` `bad_spec` Premier pull sans marqueur stocké notifie rétroactivement tout l'historique
    `critical` déjà présent (`notified_up_to` par défaut à `0`) au lieu d'établir une base
    silencieuse comme `transitions(old: nil)` -- amendé Tasks & Design Notes pour exiger
    `notified_up_to = max(id)` de la première page reçue, jamais de notification sur ce premier pull.
  - `high` `bad_spec` L'affichage (`fetchEventsForDisplay`, onglet Events et `hpm events`) lit
    toujours `since_id=0, limit=200` sans jamais suivre `has_more` -- au-delà de 200 événements
    accumulés dans un epoch, l'affichage reste bloqué sur les 200 plus anciens et ne montre plus
    jamais rien de récent -- amendé Tasks & Design Notes pour exiger la pagination jusqu'à
    `has_more == false` avant de retourner la fenêtre la plus récente.

## Design Notes

**Pourquoi la « seule politique par machine » est le point le plus fragile.** `FleetModel.refresh()`
notifie aujourd'hui sans condition sur chaque transition (L.204-206). Ajouter les notifications
d'événements est la moitié facile ; la moitié qui se perd facilement est de couper le fallback dès
qu'une machine sert `events`, pour ne jamais doubler une alerte. Le Code Map nomme le point d'édition
précis pour que cette coupure ne soit pas oubliée en aval du refactor.

**Pourquoi la navigation clic-notification est neuve, et pourquoi elle n'est pas un `Block If`.**
Aucun état de navigation programmatique n'existe entre le menubar/une notification et la sélection
de machine + onglet dans `ControlCenterView`/`MachineDetailView` : `tab` (L.70) est un `@State`
purement local. C'est du câblage UI ordinaire (ajouter un état observé, le consommer une fois), pas
une décision d'architecture — donc une tâche, pas un blocage. `App/Sources` n'a pas de cible de
test (constat pré-existant, DW-7/DW-8) : cette portion reste vérifiée manuellement, pas par un test
unitaire, et c'est consigné comme tel plutôt que fantasmé comme couvert.

**Pourquoi l'état réel de la flotte aujourd'hui (aucune machine ne sert `/api/v1/`) n'empêche pas
cette story d'être menée à son terme.** Deux des trois AC de cette story décrivent précisément la
dégradation propre — le chemin que la flotte emprunte réellement tant que le chantier miroir
Homeport n'a pas livré. Seule la notification sur `critical` (AC1) ne peut pas s'exercer en bout en
bout contre un serveur réel ; elle se vérifie comme 2.1 a vérifié sa compatibilité de version, par
décodage de fixtures conformes au contrat (§8) injectées dans un client de test.

**Pourquoi le premier pull ne doit jamais notifier rétroactivement.** Une machine qui vient d'obtenir
`events` dans ses `features` (mise à jour Homeport, ou premier lancement de l'app) peut avoir un
historique déjà peuplé de `critical`. Traiter `notified_up_to` comme `0` par défaut sur ce premier
pull revient à faire sonner l'app pour des incidents parfois anciens de plusieurs semaines -- une
lecture littérale de la règle « `critical` non encore notifié -> notifie », mais qui contredit
l'esprit de la fonctionnalité (alerter sur du nouveau, pas rejouer l'histoire) et la propre doctrine
déjà écrite dans ce même code pour le mécanisme voisin (`transitions(old: nil) -> []`). Établir
`notified_up_to` à l'`id` le plus haut déjà présent, silencieusement, est la seule lecture cohérente.

**Pourquoi l'affichage ne peut pas se contenter de `since_id=0, limit=200`.** Le contrat ne propose
aucun moyen de demander directement « les événements les plus récents » -- seulement un pull
ascendant avec `since_id`/`has_more` (§6). Un fetch qui s'arrête à la première page reste bloqué sur
les 200 événements les plus anciens de l'epoch dès que l'historique dépasse `limit`, et ne montre
plus jamais rien de récent -- silencieusement, sans erreur, ce qui est pire qu'une absence de
données. Paginer jusqu'à `has_more == false` avant de retourner la fenêtre la plus récente est requis
par AD-13 (l'onglet Events et `hpm events` doivent montrer la même chose) autant que par le bon sens
produit.

**KEEP -- à préserver tel quel dans la re-dérivation, ce n'est pas remis en cause :**
- Le design stateless de `fetchEventsForDisplay` (jamais une projection du curseur de notification,
  toujours un fetch frais) -- seule sa boucle de pagination change, pas son indépendance vis-à-vis du
  curseur stocké.
- Le schéma v2 de `HistoryStore` : deux colonnes distinctes `cursor_id`/`notified_up_to` dans
  `event_cursors`, `setEventMarkers` écrivant toujours les deux ensemble (AD-5).
- `EventsPullOutcome` comme résultat pur retourné par `decideEventsPull`, consommé comme un gate
  binaire dans `refresh()` (une seule politique par machine, AC2).
- `checkEventsCapability`, factorisant la triage capabilities entre le pull de notification et le
  fetch d'affichage, pour que les deux surfaces ne puissent jamais diverger sur la disponibilité.
- La structure de test existante (`HomeportAPIClientTests`, `ManagerEventsTests`) et le decoding
  fixtures-driven pour `HomeportAPIClient` (§8) -- seules les assertions touchées par les deux
  amendements ci-dessus doivent changer.

## Verification

**Commands:**
- `swift build` -- expected: compile sans avertissement.
- `swift test --filter HomeportAPIClientTests` -- expected: les scénarios §8 (404, hors plage,
  features absent, erreur réseau, 5xx) passent.
- `swift test --filter ManagerEventsTests` -- expected: invalidation curseur + décision de
  notification couvertes.
- `swift test` -- expected: aucune régression sur la suite existante.
- `bash Scripts/verify-app-build.sh` -- expected: rc 0.

**Manual checks (if no CLI):**
- Sur une machine réelle sans API (état actuel de toute la flotte) : ouvrir l'onglet Événements,
  vérifier l'empty-state « non disponible » + pill Updates, et qu'aucune notification menubar
  existante n'a disparu (le fallback reste actif).
- Simuler, via un client injecté renvoyant une erreur réseau, l'état « injoignable » et vérifier le
  texte « Vu pour la dernière fois ».
- Déclencher une notification `critical` de test (via `Notifier` avec `userInfo` simulé) et
  vérifier que le clic ouvre bien la fiche machine sur l'onglet Événements.
