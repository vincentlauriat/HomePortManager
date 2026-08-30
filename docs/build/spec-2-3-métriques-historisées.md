---
title: '2.3 — Métriques historisées'
type: 'feature'
created: '2026-08-29'
baseline_revision: 'fd59f0e856b0e40d17b8ce86a0ed51d84a48f0fc'
status: 'in-review'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/build/epic-2-context.md'
  - '{project-root}/docs/api/homeport-api-v1.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** L'onglet Métriques de la fiche machine est encore un empty-state (« Metric charts
arrive with story 2.3 ») et `hpm metrics` n'existe pas, alors que le volet `GET /api/v1/metrics`
du contrat v1 est **servi en production** par `raspcorse` et `raspyellow` (`features:
["events","metrics"]`, grille conforme vérifiée le 29/08) : CAP-8 / FR8 est la dernière capacité
de l'epic 2 dont la donnée existe et ne se voit nulle part.

**Approach:** Consommer le volet métriques du contrat **sans l'étendre** (AD-4), sur le même
patron que 2.2a/2.2b : un décodage + une classification §8 dans `HomeportAPIClient`, un lecteur
pur (`HomeportMetricsReader`) et toute la logique décidable (grille, segmentation des `null`,
courant/min/max, mise en forme des lignes CLI) dans `HomePortKit` où `swift test` la tient ;
puis deux surfaces jumelles et minces au-dessus — l'onglet Métriques (4 `metric-card` Swift
Charts + sélecteur de plage) et `hpm metrics <machine> [--range …]`.

## Boundaries & Constraints

**Always:**
- Le contrat est consommé, jamais étendu (AD-4) : aucune route, aucun paramètre, aucun champ
  hors de `docs/api/homeport-api-v1.md` §4 et §7.
- Les trois états du contrat (§8) sont rendus tels quels, jamais comme une erreur :
  `available` / `unavailable` (→ Updates) / `unreachable` (→ garde les dernières données
  connues + heure de dernière vue, UX-DR5).
- **La grille servie fait foi** : l'instant du point `i` vaut `from + i * step_s`, avec `from`,
  `to` et `step_s` **tels que servis**. Ne jamais coder en dur 60/300/3600/86400 (§7 : « le
  client ne ré-échantillonne pas »).
- Un `null` est une absence de mesure : jamais un zéro, jamais interpolé — la courbe
  s'interrompt (§7).
- Les 4 séries connues sont toujours affichées, y compris absentes de `series` ou entièrement
  `null` : carte vide, jamais carte manquante (§7). Une clé inconnue de `series` est ignorée.
- Toute logique décidable vit dans `Sources/HomePortKit/` ; `App/Sources` n'est couvert par
  aucun test unitaire (action item 8 de la rétro epic 1).
- Les composants de `docs/build/design-components.md` sont consommés, pas redéfinis (UX-DR2) ;
  un composant ajouté y ajoute sa ligne.
- Toute chaîne d'interface nouvelle est traduite dans **les trois langues** du catalogue
  (`en`, `fr`, `zh-Hans`, état `translated`) — aucun gate ne rattrape une locale manquante.

**Block If:**
- Le contrat `docs/api/homeport-api-v1.md` devrait être modifié pour que la story tienne
  (2.1 est la seule rédactrice ; 2.3 consomme).
- L'implémentation exigerait un second contournement App Transport Security ou un transport
  autre que le `URLSession` éphémère déjà en place (AD-3).

**Never:**
- Aucun état durable côté Mac pour les métriques (AD-6) : ni curseur, ni epoch, ni point de
  série dans `hpm.db`. `MetricsCmd` **ne touche pas** `HistoryStore` — il n'y a rien à y
  écrire, et recopier la plomberie `fileExists` / `HistoryStore()` d'`EventsCmd` par symétrie
  serait un faux parallèle.
