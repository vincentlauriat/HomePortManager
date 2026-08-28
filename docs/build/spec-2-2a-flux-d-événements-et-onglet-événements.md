---
title: '2.2a — Flux d''événements et onglet Événements'
type: 'feature'
created: '2026-08-28'
status: 'done'
baseline_commit: 'bce3e59a2a52a98bd281eb79c6448133e262603c'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/docs/build/epic-2-context.md'
  - '{project-root}/docs/api/homeport-api-v1.md'
warnings: ['oversized']
deferred: ['DW-17', 'DW-18', 'DW-19']
---

<intent-contract>

## Intent

**Problem:** L'onglet Événements affiche encore le message générique de la story 2.1 (« arrive avec
2.1 », périmé depuis que 2.1 est `done`) ; aucun client ne consomme le contrat v1 pour peupler cet
onglet ni `hpm events`, et aucune machine réelle ne distingue « Homeport ne sert pas encore l'API »
d'« injoignable ».

**Approach:** Écrire `HomeportAPIClient` (capabilities + events, décodage conforme au contrat v1
§4/§6/§8) via `URLSession` (AD-3), un curseur `(epoch, id)` par machine dans hpm.db, et remplir
l'onglet Événements + `hpm events` avec les trois états du contrat. Les notifications critiques et
`notified_up_to` sont hors périmètre (2.2b).

## Boundaries & Constraints

**Always:**
- Consomme le contrat v1 sans l'étendre (AD-4) ; toute lacune constatée va dans `deferred`, jamais
  une extension à la volée.
- HTTP via `URLSession` sur le tailnet, exception ATS unique déjà déclarée et partagée avec
  `WKWebView` (AD-3) — aucun nouveau contournement.
- Seul état persisté côté Mac : le curseur `(epoch, id)` par machine dans hpm.db (AD-6) — jamais de
  copie durable d'événements, jamais `notified_up_to` (2.2b).
- Curseur invalidé si l'`epoch` reçu diffère du curseur OU si `latest_id` < id du curseur (§5) —
  repart du début de l'epoch courant, sans exception levée.
- Sévérité inconnue (hors `info`/`warning`/`critical`) → traitée comme `warning`, jamais invisible.
- Texte exact de l'état « non disponible » : « Cette version de Homeport ne fournit pas encore les
  événements » + pill vers Updates (UX-DR5). État « injoignable » = pill critical, distinct.
- La lecture pagine jusqu'à `has_more == false` avant de retenir la fenêtre la plus récente — jamais
  bloquée sur les événements les plus anciens d'un epoch qui dépasse `limit` (leçon de la 1ʳᵉ
  tentative, `deferred-work.md`).
- `hpm events [--machine] [--severity]` sert exactement le même contenu filtré que l'onglet
  correspondant (AD-13).
- Le poll (30–60 s) est scopé à l'onglet Événements ouvert — pas de nouveau timer global dans
  `FleetModel` ; un poll de fond pour les notifications, si nécessaire, est une décision de 2.2b.

**Never:**
- Étendre le contrat v1 (AD-4) ou toucher au repo Homeport.
- Introduire un stream (SSE/WebSocket) — le pull à curseur reste le mécanisme de vérité en v1.
- Implémenter les notifications, `notified_up_to`, ou le gating de `FleetHealth.transitions` — c'est
  2.2b.
- Toucher au volet métriques du contrat (2.3) ou à `sprint-status.yaml`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| 404 sur `capabilities` | Homeport sans API v1 | « non disponible », pill vers Updates | jamais une erreur |
| `contract` hors plage consommée | ex. `"2.0.0"` | idem, en nommant la version rencontrée | jamais une erreur |
| `events` absent de `features` | `capabilities` OK, `features: ["metrics"]` | « non disponible » sur l'onglet Events seulement | jamais une erreur |
| Erreur réseau / timeout / 5xx | machine injoignable | « injoignable », derniers événements connus + « Vu pour la dernière fois à HH:MM » | distinct de « non disponible » |
| `epoch` changé ou `latest_id` < curseur | reset/restore côté Pi | curseur réinitialisé au début du nouvel epoch | pas une erreur |
| Historique d'un epoch > `limit` | pagination | pagine jusqu'à `has_more == false`, retient la fenêtre la plus récente | jamais tronqué sur l'ancien |

</intent-contract>

## Code Map

- `docs/api/homeport-api-v1.md:63-98` (`capabilities`), `:100-149` (epoch/curseur), `:151-276`
  (`events`, pagination, sévérités, `kind`), `:355-371` (§8, échecs) -- lecture seule (AD-4).
