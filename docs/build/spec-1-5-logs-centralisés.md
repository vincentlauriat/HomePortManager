---
title: '1.5 — Logs centralisés'
type: 'feature'
created: '2026-08-24'
status: 'done'
baseline_revision: 'a359184207f355a0c6af398bcb17c136fa788f63'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/docs/build/epic-1-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      La machine à états des sessions de log côté app (followEnabled, interrupted,
      activate/deactivate/suspendForWindow/resumeAfterWindow, reset du buffer au
      changement de mode, arrêt avant retrait dans prune) n'a aucune vérification
      exécutable.
    evidence: |-
      Quatrième story consécutive sous le même parapluie (DW-7, DW-10) : Package.swift ne
      déclare que HomePortKitTests et App/project.yml une seule target application, donc
      Tests/ ne peut pas importer App/Sources. Supprimer la boucle `session.stop()` de
      LogSessionStore.prune, ou le `session.deactivate()` du onDisappear, laisse
      `swift test` entièrement vert tout en laissant un `ssh journalctl -f` orphelin.
      Piste : extraire l'état de cycle de vie (active/followEnabled/suspended + compteur
      d'arrêts) en type HomePortKit, la vue ne gardant que le câblage SwiftUI — la même
      opération que LogLines.swift a faite pour le buffer et le filtre.
    location: >-
      App/Sources/LogsTabView.swift
    severity: medium
  - summary: >-
      Les lignes d'erreur du log-viewer ne sont distinguées que par la couleur, ce qui
      contredit le plancher d'accessibilité de l'epic.
    evidence: |-
      rebuild() applique Theme.semanticCritical au run et rien d'autre ; l'epic exige que
      « la couleur ne soit jamais seule porteuse d'état », mais le token log-viewer de
      DESIGN.md:291 ne prévoit que la teinte, et l'AC de la story la nomme explicitement.
      Tension réelle entre deux sources, à trancher hors du périmètre de cette story. Le
      choix d'un seul Text (imposé par la sélection multi-ligne de l'AC) fait aussi de tout
      le viewer un unique élément VoiceOver sans libellé par ligne.
    location: >-
      App/Sources/LogsTabView.swift
    severity: low
  - summary: >-
      Sur une machine injoignable, l'onglet traverse brièvement l'empty-state « No log
      lines » avant de basculer sur « Unreachable ».
    evidence: |-
      runFollow met loading = false dès que startLogFollow retourne, c'est-à-dire dès que
      le ssh local est lancé et avant tout établissement de connexion ; le verdict n'arrive
      qu'à la fin du stream. Garder loading vrai jusqu'à la première ligne rouvrirait le
      spinner infini sur une unité silencieuse : le correctif propre demande une grâce
      temporisée dans un chemin déjà concurrent, disproportionnée pour un état transitoire
      dont l'état final est correct.
    location: >-
      App/Sources/LogsTabView.swift
    severity: low
  - summary: >-
      `LogsCmd` code en dur la chaîne « homeport.service » au lieu de lire `RemotePaths.unit`,
      seule source de vérité du nom d'unité.
    evidence: |-
      Pré-existant : `LogsCmd` n'est pas touché par cette story (AC 4 est une contrainte de
      préservation). Mais le kit expose désormais deux chemins qui, eux, lisent
      `RemotePaths.unit` (`logs`, `followLogs`), tandis que la branche `-f` du CLI interpole sa
      propre chaîne. Renommer l'unité côté déploiement laisserait `hpm logs -f` cibler
      silencieusement une unité inexistante, et aucun test n'exécute la couche CLI (DW-1,
      DW-6). Correctif d'une ligne, mais il touche le CLI : hors périmètre d'une story dont
      l'AC 4 exige que `Sources/hpm/Commands.swift` ne soit pas modifié.
    location: >-
      Sources/hpm/Commands.swift:274
    severity: low
---

<intent-contract>

## Intent

**Problem:** L'onglet Logs de la fiche machine n'est encore qu'un placeholder (`MachineTab.pendingMessage` renvoie « … arrive avec la story 1.5 ») : diagnostiquer une machine impose d'ouvrir la fenêtre menubar « Logs » (dernières lignes, rechargement manuel, ni suivi, ni filtre, ni distinction des erreurs) ou un terminal SSH (FR4, CAP-4).

**Approach:** Poser dans HomePortKit la moitié testable de la capacité — classification pure d'une ligne d'erreur, découpage incrémental d'un flux en lignes, filtre texte, et un suivi continu porté par les owners existants (`ProcessRunner` gagne un mode flux, `SSHClient` l'expose, `Manager+Service` le commande) — puis remplir l'onglet Logs avec un log-viewer mono à sélection continue, suivi continu commutable, ré-épinglage bas de page et filtre ⌘F, dont l'état vit dans un magasin par machine possédé par la fenêtre, comme le cache Dashboard de 1.4.

## Boundaries & Constraints