- Aucun ré-échantillonnage, agrégation ou lissage côté client.
- Ne pas remanier `HomeportEventsReading`, `HomeportEventsReader` ni `EventsCmd` : la story
  ajoute un protocole et un lecteur à côté, elle ne refactorise pas l'existant de 2.2a/2.2b.
- Pas de sondage de fond : l'onglet Métriques ne lit que pendant qu'il est visible (`.task`),
  contrairement au sondage d'événements de `FleetModel`.
- Pas de notification, pas de badge, pas de seuil d'alerte à partir des métriques.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Plage nominale | `capabilities` 200 avec `"metrics"` dans `features` ; `metrics?range=24h` 200, `step_s=60`, `to-from=86400`, 4 séries de 1440 points | `.window(MetricsWindow)` : epoch, range, step, from/to et les 4 séries dans l'ordre servi | Aucune erreur attendue |
| Série absente du corps | `series` sans `temp_c` | La série `temp_c` existe dans la fenêtre, entièrement `null` (§7) — 4 cartes toujours | Aucune erreur attendue |
| Série inconnue | `series` contient `net_rx_bps` | Ignorée sans erreur (client v1.0, §7) | Aucune erreur attendue |
| Trous de mesure | `cpu_pct` = `[1.0, null, null, 2.0]` | 2 segments de 1 point chacun ; la courbe ne relie pas les deux ; valeur courante = 2.0 | Aucune erreur attendue |
| Série toute `null` | `temp_c` = 1440 × `null` | Carte présente, valeur courante « — », aucun segment tracé | Aucune erreur attendue |
| Grille incohérente | `(to - from)` non multiple de `step_s`, ou `step_s <= 0`, ou `to <= from`, ou une série connue de longueur ≠ `(to-from)/step_s` | `.unavailable(.surfaceNotServed("metrics"))` | Traité comme un corps non conforme — jamais une panne (§8, ligne « annoncée mais discordante ») |
| Corps non décodable | 200 avec un JSON qui n'est pas §7 | `.unavailable(.surfaceNotServed("metrics"))` | Idem |
| `metrics` hors de `features` | `capabilities` 200, `features: ["events"]` | `.unavailable(.surfaceNotServed("metrics"))` sans appeler `metrics` (§4) | Empty-state → Updates |
| Surface annoncée, 404 | `features` contient `"metrics"`, `metrics` répond 404 | `.unavailable(.surfaceNotServed("metrics"))` | §8 : jamais une panne |
| `range` refusé | `metrics?range=1y` → **400** | `.unavailable(.surfaceNotServed("metrics"))` | §8 : ne pas réessayer à l'identique, ne rien invalider ; le remède est une mise à jour, pas une intervention machine |
| API absente | `capabilities` → 404 | `.unavailable(.notServed)` | Empty-state → Updates |
| Contrat hors plage | `contract: "2.0.0"` | `.unavailable(.incompatibleContract(...))` nommant la version rencontrée | Empty-state → Updates |
| Machine injoignable | erreur réseau, timeout ou 5xx | `.unreachable(detail)` | Les courbes déjà lues restent, avec l'heure de dernière lecture (UX-DR5) |
| Lecture annulée | changement d'onglet en cours de fetch | `.cancelled` | Rien n'est publié : ni verdict, ni effacement |
| Changement de génération | epoch servi ≠ epoch de la dernière lecture réussie de cette machine (mémoire de session) | Les courbes affichées sont remplacées, une note « nouvelle génération » s'affiche | Jamais une erreur (§5/§7) |

</intent-contract>

## Code Map

**À lire avant d'écrire (patrons à reproduire, non modifiés) :**
- `Sources/HomePortKit/Manager+Events.swift` — le patron du lecteur pur : protocole d'API
  injecté, poignée de main `capabilities` puis garde `features`, retour en trois états.
  **Ne pas modifier.**
- `App/Sources/EventsTabView.swift` — le patron d'onglet : `EventFeedStore` (l:12-33) possédé
  par la fenêtre, `EventFeed` `ObservableObject` (l:37-134) avec `isFetching` anti-course,
  `.task(id: machine.name)` (l:194-203), l'ordre des états d'affichage (l:227-262), le
  `unreachableNotice` (l:290-311), `detail(for:)` (l:277-286). **Ne pas modifier.**