- `Sources/HomePortKit/HomeportAPIContract.swift:77` -- `compatibility(with:)`, à réutiliser pour
  distinguer « hors plage » d'un 404 pur.
- `Sources/HomePortKit/Dashboard.swift:16` -- `dashboardURL(for:)`, dérivation host/port depuis
  `machine.ssh`/`machine.port` (AD-3) ; même dérivation pour la base `HomeportAPIClient`, path
  `/api/v1/...`.
- `Sources/HomePortKit/HistoryStore.swift:469` (`migrate(from:)`, garde `version < 1`), `:61`
  (`schemaVersion`) -- ajouter la migration `version < 2` : table/colonnes curseur `(epoch, id)`
  par machine, même style (pas de struct par migration, `now: Date` injectable).
- `App/Sources/MachineDetailView.swift:10` (`MachineTab.events`), `:34-43` (`pendingMessage`, l.37
  texte périmé « arrives with story 2.1 »), `:51-56` (`fillsSheet`, l.54), `:222-234` (switch
  `fullTab`, l.231-232 groupe `EmptyView` à sortir pour `.events`).
- `App/Sources/DashboardTabView.swift:203-225` -- gabarit à 3 branches (unreachable / échec /
  contenu), à reprendre pour Events.
- `App/Sources/DesignComponents.swift:578` -- `EmptyStateView(title:message:detail:actionTitle:action:)`,
  réutilisable tel quel.
- `Sources/HomePortKit/FleetRow.swift:8-12` -- `Severity` (`ok`/`warning`/`critical`). `StatusPill`
  (`App/Sources/DesignComponents.swift:85-86`) est typée sur ce seul enum : un événement API doit
  être mappé (`info`→`ok`, `warning`→`warning`, `critical`→`critical`) pour réutiliser `StatusPill`
  tel quel, plutôt que de créer un second composant pill.
- `Sources/hpm/Commands.swift:309-373` -- `TasksCmd`, gabarit direct pour `EventsCmd` (options
  facultatives, garde d'existence hpm.db, `printTable`).
- `Sources/HomePortKit/FleetHealth.swift:41-42` -- `transitions(old:new:)`,
  `guard let old else { return [] }` : précédent de conception pour « le premier pull établit une
  base, ne notifie/n'alerte jamais rétroactivement » (lecture seule, ne pas toucher ce fichier).
- `Sources/HomePortKit/ReleaseService.swift:26-33,66-80` -- seul précédent de décodage JSON +
  erreurs `HPMError` dans le Kit ; **aucun précédent `URLSession`/async-await** n'existe (réseau
  existant = `curl` synchrone via `ProcessRunner`) — `HomeportAPIClient` innove sur ce point,
  mandaté par AD-3.
- `Tests/HomePortKitTests/HomeportAPIContractTests.swift`, `MachineIssueTests.swift` -- gabarits de
  test (`XCTest` + `@testable import HomePortKit`).
- `App/Sources/FleetModel.swift:31-32` (`lastReachableStatus`, `lastSeenAt`) -- précédent direct pour
  « Vu pour la dernière fois à HH:MM » : dictionnaires par machine, tenus à part de l'état brut ;
  même schéma pour un « dernier vu » propre au poll HTTP events (SSH et HTTP restent deux sources
  distinctes, ne pas fusionner les dictionnaires).
- `App/Sources/FleetModel.swift:89` -- timer existant (300 s, SSH) : ne pas y accrocher le poll
  events (30-60 s, HTTP) ; mécanisme séparé, scopé à l'onglet ouvert.
- `App/Sources/FleetOverviewView.swift:74-79`, `App/Sources/DesignComponents.swift:177`
  (`FilterField`) -- seul filtre existant, textuel (nom de machine) : aucun précédent de filtre par
  catégorie/sévérité dans l'app — un `Picker` segmenté sur les 3 sévérités est une nouvelle surface,
  pas une réutilisation.

## Tasks & Acceptance

**Execution:**
- `Sources/HomePortKit/HomeportAPIClient.swift` -- créer -- GET `capabilities`/`events` via
  `URLSession`, décodage conforme au contrat, classification en `APIAvailability`
  (available/unavailable(reason)/unreachable).
- `Sources/HomePortKit/HistoryStore.swift` -- migration `version < 2` -- curseur `(epoch, id)` par
  machine.
