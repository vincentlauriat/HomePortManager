---
title: '2.2b — Notifications critiques et politique de repli'
type: 'feature'
created: '2026-08-28'
status: 'in-review'
baseline_revision: '8118a40dc69c6f76cd923c217b3c9082d2e714ca'
review_loop_iteration: 1
followup_review_recommended: false
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
  `:472-515` (`eventCursor`/`setEventCursor`/`clearEventCursor`) -- gabarit direct pour
  `notifiedUpTo`/`setNotifiedUpTo`/`clearNotifiedUpTo`, migration `version < 3`.
- `Sources/HomePortKit/Manager+Events.swift:83-134` (`HomeportEventsReader.read`, mode `.window`),
  `48-56` (`EventsRead`) -- réutiliser tel quel pour le sondage de fond (`advancingCursor: false`,
  même chemin que `EventsCmd`).
- `Sources/HomePortKit/Manager+Events.swift:59-71` (`EventWindow.cursorWasReset`), `:181-197`
  (`pull`, la comparaison `stored.epoch != epoch` qui alimente ce champ -- ne s'évalue que si
  `stored` est non-nil) -- le sondage de fond DOIT passer le vrai `EventCursorStore` (celui de
  l'onglet, `model.eventCursors`/`history`) en lecture seule à `HomeportEventsReader.init(cursors:)`
  pour que `cursorWasReset` soit renseigné ; passer `cursors: nil` désactive silencieusement toute
  détection de reset pour la décision de notifier (revue de la 1ʳᵉ tentative de cette story : un
  restore/reflash côté Pi fait repartir les `id` à zéro, `id > notified_up_to` échoue alors pour
  tout événement de la nouvelle génération y compris `critical`, et rien ne le signale). Lire, ne
  jamais écrire : `advancingCursor: false` reste la seule garantie qui compte pour AD-6, cette
  lecture-là ne l'engage pas.
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
- `Sources/HomePortKit/HistoryStore.swift` -- migration `version < 3` + `notifiedUpTo`/
  `setNotifiedUpTo`/`clearNotifiedUpTo` -- second marqueur, gabarit `event_cursors` **y compris sa
  garde de corruption** (`guard lastID >= 0` sur la lecture, même doctrine que `eventCursor`).
- `Sources/HomePortKit/Manager+Notifications.swift` -- créer -- fonction pure
  `notifiableCriticalEvents(in: EventWindow, notifiedUpTo: Int64?) -> (toNotify: [HomeportEvent], newMarker: Int64)`,
  testable sans réseau ni base. **Doit traiter `window.cursorWasReset == true` exactement comme un
  `notifiedUpTo` absent** (ré-initialisation silencieuse au plus grand `id` vu, aucune notification
  rétroactive) plutôt que de comparer contre l'ancien marqueur -- sans quoi un restore/reflash côté
  Pi (ids repartis à zéro) fait échouer `id > notified_up_to` pour toute la fenêtre qui suit le
  reset, `critical` compris, et rien ne le signale. Doc comment attaché à la déclaration de la
  fonction (pas un commentaire de fichier orphelin séparé par une ligne vide).
- `App/Sources/FleetModel.swift` -- timer de sondage 45 s par machine (`.window`,
  `advancingCursor: false`, **`cursors:` le vrai store de l'onglet -- lecture seule, jamais
  d'écriture depuis ce chemin**), `eventsAvailable` sticky, notifie via `Notifier`, avance le
  marqueur, gate la boucle `transitions()`/`Notifier.notify` de `refresh()` sur
  `!eventsAvailable[name]`. La constante de cadence (45 s) vit ici ou dans un fichier neutre, pas
  dans `EventsTabView` (un type modèle ne doit pas dépendre d'un type vue pour sa propre cadence).
  Le sondage doit vérifier que la machine est toujours déclarée (`model.machines`) avant d'écrire
  `eventsAvailable[name]` -- une machine retirée de fleet.yaml pendant un sondage en vol ne doit
  pas laisser réapparaître une entrée après le nettoyage de `reloadFleet()`.
- `App/Sources/Notifier.swift` -- délégué de clic, `userInfo["machine"]` ; **titre et corps de la
  notification passent tous deux par `String(localized:)`** (pas seulement le titre). Le délégué
  doit tolérer `Notifier.model` encore nil au moment du clic (course avec `FleetModel.init` au
  lancement) sans échouer silencieusement -- au minimum une trace sur le canal d'avertissement
  existant. `Notifier.model` annoté `@MainActor` (écrit et lu uniquement depuis l'acteur principal).
- `App/Sources/ControlCenterWindow.swift`, `ControlCenterView.swift`, `MachineDetailView.swift` --
  route "ouvrir machine X, onglet Événements" depuis le délégué jusqu'à la sélection + `.selectTab`.
  Si la machine visée n'existe plus dans `model.machines` au moment où la requête en attente est
  consommée, la vider plutôt que la laisser en suspens (elle ne serait sinon jamais nettoyée par
  l'`onChange` de la liste des machines, qui ne réagit qu'aux *changements* de la liste).
- `App/Sources/Localizable.xcstrings` -- ajouter les clés du titre/corps de notification (fr, en,
  zh-Hans), gabarit des clés `events.*` ajoutées en 2.2a.
- `Sources/hpm/Commands.swift` (`MachineCmd.Remove`) -- `clearNotifiedUpTo` à côté de
  `clearEventCursor` ; message d'avertissement distinct si l'un échoue sans l'autre (ne pas
  laisser un message qui ne nomme que le curseur alors que c'est le marqueur qui a échoué, ou
  l'inverse).
- `Tests/HomePortKitTests/ManagerNotificationsTests.swift` -- créer -- les 3 scénarios ACs
  (init silencieuse, critical > marqueur notifie, non-critique n'notifie pas) + migration v3 +
  `cursorWasReset == true` traité comme marqueur absent (silencieux, pas de perte).
- `docs/build/deferred-work.md` -- consigner le sondage de fond, le gating single-policy et la
  navigation clic comme non testables (même trou que DW-17, `App/Sources` hors graphe SwiftPM).

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