- `Tests/HomePortKitTests/HomeportAPIClientTests.swift` — le seam de test : `fetch` remplacé,
  helper `ok(_:)` (l:149). `Tests/HomePortKitTests/ManagerEventsTests.swift` — le faux
  `HomeportEventsReading` (l:16 `features`). Copier la forme, pas les fichiers.

**À modifier :**
- `Sources/HomePortKit/HomeportAPIClient.swift` — ajouter `MetricsRange`, `MetricSeries`,
  `MetricsWindow`, `MetricsOutcome`, `HomeportMetricsReading`, `HomeportAPIClient.metricsFeature`
  et `metrics(of:range:)`. Réutiliser `endpoint(_:on:query:)` (l:210-219), `describe(_:)`,
  `isCancellation(_:)`, `APIUnavailableReason`. `HomeportAPIClient` conforme aux **deux**
  protocoles ; `HomeportEventsReading` inchangé.
- `App/Sources/MachineDetailView.swift` — `pendingMessage` l:34-41 (`.metrics` → `nil`) ;
  `content` l:283-290 (**doit** aiguiller sur `tab` : sans ça l'onglet Métriques rend le
  Résumé, sans erreur de compilation). `fillsSheet` l:50-55 et le groupe `EmptyView()` de
  `fullTab` l:251-252 restent tels quels — les cartes scrollent dans la `ScrollView` de la
  fiche. Nouveau paramètre `metrics: MetricsStore`.
- `App/Sources/ControlCenterWindow.swift` — `@StateObject private var metrics = MetricsStore()`
  près de l:192 ; `metrics.prune(keeping: names)` à côté des trois autres l:239-241 ;
  passage à `MachineDetailView` l:306-308.
- `Sources/hpm/Commands.swift` — `MetricsCmd` à côté d'`EventsCmd` (l:414-529). Reprendre
  `printTable` et le `static rows(for:)` testable (patron l:515-529). **Sans** `HistoryStore`.
- `Sources/hpm/HPM.swift` l:15-20 — enregistrer `MetricsCmd.self`.
- `App/Sources/Localizable.xcstrings` — 167 clés, `en`/`fr`/`zh-Hans` toutes `translated`.
  Ajouter les clés `metrics.*` dans les trois langues.
- `docs/build/design-components.md` — ajouter la ligne `MetricCard` au tableau (règle du
  fichier lui-même).

**À créer :**
- `Sources/HomePortKit/Manager+Metrics.swift` — `HomeportMetricsReader`.
- `App/Sources/MetricsTabView.swift` — `MetricsStore`, `MetricsFeed`, `MetricsTabView`,
  `MetricCard`.
- `Tests/HomePortKitTests/HomeportAPIMetricsTests.swift`, `ManagerMetricsTests.swift`,
  `MetricsCmdTests.swift`.

**Contraintes de plateforme / lecture seule :**
- `App/project.yml` : `deploymentTarget macOS 13.0` → Swift Charts disponible, `import Charts`
  suffit (framework système, pas de dépendance à déclarer). Ne pas toucher `project.yml`.
- `Package.swift` : la cible de test dépend déjà de `HomePortKit` **et** `hpm` — `MetricsCmd`
  est testable sans modification.
- `Theme` (`App/Sources/Theme.swift`) est le seul endroit où vit une couleur, une taille ou un
  rayon. `Theme.ink`, `Theme.hairlineSoft`, `Theme.canvas`, `Theme.Rounded.md`,
  `Theme.eyebrow`, `Theme.sectionTitle`, `Theme.data`, `Theme.Spacing.md` couvrent la
  `metric-card` de DESIGN.md l:187-192 et l:293. Une valeur absente s'ajoute à `Theme`.