- `Sources/HomePortKit/Manager+Events.swift` -- créer -- pull depuis le curseur stocké, invalidation
  (epoch changé OU `latest_id` < curseur), pagination jusqu'à `has_more == false` puis fenêtre la
  plus récente (taille `limit`) -- pur, testable via un client injecté ; source unique lue à la fois
  par l'onglet et `hpm events` (AD-13).
- `App/Sources/MachineDetailView.swift` -- remplacer le `pendingMessage` périmé de `.events` par les
  3 états du contrat (gabarit `DashboardTabView`/`EmptyStateView`), liste des événements en sévérité
  pill, et un `Picker` segmenté par sévérité (`info`/`warning`/`critical`) filtrant l'affichage.
- `Sources/hpm/Commands.swift` -- ajouter `EventsCmd` (`hpm events [--machine] [--severity]`),
  gabarit `TasksCmd`.
- `Tests/HomePortKitTests/HomeportAPIClientTests.swift` -- créer -- décodage de fixtures conformes
  au contrat pour chaque ligne de §8.
- `Tests/HomePortKitTests/ManagerEventsTests.swift` -- créer -- invalidation curseur, pagination
  au-delà de `limit`, sévérité inconnue → `warning`.
- `docs/build/deferred-work.md` -- consigner le câblage UI non testé (`App/Sources` sans cible de
  test).

**Acceptance Criteria:**
- Given un Homeport exposant l'API, when l'onglet Événements est ouvert, then les nouveaux
  événements apparaissent (sévérité en pill, filtrable), curseur `(epoch, id)` persisté par machine
  dans hpm.db.
- Given `hpm events --machine <nom> --severity <niveau>`, when la commande s'exécute, then le
  contenu filtré est identique à celui de l'onglet pour le même filtre (AD-13).
- Given un epoch qui dépasse `limit` événements, when l'onglet ou `hpm events` lit l'historique,
  then l'affichage montre la fenêtre la plus récente, jamais bloqué sur les plus anciens.

## Spec Change Log

**2026-08-28 — le jalon bloquant est levé.** Le contexte d'epic et `deferred-work.md` décrivent
une flotte où aucune machine ne sert `/api/v1/` ; ce n'est plus vrai. `raspcorse` et `raspyellow`
répondent tous deux `contract 1.0.0`, `server 0.8.0`, `features: ["events","metrics"]`. Le
vérificateur manuel « sur une machine réelle sans API (état actuel de toute la flotte) » n'a donc
plus de sujet : c'est le chemin *disponible* qui a été vérifié en vrai, et les trois états de §8
restent couverts par les tests de décodage. Aucun changement de périmètre.

**2026-08-28 — `hpm events` ne consomme pas le curseur.** La ligne d'exécution disait « pull depuis
le curseur stocké » sans distinguer les deux appelants. Le curseur est le seul état partagé entre
l'app et le CLI (AD-6), et un `hpm events` qui l'avancerait aveuglerait le poll incrémental de
l'onglet — l'app ne verrait jamais ce que le CLI vient d'imprimer. La lecture de fenêtre n'est donc
jamais bornée par le curseur (ce qui est aussi ce qui rend AD-13 vrai), et seule l'app l'avance.
Reporté en 2.2b, où `notified_up_to` rend le geste sûr : voir DW-18.

## Review Triage Log

### 2026-08-28 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 10: (high 0, medium 3, low 7)
- defer: 0
- reject: 8
- addressed_findings:
  - `low` `patch` `HistoryStore.clearEventCursor` n'était jamais appelé (ni par `hpm machine remove`
    ni par la suppression fleet.yaml) malgré son propre commentaire de doc -- câblé dans
    `MachineCmd.Remove`.
  - `medium` `patch` Une annulation de tâche (`URLError.cancelled`/`CancellationError`) pendant un
    fetch en cours était traitée comme `.unreachable` dans `HomeportAPIClient`, polluant
    potentiellement un `EventFeed` qui survit au changement d'onglet -- distinguée de l'échec réel.
  - `low` `patch` Un reset (`historyRestarted`) qui atterrit sur une nouvelle epoch vide passait
    silencieusement par l'état "No events yet" au lieu de montrer la note de reprise --
    `EventsTabView.content` teste désormais `historyRestarted` avant l'état vide générique.
  - `low` `patch` `retry()` et la boucle de poll (45 s) de `EventsTabView` pouvaient s'exécuter en
    concurrence et appliquer un résultat obsolète après un plus frais -- garde `isFetching` ajoutée
    dans `EventFeed`.
  - `medium` `patch` `describe(_ compatibility:)` dupliqué verbatim entre `EventsCmd` et
    `EventsTabView` -- extrait en un point unique pour empêcher toute divergence entre les deux
    surfaces qu'AD-13 exige identiques.
  - `medium` `patch` `EventsCmd` (Sources/hpm/Commands.swift, dans le graphe SwiftPM testable)
    n'avait aucun test -- ajouté pour la validation `--severity`/`--limit` et le format de sortie.
  - `low` `patch` Style de clé de localisation incohérent (`events.filter.*` scopé vs en-têtes de
    colonnes/libellés bruts) dans le même écran -- toutes les clés Events scopées sous `events.*`.
  - `low` `patch` La garde de corruption `guard lastID >= 0` de `HistoryStore.eventCursor` n'était
    couverte par aucun test -- ajouté.
  - `low` `patch` `EventsTabView.content` affichait le texte "No events yet" avant même la fin du
    premier chargement (`feed.loading`), avec pour seul indice un petit spinner dans la barre de
    filtre -- état de chargement dédié ajouté.
  - `low` `patch` La branche "epoch encore périmée après une première reprise" (`.stale` deux fois
    de suite) de `HomeportEventsReader.pull` n'était couverte par aucun test -- ajouté.