**Always:**
- **Deux notions distinctes, jamais confondues.** `followEnabled` est l'intention utilisateur : elle **possède le cycle de vie du process ssh** (activée → un flux tourne ; désactivée → le process est arrêté, le buffer reste). `pinnedToBottom` ne gouverne **que l'auto-scroll** : le flux continue de tourner et les lignes continuent d'arriver quand l'utilisateur remonte. « Reprendre le suivi » ré-épingle et redescend — il ne redémarre aucun process.
- **Le buffer est toujours le produit d'exactement une commande distante**, jamais un recollage : suivi activé → `journalctl … -n <tail> -f` **remplace** le buffer (journalctl sert l'historique puis suit, comme `tail -n N -f`) ; suivi désactivé ou « Rafraîchir » → `logs(on:lines:)` one-shot **remplace** le buffer. Aucune déduplication, aucun raisonnement sur les trous.
- **Auto-scroll conditionné à la position, jamais à l'origine du scroll** : à chaque lot reçu, si `pinnedToBottom` → défiler en bas ; sinon ne rien faire. `pinnedToBottom` est dérivé d'une seule mesure de géométrie (l'ancre de fin est-elle visible, à ~12 pt près) — il n'existe aucun drapeau distinguant scroll programmatique et scroll utilisateur.
- **La classification d'erreur est une fonction pure du kit**, insensible à la casse, à frontières de mot (délimiteurs = tout sauf `[A-Za-z0-9_]`), sur la liste de jetons figée `error, errors, failed, failure, failing, fatal, critical, panic, segfault, traceback, exception` ; une occurrence immédiatement précédée du mot `no` ou `0` ne compte pas (`no errors`, `0 errors found`). `errno` et `error_log` ne matchent pas, par frontière de mot.
- **Cycle de vie du flux, écrit comme invariant faute de test possible** : `stop()` idempotent, appelé depuis `deinit`, depuis `LogSessionStore.prune(keeping:)` et depuis `AsyncStream.onTermination` ; `readabilityHandler` remis à `nil` **avant** `terminate()`/fermeture des handles ; `terminationHandler` termine la continuation. Aucun `ssh` ne survit à la machine retirée de `fleet.yaml`, ni à l'onglet quitté.
- **Le flux ne tourne que tant que l'onglet est visible** : `onDisappear` arrête le process et conserve buffer, filtre et `followEnabled` ; `onAppear` redémarre le flux si `followEnabled`. Le magasin par machine est possédé par `ControlCenterView` en `@StateObject` et purgé dans le `onChange` des noms existant — même doctrine que `DashboardWebCache`.
- **Défauts figés** : suivi **actif** à l'ouverture (`EXPERIENCE.md:93` décrit l'onglet en train de suivre), `tail` initial **200** lignes, buffer plafonné à **1000** lignes (les plus anciennes tombent), lots de lignes publiés au plus toutes les **0,3 s**. Le plafond porte sur le **buffer**, le filtre sur le **rendu**.
- Rendu au token `log-viewer` (surface `Theme.surfaceSoft`, `Theme.data` mono, `Theme.Rounded.md`, padding 12) en **un seul** `Text(AttributedString)` — la sélection et la copie doivent traverser les lignes — les lignes d'erreur portant `Theme.semanticCritical` sur leur run.
- ⌘F focalise le champ de filtre de l'onglet via `ControlCenterCommands.handling(.focusFilter, …)` enregistré à l'apparition et retiré à la disparition ; le filtre s'applique identiquement à l'historique et au flux.
- Toutes les nouvelles chaînes app en en/fr/zh-Hans dans `Localizable.xcstrings` (clé = texte source anglais) ; **réutiliser** `Retry`, `Unreachable`, `%@ is unreachable. Check Tailscale or retry.`, `Refresh`, `Clear the filter`, `Loading…` qui existent déjà, et **supprimer** la clé placeholder `Centralized logs, continuous follow and text filter arrive with story 1.5.`. Le contenu produit par la machine (lignes de journal, message d'erreur) n'est jamais traduit et reste mono.
- Empty-states guidants, jamais une page d'erreur : lecture impossible → titre + détail machine en mono + « Réessayer » ; journal vide → empty-state ; filtre sans correspondance → empty-state + « Clear the filter ».

**Block If:**
- Satisfaire un critère exigerait de changer le format de sortie distant (`journalctl -o json`, `-o short-iso`, `-p err`) : le CLI et l'app partageraient alors deux commandes divergentes pour une même capacité, ce qui touche AD-2/AD-13 et se décide en amont.
- Le suivi continu exigerait un tty distant ou une session ssh persistante partagée entre actions — le multiplexage ssh est une décision d'architecture, pas un détail d'implémentation.

**Never:**
- **Ne pas toucher à `LogsCmd`** : l'AC 4 est une contrainte de préservation, et aucun test n'exécute la couche CLI (DW-1, DW-6) — une régression y serait structurellement invisible dans ce run non assisté. Pas de `streamLogsToTerminal`, pas de déplacement du `Process` tty dans le kit.
- Pas de modification de `App/Sources/LogsWindow.swift` ni de l'entrée menubar « Show logs » : elles restent telles quelles, la story ne les remplace pas.
- Pas de seconde clé ATS, pas de `URLSession`/`HomeportAPIClient`, pas de surface epic 2 (événements, métriques, curseurs) ; pas d'écriture dans `hpm.db` — lire des logs n'est ni journalisé ni verrouillé.
- Pas de modification de `docs/build/sprint-status.yaml` (propriété de l'orchestrateur), ni des invariants 1.2/1.3/1.4.
- Pas de `LazyVStack` de `Text` par ligne : la sélection croisée exigée par l'AC 1 y est impossible. Si `Text(AttributedString)` ne tenait pas la couleur par run **et** la sélection multi-ligne sur macOS 13, le repli nommé est `NSTextView` dans un `NSScrollView`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Ouverture nominale | machine joignable, onglet Logs ouvert | `journalctl -u homeport.service -n 200 -f --no-pager` en flux ; les 200 dernières lignes s'affichent puis les nouvelles arrivent ; les lignes d'erreur sont teintées `semantic-critical` | Aucune |
| Suivi désactivé | bascule « Follow » sur off | Le process ssh est arrêté ; le buffer affiché reste tel quel | Aucune |
| Suivi réactivé | bascule sur on | Un nouveau `-n 200 -f` démarre et **remplace** le buffer | Aucune |
| Remontée pendant le suivi | l'utilisateur défile vers le haut | L'auto-scroll se suspend, « Reprendre le suivi » apparaît ; le flux continue et le buffer continue de grandir | Aucune |
| Reprise du suivi | clic sur « Reprendre le suivi » | `pinnedToBottom` repasse à vrai et la vue redescend en bas | Aucune |
| Filtre saisi | ⌘F puis `mqtt` | Seules les lignes contenant `mqtt` (insensible à la casse) s'affichent, y compris celles qui arrivent ensuite | Aucune |
| Filtre sans correspondance | filtre `zzz`, buffer non vide | Empty-state + « Clear the filter » | Aucune |
| Machine injoignable | ssh échoue au démarrage du flux ou du one-shot | Empty-state « injoignable » + « Réessayer » ; le détail d'erreur reste en mono | `HPMError` capturée, jamais propagée à l'UI |
| Journal vide | commande réussie, sortie vide | Empty-state « aucune ligne » | Aucune |
| Flux coupé en vol | ssh meurt (réseau perdu) | Le suivi s'arrête, le buffer déjà reçu reste affiché, « Réessayer » proposé | Code de sortie non nul rapporté en détail mono |
| Ligne coupée entre deux lots | un chunk se termine au milieu d'une ligne | La ligne n'est émise qu'une fois complète, jamais en deux moitiés | Aucune |
| Buffer saturé | plus de 1000 lignes reçues | Les plus anciennes tombent, le compte reste à 1000 | Aucune |
| Machine retirée | machine supprimée de `fleet.yaml` pendant que sa session existe | Session purgée et process arrêté au `reloadFleet` suivant | Aucune |

</intent-contract>

## Code Map

- `Sources/HomePortKit/ProcessRunner.swift` (`:18-25` protocole, `:27-60` `DefaultProcessRunner`) — owner unique de l'exécution locale (AD-2). Y ajouter l'exigence `stream(_:_:stdin:) throws -> ProcessOutputStream` **avec** une implémentation par défaut en extension qui lève `HPMError` (les doubles de test qui ne streament pas restent valides), et l'implémentation réelle dans `DefaultProcessRunner` (écrire puis fermer stdin, `readabilityHandler` alimentant un `LineSplitter`, `terminationHandler` terminant la continuation).
- `Sources/HomePortKit/ProcessOutputStream.swift` — **à créer** : `public final class ProcessOutputStream { public let lines: AsyncStream<String>; public func stop() }`, construit depuis un `AsyncStream` + une fermeture d'arrêt, de sorte qu'un double de test puisse en fabriquer un depuis un tableau de lignes.
- `Sources/HomePortKit/LogLines.swift` — **à créer** : `LogLine` (`id: Int` monotone, `text`, `isError`), `logLineIsError(_:)` (jetons + frontières de mot + garde `no`/`0`), `LineSplitter` (struct mutable : `push(_ chunk:) -> [String]`, `flush() -> String?`), `splitLogLines(_:)`, `filterLogLines(_:matching:)`, et les défauts `LogDefaults.tail = 200` / `LogDefaults.bufferCap = 1000`. Modèle des helpers purs du kit : `fleetRows` (`FleetRow.swift`), `machineIssues` (`MachineIssue.swift`), `dashboardURL` (`Dashboard.swift`).
- `Sources/HomePortKit/SSHClient.swift` (`:19-30` `run`) — owner de l'accès distant. Ajouter `stream(on:_:sudo:) throws -> ProcessOutputStream` calqué sur `run` : mêmes `batchOptions`, même chemin `sudo bash -s` par stdin. Ne pas modifier `run`.
- `Sources/HomePortKit/Manager+Service.swift` (`:5-14` `logs`) — ajouter `followLogs(on:lines:) throws -> ProcessOutputStream` → `journalctl -u \(RemotePaths.unit) -n \(lines) -f --no-pager`, `sudo: true`, exactement le format de sortie du `logs()` existant. `logs()` reste inchangé (le CLI et `FleetModel.fetchLogs` l'appellent).
- `Sources/hpm/Commands.swift` (`:262-281` `LogsCmd`) — **lecture seule, ne pas modifier** : la parité CLI est déjà acquise, l'AC 4 est une exigence de préservation.
- `App/Sources/LogsTabView.swift` — **à créer** : `LogSessionStore` (`ObservableObject`, `entry(for:)`, `prune(keeping:)`), `LogSession` (`@MainActor` `ObservableObject` : buffer, filtre, `followEnabled`, `pinnedToBottom`, `loading`, `failure`, `activate/deactivate/setFollow/refresh/stop`), `LogsTabView` + le log-viewer. Structure jumelle de `App/Sources/DashboardTabView.swift` (`:12-170` cache par machine + `prune`, `:172-235` vue et gardes) — la relire avant d'écrire.
- `App/Sources/ControlCenterWindow.swift` (`:148-151` `@StateObject webCache`, `:178-186` `onChange(model.machines.map(\.name))`, `:242-247` construction de `MachineDetailView`) — posséder le `LogSessionStore` au même endroit et le purger dans le même `onChange`.
- `App/Sources/MachineDetailView.swift` (`:31-42` `pendingMessage`, `:47-56` propriétés, `:76-88` corps, `:195-202` `content`) — recevoir le magasin, `.logs` → `pendingMessage` `nil`, et généraliser `if tab == .dashboard` en un prédicat (ex. `MachineTab.fillsSheet`) couvrant `.dashboard` et `.logs` : l'onglet Logs défile dans son propre viewer et ne doit pas être imbriqué dans la `ScrollView` de la fiche.
- `App/Sources/FleetOverviewView.swift` (`:42-52` enregistrement `.focusFilter`, `:72-89` `filterField`) — le patron exact du champ filtre et du câblage ⌘F à reproduire.
- `App/Sources/DesignComponents.swift` (`:444-478` `EmptyStateView` avec `detail`/`actionTitle`/`action`, `:107` `PillButtonStyle`) — couvre les trois empty-states et les boutons sans nouveau composant.
- `App/Sources/Theme.swift` (`:22` `surfaceSoft`, `:30` `semanticCritical`, `:51` `Rounded.md`, `:98` `data`) — les tokens du `log-viewer` d'`ux-designs/…/DESIGN.md:175-180`.
- `App/Sources/Localizable.xcstrings` — catalogue manuel en/fr/zh-Hans, `extractionState: manual`, `state: translated` sur chaque unité.
- `Tests/HomePortKitTests/MockProcessRunner.swift` — y ajouter la surcharge `stream(…)` (lignes scriptées + enregistrement de l'appel), sans quoi la plomberie de suivi n'a aucune couverture.
- `Tests/HomePortKitTests/LogLinesTests.swift`, `Tests/HomePortKitTests/LogFollowTests.swift` — **à créer**.
- Références : `docs/specs/epics.md:224-247` (les 4 AC), `ARCHITECTURE-SPINE.md` AD-1/AD-2 (owners uniques), AD-13 (parité CLI), `EXPERIENCE.md:54` et `:93` (UX-DR8, suivi actif), `DESIGN.md:291` (`log-viewer`). L'app n'a aucun target de tests (parapluie DW-7/DW-10) : la couche vue reste sans vérification exécutable.

## Tasks & Acceptance

**Execution:**
- `Sources/HomePortKit/LogLines.swift` — créer les types et fonctions pures (classification, `LineSplitter`, découpage, filtre, défauts) — c'est toute la logique de la story qui se teste par `swift test`.
- `Sources/HomePortKit/ProcessOutputStream.swift` — créer le porteur de flux (`lines`/`stop`), constructible depuis un `AsyncStream` quelconque — pour que le double de test n'ait pas besoin d'un vrai process.
- `Sources/HomePortKit/ProcessRunner.swift` — ajouter `stream(…)` au protocole, son défaut qui lève, et l'implémentation `DefaultProcessRunner` respectant les invariants de cycle de vie — un `ssh` orphelin est le mode de panne principal de cette story.
- `Sources/HomePortKit/SSHClient.swift` — exposer `stream(on:_:sudo:)`, mêmes options que `run` — AD-2 : un seul owner de l'accès distant.
- `Sources/HomePortKit/Manager+Service.swift` — ajouter `followLogs(on:lines:)`, format de sortie identique à `logs()` — même commande distante, deux modes.
- `Tests/HomePortKitTests/MockProcessRunner.swift` — surcharger `stream(…)` : rejouer des lignes scriptées et enregistrer l'appel.
- `Tests/HomePortKitTests/LogLinesTests.swift` — couvrir la matrice pure : classification positive (`ERROR`, `Failed to start`, `panic:`), négative (`no errors`, `0 errors found`, `errno`, `error_log`, ligne ordinaire), casse mixte ; `LineSplitter` (ligne coupée entre deux chunks, CRLF, chunk sans saut final, `flush`) ; découpage (entrée vide, saut final unique) ; ids monotones ; plafond du buffer ; filtre (insensible à la casse, filtre vide, filtre espacé, aucune correspondance).
- `Tests/HomePortKitTests/LogFollowTests.swift` — épingler la commande émise par `followLogs` (unité, `-n`, `-f`, `--no-pager`, `sudo`, `BatchMode=yes`) et la consommation du flux jusqu'à sa fin via le mock.
- `App/Sources/LogsTabView.swift` — créer le magasin, la session et la vue : viewer `Text(AttributedString)`, bascule « Follow », champ filtre ⌘F, bouton « Resume follow », trois empty-states, et les invariants de cycle de vie — le cœur de FR4 et d'UX-DR8.
- `App/Sources/ControlCenterWindow.swift` — posséder le `LogSessionStore` en `@StateObject`, le passer à `MachineDetailView`, le purger dans le `onChange` des noms.
- `App/Sources/MachineDetailView.swift` — recevoir le magasin, retirer le `pendingMessage` de `.logs`, router `.logs` vers `LogsTabView` hors de la `ScrollView` de la fiche.
- `App/Sources/Localizable.xcstrings` — ajouter les nouvelles clés en/fr/zh-Hans (`Follow`, `Resume follow`, placeholder et libellés d'empty-state) et **supprimer** la clé placeholder de la story 1.5 — aucune chaîne en dur, aucun orphelin.

**Acceptance Criteria:**
- Given une machine sélectionnée, when Vincent ouvre l'onglet Logs, then les dernières lignes du journal s'affichent en mono dans le log-viewer, sélectionnables et copiables **d'une ligne à l'autre en une seule sélection**, le suivi continu est actif et commutable, et les lignes d'erreur sont teintées `semantic-critical`.
- Given le suivi continu actif, when Vincent défile vers le haut, then l'auto-scroll se suspend et un bouton « Reprendre le suivi » apparaît, sans que le flux ne s'arrête ; cliquer le bouton redescend en bas et ré-épingle.
- Given un filtre saisi via ⌘F, when de nouvelles lignes arrivent, then seules les lignes correspondantes s'affichent, aussi bien dans l'historique déjà chargé que dans le flux, et vider le filtre restitue tout le buffer.
- Given `hpm logs <machine>` et `hpm logs <machine> -f`, when ils sont exécutés après cette story, then leur comportement est inchangé — `Sources/hpm/Commands.swift` n'est pas modifié et `logs(on:lines:)` garde sa signature et sa sortie.
- Given l'app basculée en fr ou zh-Hans, when l'onglet Logs et ses empty-states s'affichent, then libellés, placeholder et boutons sont traduits, et les lignes de journal comme les détails d'erreur restent en mono non traduits.

## Spec Change Log

## Review Triage Log

### 2026-08-24 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 10: (high 0, medium 6, low 4)
- defer: 3: (high 0, medium 1, low 2)
- reject: 21: (high 0, medium 4, low 17)
- addressed_findings:
  - `[medium]` `[patch]` `ProcessFollow.processTerminated` drainait les deux pipes *avant* de vérifier `finished` : `stop()` ayant déjà fermé les handles, le `terminationHandler` lisait deux descripteurs fermés. La revendication de `finished` passe désormais avant les `readToEnd`.
  - `[medium]` `[patch]` Aucun keepalive sur le ssh de suivi : un lien tailnet qui tombe silencieusement ne fait jamais sortir le ssh local, donc `interrupted` ne devient jamais vrai et l'onglet affiche un suivi vivant mais gelé. `ServerAliveInterval=15`, `ServerAliveCountMax=3` et `ConnectTimeout=10` ajoutés au **seul** chemin `SSHClient.stream` — `run`, donc le CLI et toutes les actions, reste intact ; test dédié qui épingle les deux faces.
  - `[medium]` `[patch]` Le bouton « Reprendre le suivi » apparaissait aussi quand le suivi était coupé, où il ne nomme aucune action existante. Il est désormais conditionné à `followEnabled` (libellé conservé : l'AC 2 l'impose).
  - `[medium]` `[patch]` `LogSession` n'avait pas de `deinit` : une session relâchée sans `prune`/`deactivate` laissait sa tâche et son flux vivants. `deinit` annule la tâche et stoppe le flux.
  - `[medium]` `[patch]` La reconstitution d'un caractère multi-octets coupé entre deux lectures de pipe n'était couverte par aucun test (tous les tests de flux étaient ASCII) : supprimer `carry` laissait la suite verte. Test ajouté avec un `é` coupé entre deux écritures.
  - `[medium]` `[patch]` Le filet `onTermination`/`deinit` — un flux simplement lâché doit tuer l'enfant — n'était exercé par aucune assertion : les deux lignes pouvaient être supprimées sans qu'un test bronche. Test ajouté qui laisse le flux sortir de portée sans `stop()` et observe la mort du pid.
  - `[low]` `[patch]` `MachineDetailView.fullTab` renvoyait `DashboardTabView` dans un `default:` : tout futur onglet passant `fillsSheet` à vrai aurait silencieusement affiché la WebView du dashboard. Tous les cas sont désormais nommés.
  - `[low]` `[patch]` Le doc-comment de `LogDefaults` affirmait que « le CLI, l'app et les tests lisent les mêmes nombres », ce qui est faux : `logs(on:lines:)` garde 50 et `hpm logs` son `-n 50`. Le commentaire dit maintenant la vérité (défauts de l'onglet, préservation délibérée du CLI) et un test épingle la divergence pour qu'« aligner les défauts » se lise comme un changement de comportement CLI, pas comme un nettoyage.
  - `[low]` `[patch]` `followLogs` interpolait un tail non contrôlé : `max(1, lines)` évite un argument que journalctl refuserait.
  - `[low]` `[patch]` La branche non-sudo de `SSHClient.stream` n'était exercée par rien (`followLogs` demande toujours sudo). Test ajouté.

### 2026-08-24 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 5: (high 0, medium 3, low 2)
- defer: 1: (high 0, medium 0, low 1)
- reject: 31: (high 0, medium 7, low 24)
- addressed_findings:
  - `[medium]` `[patch]` Un `AsyncStream` livre encore ce qu'il avait tamponné après `finish()` : la boucle `for await` de `runFollow` n'ayant aucune vérification d'annulation, un suivi remplacé pouvait déposer les lignes de la commande précédente dans le buffer de la nouvelle — l'invariant « un buffer = exactement une commande distante » tombait. `guard !Task.isCancelled else { break }` ajouté dans la boucle.
  - `[medium]` `[patch]` `ProcessFollow.launch` écrivait le script sudo avec `FileHandle.write(_:)`, qui lève une exception Objective-C non rattrapable : un ssh mort avant d'avoir lu son stdin (connexion refusée) faisait sortir l'app entière sur EPIPE. Remplacé par la forme lançante `try? write(contentsOf:)` — la panne devient un flux qui se termine.
  - `[medium]` `[patch]` L'argv de `SSHClient.stream` n'était vérifié que par appartenance (`contains`), jamais par position, alors que `ssh` lit ses options avant l'hôte et traite le premier argument non-option comme l'hôte. Regrouper le tableau autrement gardait la suite verte tout en produisant un suivi incapable de se connecter. `testStreamArgumentsAreOrderedAsSSHExpects` épingle désormais le tableau complet des deux branches, comme `SSHClientTests` le fait déjà pour le one-shot.
  - `[low]` `[patch]` `MachineTab.fillsSheet` répondait par un `default:`, ce qui annulait la protection revendiquée par le commentaire de `fullTab` : un onglet ajouté à l'enum n'aurait jamais été routé vers le `switch` exhaustif censé le faire échouer visiblement. Tous les cas sont nommés, dans les deux switches.
  - `[low]` `[patch]` Les boutons « Follow » et « Refresh » écrasaient leur libellé visible par un `accessibilityLabel` long, ce qui retire de Voice Control la commande vocale correspondant au texte affiché. Les deux chaînes restent portées par `.help`, où elles ont leur place ; aucune clé de localisation n'est devenue orpheline.


### 2026-08-24 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 3: (high 0, medium 2, low 1)
- defer: 0
- reject: 38: (high 0, medium 9, low 29)
- addressed_findings:
  - `[medium]` `[patch]` Aucun chemin d'arrêt ne couvrait la sortie de l'app : `NSApp.terminate` ne déclenche ni `onDisappear`, ni `willClose`, ni aucun `deinit`, et un enfant `ssh` est réattribué à launchd plutôt que tué. Un suivi sur une unité silencieuse n'écrit rien, ne prend donc jamais le SIGPIPE de la fermeture de notre bout de pipe, et survit à l'app tant que le journal se tait. `LogSessionStore` observe désormais `NSApplication.willTerminateNotification` et arrête toutes ses sessions de façon synchrone (`stopAll()`).
  - `[medium]` `[patch]` `followLogs` n'était inscrit dans aucun des deux rôles de classification AD-16, alors que l'`<intent-contract>` exige explicitement que lire des logs ne soit « ni journalisé ni verrouillé ». L'envelopper dans `journaled("logs", locking: true)` laissait les 225 tests verts : `testPureReadsNeverJournal` ne l'appelait pas, `testNonLockingActionsRunDespiteAForeignLock` ne le listait pas, et `LogFollowTests` monte son manager sans `HistoryStore`. Les deux tests l'appellent maintenant.
  - `[low]` `[patch]` Les `readabilityHandler` des deux pipes retournaient sans se désarmer sur une lecture vide, c'est-à-dire sur l'EOF : Foundation garde le handler armé et le refait tirer sur un descripteur qui ne rendra plus rien, faisant tourner une file dispatch jusqu'à ce que `terminationHandler` s'exécute. Ils se mettent désormais à `nil` sur EOF ; le drain de `processTerminated` reste la source des dernières lignes.


## Design Notes

**Le CLI ne bouge pas, et c'est un choix.** L'AC 4 demande la préservation, pas la refactorisation. `LogsCmd` garde son chemin tty (`ssh -t`) parce que le Ctrl-C interactif en dépend, et parce qu'aucun test n'exécute la couche CLI (DW-1, DW-6) : une régression y serait invisible pour `swift build` comme pour `swift test`. Déplacer ce `Process` dans le kit relocaliserait la dérogation à AD-2 sans la corriger — il contournerait toujours `SSHClient`. Le nouveau chemin `stream` est du code neuf pour l'app, et lui passe bien par les owners nommés.

**Heuristique de texte plutôt que `PRIORITY` journald.** `journalctl -o json` donnerait la sévérité faisant autorité, mais imposerait à l'app une commande distante et un format différents de ceux du CLI pour la même capacité — deux vérités pour une teinte. La liste de jetons est donc figée dans le kit, à frontières de mot, avec la garde `no`/`0` contre `no errors` et `0 errors found`, et elle est testée dans les deux sens.

**Une seule commande par buffer.** `journalctl -n 200 -f` sert l'historique **puis** suit : lancer un one-shot puis un flux `-n 200 -f` produirait 200 doublons. D'où l'invariant : chaque changement de mode **remplace** le buffer plutôt que de le recoudre.

**Auto-scroll par position, pas par origine.** On ne défile que si l'on était déjà en bas — donc aucun drapeau n'a besoin de distinguer un scroll programmatique d'un scroll utilisateur, et le bouton « Reprendre le suivi » n'a qu'une seule condition d'apparition.

**Pourquoi un seul `Text`.** L'AC exige sélection et copie ; en SwiftUI la sélection ne traverse pas deux `Text`. Un `AttributedString` unique porte à la fois la couleur par run et une sélection continue. C'est aussi ce qui impose le plafond de 1000 lignes : tout le texte est mis en page, sans lazy rendering.

**Squelette du viewer (5 lignes) :**
```swift
ScrollViewReader { proxy in
    ScrollView { VStack(alignment: .leading, spacing: 0) {
        Text(attributed).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        Color.clear.frame(height: 1).id(Anchor.bottom)
            .background(GeometryReader { g in Color.clear.preference(key: BottomKey.self,
                value: g.frame(in: .named(Anchor.space)).maxY) })
    } }.coordinateSpace(name: Anchor.space)
}
```

## Verification

**Commands:**
- `swift build` — expected: compilation sans erreur.
- `swift test` — expected: suite verte, dont `LogLinesTests` et `LogFollowTests` ; aucune régression.
- `cd App && xcodegen generate && xcodebuild -project HomePortMenu.xcodeproj -scheme HomePortMenu -configuration Debug build CODE_SIGNING_ALLOWED=NO` — expected: `BUILD SUCCEEDED`.
- `git status --porcelain` — expected: seuls les fichiers de la story (le `.xcodeproj` est ignoré par `.gitignore`).

**Manual checks (if no CLI):**
- Fiche d'une machine joignable, onglet Logs : lignes présentes, suivi actif, nouvelles lignes qui arrivent, sélection à la souris traversant plusieurs lignes puis ⌘C.
- Défiler vers le haut : « Reprendre le suivi » apparaît, les lignes continuent d'arriver, le clic redescend.
- ⌘F puis un mot présent : historique et flux filtrés ; vider le filtre restitue tout.
- Machine éteinte : empty-state + « Réessayer », jamais de trace brute.
- Quitter l'onglet puis la fenêtre : `pgrep -fl "ssh .*journalctl"` ne laisse aucun process.
- Basculer en fr/zh-Hans : libellés traduits, lignes de journal inchangées.

## Auto Run Result

Status: done
Blocking condition: aucune

### Changement implémenté

L'onglet Logs de la fiche machine (FR4, CAP-4) n'est plus un placeholder. La moitié testable de
la capacité vit dans HomePortKit — classification pure d'une ligne d'erreur, découpage
incrémental d'un flux en lignes, filtre texte, buffer plafonné à ids monotones — et le suivi
continu passe par les owners existants (`ProcessRunner` gagne un mode flux, `SSHClient`
l'expose avec keepalives, `Manager+Service` le commande). Côté app, un log-viewer mono en un
seul `Text(AttributedString)` (sélection continue d'une ligne à l'autre, lignes d'erreur
teintées `semantic-critical`), suivi commutable, ré-épinglage bas de page, filtre ⌘F, trois
empty-states et un bandeau d'interruption ; l'état vit dans un magasin par machine possédé par
`ControlCenterView`, comme le cache Dashboard de 1.4. `LogsCmd` et `LogsWindow.swift` sont
intacts (AC 4).

### Fichiers modifiés

- `Sources/HomePortKit/LogLines.swift` — créé : `LogLine`, `logLineIsError`, `LineSplitter`, `splitLogLines`, `filterLogLines`, `LogBuffer`, `LogDefaults`.
- `Sources/HomePortKit/ProcessOutputStream.swift` — créé : porteur de flux (`lines`/`stop`/`failure`), constructible depuis un `AsyncStream` quelconque.
- `Sources/HomePortKit/ProcessRunner.swift` — `stream(…)` au protocole, défaut lançant, implémentation `DefaultProcessRunner` + `ProcessFollow` (cycle de vie, décodage UTF-8 à cheval, écriture stdin lançante, handlers désarmés sur EOF).
- `Sources/HomePortKit/SSHClient.swift` — `stream(on:_:sudo:)`, mêmes options que `run` plus les keepalives du seul chemin de suivi.
- `Sources/HomePortKit/Manager+Service.swift` — `followLogs(on:lines:)` : `journalctl -u … -n N -f --no-pager`, sudo, tail borné.
- `App/Sources/LogsTabView.swift` — créé : `LogSessionStore` (purge, `stopAll()` au quit), `LogSession`, `LogsTabView`, `LogViewer`.
- `App/Sources/ControlCenterWindow.swift` — possession et purge du `LogSessionStore`.
- `App/Sources/MachineDetailView.swift` — `fillsSheet` exhaustif, `.logs` routé hors de la `ScrollView` de la fiche, `pendingMessage` retiré.
- `App/Sources/FleetModel.swift` — `startLogFollow` / `logSnapshot`, via la fabrique de manager existante.
- `App/Sources/Localizable.xcstrings` — 10 clés neuves en/fr/zh-Hans, clé placeholder 1.5 supprimée.
- `Tests/HomePortKitTests/` — `LogLinesTests.swift` et `LogFollowTests.swift` créés ; `ProcessRunnerTests.swift`, `MockProcessRunner.swift` et `JournalSeamTests.swift` étendus.

### Revue

Trois passes au total. La dernière a rejoué les quatre couches en parallèle (blind hunter,
edge-case hunter, verification gap, intent alignment) sur le diff depuis
`a359184207f355a0c6af398bcb17c136fa788f63`.

- **Passe 1 : 10 patches** (6 medium, 4 low) — cf. Review Triage Log.
- **Passe 2 : 5 patches** (3 medium, 2 low), 1 report.
- **Passe 3 : 3 patches** — 2 medium (aucun arrêt des flux à la sortie de l'app : un `ssh` suivant une unité silencieuse survivait au quit ; `followLogs` absent des deux rôles de classification AD-16, alors que l'`<intent-contract>` exige « ni journalisé ni verrouillé ») et 1 low (`readabilityHandler` non désarmé sur EOF, boucle de ré-armement jusqu'au `terminationHandler`). 0 report, 38 rejets.
- **Rejets de la passe 3** — pour l'essentiel : des propositions de design hors périmètre (debounce du filtre, cache du verdict de filtre par ligne, escalade SIGKILL, annonce VoiceOver de l'interruption), des comportements que l'`<intent-contract>` prescrit lui-même (« Rafraîchir remplace le buffer », y compris quand la commande échoue ; l'empty-state « injoignable » comme unique état d'échec de lecture, détail machine en mono en dessous), des redites des quatre entrées `deferred` déjà consignées, une objection fausse après lecture du code (`ControlCenterCommands.handling` est un **compteur**, précisément pour l'ordre `onAppear`/`onDisappear` que le rapport supposait cassé), et les fichiers propriété de l'orchestrateur (`sprint-status.yaml`, `deferred-work.md`).

Suivi de revue recommandé : **true** — 0 patch high, 2 medium, 1 low → 3 × 2 + 1 × 1 = 7 ≥ 5.

### Vérification effectuée

- `swift build` → succès, sans erreur.
- `swift test` → **225 tests, 0 échec** (les deux tests de rôle AD-16 étendus, pas de test neuf).
- `cd App && xcodegen generate && xcodebuild -project HomePortMenu.xcodeproj -scheme HomePortMenu -configuration Debug build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`, sans erreur ni warning nouveau.
- Les contrôles manuels de la section `## Verification` (machine joignable, remontée/reprise, ⌘F, machine éteinte, `pgrep`, bascule fr/zh-Hans) **n'ont pas été exécutés** : ce run est non assisté et n'a ni machine de flotte joignable ni session graphique. L'arrêt au quit ajouté dans cette passe est donc raisonné, non observé.

### Risques résiduels

- La machine à états de `LogSession` et toute la couche vue restent sans vérification exécutable (parapluie DW-7/DW-10 : aucun target de tests ne couvre `App/Sources`). Le nouveau `stopAll()` au `willTerminate` tombe sous le même parapluie : il est supprimable sans qu'aucun test bronche. C'est l'entrée `deferred` medium de cette story, et c'est la quatrième story consécutive concernée.
- L'invariant « aucun ssh ne survit à l'onglet » est vérifié côté local (`testDefaultRunnerStreamStopTerminatesTheChild`, `…ReleasedWithoutStopStillKillsTheChild`) ; la mort du `journalctl` **distant** repose sur la sémantique standard de ssh sans tty et n'est constatée par aucun test.
- `NSApplication.willTerminateNotification` ne couvre pas un force-quit ni un crash : un `ssh` de suivi peut encore survivre à ces deux sorties-là.
- `pinnedToBottom` est dérivé d'une mesure de géométrie via `onPreferenceChange` : le seuil de 12 pt n'a pas été éprouvé sur un écran réel.