- État live vérifié le 29/08 : `raspcorse` et `raspyellow` servent `contract 1.0.0`,
  `server 0.8.0`, `features ["events","metrics"]` ; `range=24h` → 1440 points × 4 séries,
  `range=1y` → 365 ; `range=bogus` → 400. Aucune action opérateur n'est due.

## Tasks & Acceptance

**Execution:**
- `Sources/HomePortKit/HomeportAPIClient.swift` -- ajouter le volet métriques du contrat :
  `MetricsRange` (`h24="24h"`, `d7="7d"`, `d30="30d"`, `y1="1y"`, `CaseIterable`, libellé
  d'affichage) ; `MetricSeries` (clé + `[Double?]`) avec `current` (dernier non-`null`),
  `minimum`, `maximum`, `segments` (suites contiguës de points non-`null`, chacune portant son
  index de grille) ; `MetricsWindow` (epoch, range, `stepS`, `from`, `to`, les 4 séries dans
  l'ordre CPU/RAM/disque/température, `timestamp(at:)`) ; `MetricsOutcome`
  (`window`/`unavailable`/`unreachable`/`cancelled`) ; `HomeportMetricsReading` ;
  `metricsFeature = "metrics"` ; `metrics(of:range:)` qui décode §7, valide la grille et
  classe §8 -- le décodage et la classification vivent là où ceux d'`events` vivent déjà, et
  la logique de série est pure donc testable.
- `Sources/HomePortKit/Manager+Metrics.swift` -- créer `HomeportMetricsReader` :
  `read(_ machine:range:)` fait la poignée de main `capabilities`, garde sur
  `serves("metrics")` avant tout appel à `metrics`, et retourne les mêmes trois états que le
  lecteur d'événements -- un seul lecteur pour l'onglet et le CLI (AD-13), aucun stockage.
- `Sources/hpm/Commands.swift` -- ajouter `MetricsCmd` : argument machine positionnel,
  `--range` (défaut `24h`, valeur inconnue = erreur d'usage nommant les quatre valeurs), une
  ligne d'en-tête `range / step / from / to / points`, puis `static rows(for:)` produisant
  `DATE | CPU% | MEM% | DISK% | TEMP°C`, du plus récent au plus ancien, un `-` par mesure
  absente -- même contenu que l'onglet (FR11/AD-13), même forme testable qu'`EventsCmd.rows`.
- `Sources/hpm/HPM.swift` -- enregistrer `MetricsCmd.self` dans `subcommands` -- sans quoi la
  commande n'existe pas.
- `App/Sources/MetricsTabView.swift` -- créer `MetricsStore` (une `MetricsFeed` par machine +
  `prune(keeping:)` + le `HomeportAPIClient` unique), `MetricsFeed` (fenêtre courante, plage
  choisie, `unavailable`/`unreachable`/`lastReachedAt`/`loading`/`historyRestarted`, garde
  `isFetching`, epoch de la dernière lecture réussie **en mémoire seulement**), et
  `MetricsTabView` (sélecteur de plage segmenté + grille de 4 `MetricCard`, chacune : titre
  eyebrow, valeur courante en `sectionTitle`, `Chart` avec `LineMark` encre + `AreaMark` à 8 %
  et grille `hairlineSoft`, **hauteur explicite**) -- la vue ne décide rien : elle rend ce que
  le kit a calculé.
- `App/Sources/MachineDetailView.swift` -- `pendingMessage` de `.metrics` → `nil`, `content`
  aiguillé sur `tab` pour rendre `MetricsTabView`, nouveau paramètre `metrics: MetricsStore`
  -- passer `pendingMessage` à `nil` sans toucher `content` rendrait le Résumé sur l'onglet
  Métriques, sans rien casser à la compilation.
- `App/Sources/ControlCenterWindow.swift` -- posséder le `MetricsStore`, le purger avec les
  trois autres, le passer à `MachineDetailView` -- une machine retirée de `fleet.yaml` ne doit
  pas garder de feed derrière la scène.
- `App/Sources/Localizable.xcstrings` -- ajouter les clés `metrics.*` (libellés des 4 séries,
  segments de plage, titres d'états) en `en`, `fr` et `zh-Hans`, état `translated` -- une
  locale manquante ne fait échouer aucun gate.
- `Tests/HomePortKitTests/HomeportAPIMetricsTests.swift` -- couvrir la matrice I/O au niveau
  du client via le seam `fetch` : plage nominale, série absente, série inconnue, grille
  incohérente (4 formes), corps non décodable, 400, 404, 5xx, annulation.
- `Tests/HomePortKitTests/ManagerMetricsTests.swift` -- couvrir le lecteur via un faux
  `HomeportMetricsReading` : garde `features`, propagation des trois états, et les fonctions
  pures (`current`/`minimum`/`maximum`/`segments`/`timestamp(at:)`) sur les cas à trous.
- `Tests/HomePortKitTests/MetricsCmdTests.swift` -- épingler l'analyse de `--range` et la forme
  exacte de `MetricsCmd.rows(for:)` (ordre antichronologique, `-` des `null`, 5 colonnes).
- `docs/build/design-components.md` -- ajouter la ligne `MetricCard` au tableau des composants
  -- la règle du fichier : un composant non consigné est le prochain D-1.

**Acceptance Criteria:**
- Given une machine dont le Homeport annonce `"metrics"` dans `features`, when l'onglet
  Métriques s'ouvre, then quatre cartes (CPU, RAM, disque, température) rendent leur courbe en
  Swift Charts avec un sélecteur de plage 24 h / 7 j / 30 j / 1 an, and changer de plage
  relit la même machine sur la nouvelle plage sans ré-échantillonner localement.
- Given une plage dont l'historique couvre une période où la console était fermée, when la
  fenêtre est servie, then les points de cette période sont tracés — la donnée vient du Pi, le
  Mac n'en persiste rien (AD-6/FR8).
- Given une machine dont le Homeport ne sert pas l'API ou pas la surface `metrics`, when
  l'onglet s'ouvre, then un empty-state explicatif portant une action « Go to Updates »
  s'affiche — jamais un message d'erreur (UX-DR5).
- Given une machine qui ne répond pas alors que des courbes sont déjà affichées, when la
  lecture échoue, then les courbes restent à l'écran sous une bannière « injoignable » portant
  l'heure de dernière lecture, distincte de l'état « non disponible ».
- Given `hpm metrics <machine> --range 7d` sur une machine servie, when la commande s'exécute,
  then l'en-tête annonce la plage, le pas et les bornes servis, and la table mono liste les
  mêmes valeurs que l'onglet, du plus récent au plus ancien.
- Given `hpm metrics <machine> --range 3h`, when la commande s'exécute, then elle échoue en
  nommant les quatre plages acceptées, sans appel réseau.
- Given l'ensemble du dépôt après la story, when `swift test` et
  `bash Scripts/verify-app-build.sh` s'exécutent, then les deux réussissent et aucun test
  préexistant ne régresse.

## Spec Change Log

## Review Triage Log

## Design Notes

**Pourquoi la grille servie fait foi.** §7 pose un tableau `range → step_s` mais aussi que
« le serveur aligne `from` et `to` sur des multiples de `step_s` » et que « le client peut
calculer la longueur lui-même ». La validation est donc de **cohérence interne** — `to > from`,
`step_s > 0`, `(to - from) % step_s == 0`, et chaque série connue de longueur exactement
`(to - from) / step_s` — jamais une comparaison à 60/300/3600/86400 en dur. Une grille
incohérente est un corps qui n'est pas celui du contrat : §8 range ce cas avec « surface
annoncée mais discordante », donc `surfaceNotServed`, jamais une panne. C'est le trou que
DW/2.2a signalait comme appartenant à cette story.

**Pourquoi un 400 mène à Updates.** Le client n'envoie jamais que les quatre valeurs
documentées. Un 400 signifie donc que le serveur ne connaît pas une plage de la v1 : §8 interdit
de réessayer à l'identique et d'invalider quoi que ce soit, et le remède est une mise à jour du
Pi — pas une intervention sur la machine. `surfaceNotServed` est le seul état qui dit ça.
`unreachable` serait faux : il ferait réessayer indéfiniment.

**Pourquoi la segmentation des `null` est une fonction pure.** Swift Charts relie deux
`LineMark` consécutifs même si les points intermédiaires ont été omis — la courbe traverserait
alors le trou, ce que §7 interdit explicitement (« un `null` ne s'interpole pas : une courbe
s'interrompt là »). La parade est de donner à chaque suite contiguë de points mesurés sa propre
valeur de `series:`. Découper la série est décidable, donc ça vit dans `HomePortKit` et c'est
testé ; la vue ne fait que boucler dessus.

```swift
// forme attendue — chaque run porte son index de grille, l'instant se recalcule
// avec la grille servie et rien d'autre
let runs = window.cpu.segments          // [[(index: Int, value: Double)]]
ForEach(Array(runs.enumerated()), id: \.offset) { run in
    ForEach(run.element, id: \.index) { point in
        LineMark(x: .value("t", window.timestamp(at: point.index)),
                 y: .value("v", point.value),
                 series: .value("run", run.offset))
    }
}
```

**Pourquoi `hpm metrics` imprime toute la grille.** L'epic exige que la jumelle CLI offre « le
même contenu que l'onglet correspondant », et l'AC de la story dit « les valeurs s'affichent en
table mono ». Une table de synthèse (courant/min/max) serait un contenu *différent* de la
courbe. La commande imprime donc une ligne par point de grille — 1 440 à 24 h, 365 à 1 an —
et n'invente pas d'option `--limit` que l'AC ne nomme pas. L'en-tête (`range`, `step`, bornes,
nombre de points) rend le volume prévisible avant de dérouler.

**Pourquoi l'epoch reste en mémoire.** AD-6 réserve `hpm.db` aux curseurs et marqueurs des
événements ; les métriques n'ont ni l'un ni l'autre. Un changement de génération entre deux
lectures d'une même session est détecté en comparant à l'epoch de la dernière lecture réussie
gardée dans la `MetricsFeed` — ce qui suffit à ne pas raccorder deux historiques étrangers à
l'écran, sans créer d'état durable.

## Verification

**Commands:**
- `swift test` -- expected: toutes les suites passent, dont les trois nouvelles ; aucun test
  préexistant ne régresse (316 tests au commit de base).
- `bash Scripts/verify-app-build.sh` -- expected: rc 0. C'est la **seule** commande qui compile
  `App/Sources` : `swift test` ne compile que le graphe SwiftPM et laisserait passer une erreur
  de `MetricsTabView`.
- `./Scripts/render-probe/run.sh 1040 /tmp/metrics-wide.png` puis
  `./Scripts/render-probe/run.sh 900 /tmp/metrics-narrow.png` (avec `MetricsTabView` monté dans
  `Scripts/render-probe/main.swift`) -- expected: les 4 cartes ont une hauteur non nulle aux
  deux largeurs, la courbe s'interrompt sur les trous, et rien ne déborde à 900 (le minimum de
  la fenêtre).
- `/usr/bin/curl -s "http://raspcorse/api/v1/metrics?range=24h" | head -c 200` -- expected: la
  réponse §7 réelle, pour confronter le décodage à la donnée servie plutôt qu'aux seuls
  fixtures.
- `swift run hpm metrics raspcorse --range 30d | head -20` -- expected: l'en-tête puis la table
  mono à 5 colonnes, du plus récent au plus ancien.

**Manual checks (if no CLI):**
- Confronter la sortie de `hpm metrics raspcorse --range 24h` (nombre de lignes, dernière
  valeur) à ce que la carte CPU affiche comme valeur courante : les deux surfaces lisent la
  même fenêtre et doivent coïncider.