## Design Notes

**Pourquoi la pagination ne peut pas s'arrêter à la première page.** Le contrat ne propose aucun
moyen de demander « les événements les plus récents » -- seulement un pull ascendant
`since_id`/`has_more` (§6). S'arrêter à la première page bloque l'affichage sur les événements les
plus anciens dès que l'historique dépasse `limit`, silencieusement. Paginer jusqu'à
`has_more == false` avant de ne garder que la fenêtre la plus récente est requis par AD-13 autant
que par le bon sens produit -- bug déjà trouvé et corrigé sur la story 2.2 avant sa scission
(`deferred-work.md`).

**Pourquoi le poll reste scopé à l'onglet.** Sans notifications à décider (2.2b), rien n'exige un
poll de fond quand l'onglet est fermé ; ajouter un timer global à `FleetModel` maintenant serait de
la portée anticipée pour 2.2b, à trancher là-bas selon ce qu'exige la détection de `critical` en
tâche de fond.

## Verification

**Commands:**
- `swift build` -- expected: compile sans avertissement.
- `swift test --filter HomeportAPIClientTests` -- expected: les scénarios §8 (404, hors plage,
  feature absente, erreur réseau, 5xx) passent.
- `swift test --filter ManagerEventsTests` -- expected: invalidation curseur + pagination couvertes.
- `swift test` -- expected: aucune régression sur la suite existante.
- `bash Scripts/verify-app-build.sh` -- expected: rc 0.

**Manual checks (if no CLI):**
- Sur une machine réelle sans API (état actuel de toute la flotte) : ouvrir l'onglet Événements,
  vérifier l'empty-state « non disponible » + pill Updates.
- Simuler, via un client injecté renvoyant une erreur réseau, l'état « injoignable » et vérifier le
  texte « Vu pour la dernière fois ».

## Auto Run Result

**Résumé.** `HomeportAPIClient` (capabilities + events via `URLSession`, AD-3) et
`HomeportEventsReader` (`Sources/HomePortKit/Manager+Events.swift`) consomment le contrat v1 ;
`HistoryStore` migre en schéma v2 pour persister un curseur `(epoch, id)` par machine ; l'onglet
Événements (`EventsTabView.swift`) et `hpm events` lisent la même source (AD-13) et rendent les
trois états du contrat, avec filtre de sévérité (`Picker` segmenté côté app, `--severity` côté CLI).
La pagination va jusqu'à `has_more == false` avant de retenir la fenêtre la plus récente (bug de la
1ʳᵉ tentative de la story 2.2, évité). Les notifications, `notified_up_to` et le gating de
`FleetHealth` restent hors périmètre (2.2b), comme prévu.

**Fichiers modifiés/créés :**
- `Sources/HomePortKit/HomeportAPIClient.swift` (créé) -- client `capabilities`/`events`, décodage
  conforme au contrat, classification 404/hors-plage/feature-absente/injoignable/annulation.
- `Sources/HomePortKit/Manager+Events.swift` (créé) -- `HomeportEventsReader` : curseur, invalidation
  §5, pagination, filtre partagé.
- `Sources/HomePortKit/HistoryStore.swift` -- migration `version < 2`, table `event_cursors`,
  accesseurs curseur.
- `Sources/HomePortKit/HomeportAPIContract.swift` -- `Sendable`, `describedVersion` partagé (évite la
  duplication trouvée en revue).
- `App/Sources/EventsTabView.swift` (créé) -- `EventFeedStore`/`EventFeed`, les 3 états, filtre de
  sévérité, poll scopé à l'onglet (45 s).
- `App/Sources/MachineDetailView.swift` -- `.events` sort du groupe `EmptyView`, branché sur
  `EventsTabView`, message périmé de la story 2.1 retiré.
- `App/Sources/FleetModel.swift`, `App/Sources/ControlCenterWindow.swift` -- exposition de
  `eventCursors` et câblage de navigation.
- `App/Sources/Localizable.xcstrings` -- clés `events.*` (en/fr/zh-Hans), texte exact UX-DR5.
- `Sources/hpm/Commands.swift`, `Sources/hpm/HPM.swift` -- `EventsCmd`, promotion en
  `AsyncParsableCommand`, câblage de `clearEventCursor` dans `MachineCmd.Remove`.
- `Package.swift` -- cible de test étendue à `hpm` pour couvrir `EventsCmd`.
- Tests créés : `HomeportAPIClientTests.swift`, `ManagerEventsTests.swift`, `EventsCmdTests.swift` ;
  étendus : `HistoryStoreTests.swift`, `LockTests.swift`.
- `docs/build/deferred-work.md` -- DW-17 (câblage UI `App/Sources` non testable), DW-18 (`hpm events`
  n'avance pas le curseur -- attendu, 2.2b), DW-19 (métriques §7 hors périmètre) ; entrée 2.1 sur
  l'absence d'API marquée résolue (l'API est désormais servie par `raspcorse`/`raspyellow`).

**Revue.** 1 passe : intent_gap 0, bad_spec 0, patch 10 (medium 3, low 7), defer 0, reject 8. Les 10
patches ont été appliqués (câblage `clearEventCursor`, annulation de tâche distinguée d'un vrai
échec réseau, notice de reprise visible même sur une fenêtre vide, garde anti-course retry/poll,
`describe(_:)` dédupliqué, tests `EventsCmd`/garde de corruption/`.stale` répété ajoutés, clés de
localisation unifiées, état de chargement dédié). Détail dans `## Review Triage Log`.

**Vérification.** `swift build` (0 avertissement), `swift test --filter HomeportAPIClientTests`
(20/20), `swift test --filter ManagerEventsTests` (24/24), `swift test` complet (298/298),
`bash Scripts/verify-app-build.sh` (rc 0) -- tout reconfirmé indépendamment après la passe de
patches. Audit de la matrice I/O : les 6 lignes sont couvertes par des tests exécutés et passants.
Vérification manuelle supplémentaire (par le sous-agent d'implémentation, hors script) contre les
deux machines réelles `raspcorse`/`raspyellow`, qui servent désormais `/api/v1/` : `hpm events`
lit leurs journaux réels, la pagination au-delà de `limit` a été vérifiée sur un historique de 105
événements, et le filtre `--severity` a été exercé en conditions réelles.

**Risques résiduels :**
- **Incident git pendant la passe de patch (finding #7).** Le sous-agent a exécuté
  `git checkout -- App/Sources/Localizable.xcstrings` pour annuler une réécriture JSON ratée, ce qui
  a effacé 17 entrées non committées du catalogue de localisation. Il les a reconstruites par
  insertions chirurgicales ; 8 avaient leurs traductions fr/zh-Hans déjà connues et restaurées à
  l'identique, mais **9 ont reçu de nouvelles traductions fr/zh-Hans réécrites de mémoire**
  (`Go to Updates`, `Events not available`, `Filter events by severity`, `No event matches`, son
  message détaillé, `No events yet` et son message détaillé, la notice de reprise d'epoch, et le
  texte exact UX-DR5). Vérification manuelle faite ici même : le français est orthographiquement
  correct (accents complets) et le texte UX-DR5 correspond exactement à la Boundary du spec ; le
  chinois n'a pas été vérifié par un locuteur. Un coup d'œil humain sur ces 9 chaînes reste
  recommandé.
- `App/Sources` reste hors du graphe de test SwiftPM (contrainte pré-existante depuis l'epic 1,
  DW-7/DW-8/DW-17) : `EventsTabView`, `EventFeed` (dont la logique replace-vs-merge) et le câblage UI
  ne sont vérifiés que manuellement/par lecture, jamais par un test exécuté.
- `hpm events` n'avance délibérément pas le curseur (DW-18) : normal tant que `notified_up_to`
  n'existe pas (2.2b), mais un lecteur pressé du code source pourrait s'attendre au contraire.
