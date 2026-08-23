---
title: '1.4 — Dashboard Homeport intégré'
type: 'feature'
created: '2026-08-23'
status: 'done'
baseline_revision: 'a9137057ca0b95af6c2063cec5157aa2d780fb27'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/docs/build/epic-1-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      La machine à états du cache Dashboard (verdict d'échec, garde de
      rechargement, politique de navigation externe, prune) n'a aucune
      vérification exécutable.
    evidence: |-
      Même parapluie pré-existant que DW-7/DW-8 : le target App n'a aucun test
      (Package.swift ne déclare que HomePortKitTests, App/project.yml une seule
      target application). Inverser le filtre NSURLErrorCancelled de fail(_:) ou
      le prédicat de prune(keeping:) laisse `swift test` vert. Piste : extraire
      le réducteur de verdict (fail/didCommit/retry/terminate, filtres de codes)
      en type HomePortKit testable, la WKWebView restant côté app — ou ajouter
      un bundle de tests app au xcodeproj.
    location: >-
      App/Sources/DashboardTabView.swift
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Le dashboard web de chaque Homeport n'est accessible qu'en ouvrant un navigateur à la main — l'onglet Dashboard de la fiche machine n'est qu'un placeholder — et l'app ne porte encore aucune exception App Transport Security : aucun contenu HTTP du tailnet ne peut se charger (FR3, CAP-3).

**Approach:** Poser l'exception ATS unique d'AD-3 dans l'Info.plist généré (partagée `WKWebView` + futur `URLSession` de l'epic 2), dériver l'URL du dashboard (`http://<host>:<port>/`) par un helper pur dans HomePortKit testé par `swift test`, et remplir l'onglet Dashboard avec une `WKWebView` par machine (état conservé entre changements d'onglet et de machine), gardée par les empty-states UX-DR5 : machine injoignable ou chargement échoué → empty-state avec « Réessayer », jamais une page d'erreur WebKit brute.

## Boundaries & Constraints

**Always:**
- **Une seule exception ATS**, déclarée dans `App/project.yml` (`info.properties` → `NSAppTransportSecurity` avec `NSAllowsArbitraryLoads: true`), documentée en commentaire comme l'exception AD-3 partagée par `WKWebView` et le futur client API — aucun contournement par story, aucune clé ATS ailleurs.
- L'URL du dashboard dérive de l'identité déclarée dans `fleet.yaml` : host = partie de `machine.ssh` après le dernier `@` (un `ssh` sans `@` est déjà un host), port = `machine.port`, schéma `http`, chemin `/`. La dérivation est une fonction pure de HomePortKit construite via `URLComponents` (entrée invalide → `nil`, jamais un crash) et couverte par des tests kit.
- La WebView est réellement utilisable (navigation interne, saisie clavier, sélection) et son état survit aux allers-retours d'onglet et de machine dans la fenêtre : une instance `WKWebView` par machine, mise en cache tant que la machine reste déclarée dans `fleet.yaml`, purgée quand elle en sort (même doctrine que les dictionnaires de `FleetModel.reloadFleet`).
- Trois gardes d'affichage, dans cet ordre : URL indérivable → empty-state explicatif sans « Réessayer » (réessayer n'y change rien) ; machine injoignable (`statuses[name]?.reachable == false`) **et** rien encore chargé → empty-state « injoignable » avec « Réessayer » ; échec de navigation WebKit (`didFailProvisionalNavigation`/`didFail`) → empty-state avec « Réessayer » et le détail d'erreur en contenu machine (mono, jamais traduit). Une page déjà chargée reste affichée quand la machine devient injoignable — UX-DR5 conserve les dernières données.
- « Réessayer » relance le chargement de la WebView et déclenche `model.refresh()` — le même geste réactualise le statut et la page.
- UI aux tokens `Theme` et composants existants (`EmptyStateView` avec `actionTitle`/`action`) ; toutes les nouvelles chaînes app en en/fr/zh-Hans dans `Localizable.xcstrings` (clé = texte source anglais) ; ton UX : le fait puis le remède (« %@ is unreachable. Check Tailscale or retry. »).
- `MachineTab.dashboard` perd son `pendingMessage` ; ⌘2 et la pill continuent de fonctionner tels quels.

**Block If:**
- Satisfaire un critère exigerait une exception ATS par domaine ou une seconde clé ATS — AD-3 impose l'exception unique ; en changer la forme est une décision d'architecture.
- Le dashboard exigerait une authentification applicative (le tailnet est l'authentification, AD-14) — tout besoin d'identifiants est un changement de posture de sécurité.

**Never:**
- Pas de client HTTP `URLSession`/`HomeportAPIClient` — l'API Homeport (événements, métriques, capabilities) arrive à l'epic 2 ; cette story ne pose que l'exception ATS qu'il réutilisera.
- Pas de jumelle CLI : la parité de l'epic 1 est close (`hpm tasks`, `hpm unlock`, `hpm logs`) et l'epic n'en exige pas pour CAP-3.
- Pas de barre d'adresse, boutons précédent/suivant, ni ouverture d'URL externes arbitraires ; pas de HTTPS/`tailscale cert` (différé par l'architecture).
- Pas de modification de `docs/build/sprint-status.yaml`, du menubar, ni des invariants 1.2/1.3 (journal, verrou) — afficher le dashboard n'est ni journalisé ni verrouillé (lecture).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Nominal | machine joignable, `ssh: pi@raspyellow`, `port: 8080`, onglet Dashboard ouvert | WebView charge `http://raspyellow:8080/`, navigation interne et saisie fonctionnent | Aucune |
| Host nu | `ssh: raspyellow` (sans `@`) | URL `http://raspyellow:8080/` — le host est pris tel quel | Aucune |
| Injoignable, jamais chargé | `reachable == false`, aucune page en cache WebView | Empty-state « injoignable » + « Réessayer » ; aucun chargement tenté, jamais de page d'erreur WebKit | Aucune |
| Injoignable, déjà chargé | page affichée puis machine perd le réseau | La page chargée reste affichée (dernières données conservées) | Aucune |
| Dashboard muet | machine joignable en SSH mais port web fermé → échec de navigation | Empty-state + « Réessayer », détail d'erreur WebKit en mono (contenu machine) | Erreur interceptée par le delegate, jamais rendue par WebKit |
| Réessayer | clic sur « Réessayer » après échec | Rechargement de l'URL + `model.refresh()` ; succès → dashboard affiché | Nouvel échec → même empty-state |
| URL indérivable | `ssh: ''` ou host que `URLComponents` rejette | Empty-state explicatif sans « Réessayer » | `dashboardURL` retourne `nil`, pas d'exception |
| Changement d'onglet A/R | Dashboard → Logs → Dashboard sur la même machine | Même instance WebView : pas de rechargement, état (scroll, saisie) conservé | Aucune |
| Machine retirée | machine supprimée de `fleet.yaml` pendant que sa WebView est en cache | Instance purgée du cache au `reloadFleet` suivant | Aucune |

</intent-contract>

## Code Map

- `Sources/HomePortKit/FleetStore.swift` (`:4-16`) — `Machine` : `name`, `ssh` (cible ssh `user@host` ou host nu, convention AD « l'identité vient de fleet.yaml pour tous les canaux »), `port: Int` (défaut 80, celui du serveur web Homeport — le healthz `Manager+Doctor.swift:22` interroge `http://localhost:\(machine.port)/healthz`). Ne pas modifier.
- `Sources/HomePortKit/Dashboard.swift` — **à créer** : `public func dashboardURL(for machine: Machine) -> URL?`, pure, via `URLComponents` (schéma `http`, host = suffixe après le dernier `@`, port = `machine.port`, path `/`). Modèle des helpers libres du kit : `fleetRows` (`FleetRow.swift`), `machineIssues` (`MachineIssue.swift`).
- `App/project.yml` (`info.properties`, `:21-28`) — Info.plist est **généré par xcodegen** : l'exception ATS s'ajoute ici (`NSAppTransportSecurity: {NSAllowsArbitraryLoads: true}` + commentaire AD-3), jamais dans un plist édité à la main. Nouveau fichier Swift = `xcodegen generate` suffit (dossier source).
- `App/Sources/MachineDetailView.swift` — `MachineTab.pendingMessage` (`:33-44`) : la branche `.dashboard` passe à `nil` ; `content` (`:195-202`) : router `.dashboard` vers la nouvelle vue (le `if pendingMessage` couvre le reste) ; `summary`/`unreachableNotice` (`:301-317`) montrent le pattern « Réessayer » (`model.refresh()`, `disabled(model.refreshing)`). La vue porte `.id(machine.name)` posé par `ControlCenterView` (`ControlCenterWindow.swift:244-246`) — l'état de la WebView ne peut donc PAS vivre en `@State` ici s'il doit survivre au changement de machine.
- `App/Sources/DashboardTabView.swift` — **à créer** : cache `@MainActor` d'instances `WKWebView` par nom de machine (ObservableObject possédé par `ControlCenterView` en `@StateObject`, passé à `MachineDetailView` ; purge sur `onChange(model.machines.map(\.name))` déjà présent `ControlCenterWindow.swift:177-183`) ; `NSViewRepresentable` enveloppant l'instance cachée ; vue d'onglet appliquant les trois gardes de l'intent (état d'échec publié par le `WKNavigationDelegate`, retenu par machine dans le cache — pas dans la vue, qui est recréée à chaque sélection).
- `App/Sources/FleetModel.swift` — `statuses[name]?.reachable` (`:208` côté vue), `displayStatus` (`:127-131`), `refresh()` (`:171-203`) : tout existe, rien à ajouter au modèle — la story est purement vue + kit.
- `App/Sources/DesignComponents.swift` — `EmptyStateView` (`:444`) accepte déjà `detail:` (mono, sélectionnable) et `actionTitle:`/`action:` (bouton primary) : couvre les trois empty-states sans nouveau composant.
- `App/Sources/Localizable.xcstrings` — catalogue manuel en/fr/zh-Hans ; le placeholder machine s'écrit `%@` dans la clé (modèle : « %@ is unreachable… »).
- `Tests/HomePortKitTests/DashboardURLTests.swift` — **à créer** ; la logique UI app reste sans tests exécutables (parapluie pré-existant DW-7 : aucun target de tests app).
- `docs/specs/epics.md` (`:207-223`) — les deux AC de la story ; `ARCHITECTURE-SPINE.md` AD-3 (exception unique), AD-14 (tailnet = auth), AD-15 (FleetModel source unique d'état).

## Tasks & Acceptance

**Execution:**
- `Sources/HomePortKit/Dashboard.swift` — créer `dashboardURL(for:)` : host après le dernier `@` (host nu accepté), `URLComponents` avec schéma `http`, port `machine.port`, path `/` ; entrée vide ou rejetée par `URLComponents` → `nil` — la seule logique de la story qui se teste par `swift test`, donc dans le kit.
- `Tests/HomePortKitTests/DashboardURLTests.swift` — couvrir la matrice URL : `user@host`, host nu, `user@host` avec port custom, port 80 explicite, `ssh` vide → `nil`, `user@` → `nil`, host à caractères invalides (espace) → `nil` — épingler la forme exacte de l'URL produite.
- `App/project.yml` — ajouter `NSAppTransportSecurity: {NSAllowsArbitraryLoads: true}` sous `info.properties` avec le commentaire AD-3 (exception unique, partagée WKWebView + futur client API) — sans elle, tout chargement HTTP est refusé silencieusement.
- `App/Sources/DashboardTabView.swift` — créer le cache WebView par machine (état de navigation + état d'échec, purgeable), le `NSViewRepresentable` et la vue d'onglet avec les trois gardes (URL indérivable / injoignable jamais chargé / échec de navigation) et « Réessayer » (`reload` + `model.refresh()`) — le cœur de FR3 et d'UX-DR5.
- `App/Sources/ControlCenterWindow.swift` — posséder le cache en `@StateObject` dans `ControlCenterView`, le passer à `MachineDetailView`, purger les instances des machines disparues dans le `onChange` des noms existant — l'état survit aux changements de machine, jamais aux retraits de flotte.
- `App/Sources/MachineDetailView.swift` — accepter le cache, `pendingMessage` de `.dashboard` → `nil`, router `content` vers `DashboardTabView` — l'onglet cesse d'être un placeholder.
- `App/Sources/Localizable.xcstrings` — clés des trois empty-states (titres, messages fait-puis-remède, « Retry » réutilisé s'il existe déjà, sinon créé) en en/fr/zh-Hans — aucune chaîne en dur (UX-DR4).

**Acceptance Criteria:**
- Given une machine dont le dashboard répond sur le tailnet, when Vincent ouvre l'onglet Dashboard de sa fiche, then une WebView charge `http://<host>:<port>/`, la navigation interne et la saisie fonctionnent, et l'accès HTTP passe par l'exception ATS unique d'Info.plist (AD-3) — vérifiable dans le plist généré après `xcodegen generate`.
- Given une machine injoignable sans page déjà chargée, when l'onglet Dashboard s'ouvre, then un empty-state « injoignable » s'affiche avec « Réessayer » — jamais une page d'erreur WebKit brute (UX-DR5) — et « Réessayer » relance chargement et refresh.
- Given une page dashboard affichée, when Vincent passe à l'onglet Logs puis revient, ou sélectionne une autre machine puis revient, then la page n'est pas rechargée et son état est conservé.
- Given l'app basculée en fr ou zh-Hans, when un empty-state Dashboard s'affiche, then titres, messages et bouton sont traduits, le détail d'erreur WebKit reste en mono non traduit.

## Spec Change Log

## Review Triage Log

### 2026-08-23 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 7: (high 0, medium 3, low 4)
- defer: 1: (high 0, medium 1, low 0)
- reject: 9
- addressed_findings:
  - `[medium]` `[patch]` Un `machine.port` négatif faisait lever une exception par le setter `URLComponents.port` — crash contredisant le contrat « pure et totale » — garde `(1...65535)` sinon `nil` + tests (-1/0/65536).
  - `[medium]` `[patch]` Une machine gardant son nom mais changeant de `ssh`/`port` dans fleet.yaml conservait indéfiniment l'ancienne page (`loadIfNeeded` ne renavigue jamais une entrée à `hasContent`) — `Entry` mémorise `requestedURL` et recharge sur écart (reset différé d'un tick : muter un `@Published` pendant `updateNSView` est interdit par SwiftUI).
  - `[medium]` `[patch]` Aucune politique de navigation : un lien externe du dashboard capturait l'utilisateur dans la WebView sans retour possible, contre le « Never » de la spec — `decidePolicyFor` : `.linkActivated` vers un autre host → `.cancel` + navigateur par défaut (`NSWorkspace`), mailto inclus.
  - `[low]` `[patch]` `:` appartient à `urlHostAllowed` : `host:port` et IPv6 nu produisaient une URL fausse au lieu de `nil` — host contenant `:` rejeté + 2 tests.
  - `[low]` `[patch]` Crash du process WebContent = page blanche morte sans verdict ni Retry — `webViewWebContentProcessDidTerminate` pose un `loadFailure` explicite et reset `hasContent` → empty-state avec Réessayer.
  - `[low]` `[patch]` `"\(error)"` imprimait le dump NSError complet et l'erreur WebKit 102 (« frame load interrupted ») n'était pas filtrée — détail formaté `localizedDescription (domain code)`, filtre étendu à (WebKitErrorDomain, 102).
  - `[low]` `[patch]` Rien ne vérifiait que l'app construite embarque la clé ATS (un project.yml qui la perd livrerait la feature morte, build vert) — assertion PlistBuddy dans `Scripts/release.sh` (exit 1 avec remède).

### 2026-08-23 — Review pass (follow-up)
- intent_gap: 0
- bad_spec: 0
- patch: 5: (high 0, medium 1, low 4)
- defer: 0
- reject: 11
- addressed_findings:
  - `[medium]` `[patch]` Aucun `WKUIDelegate` : un lien `target="_blank"`/`window.open` du dashboard ne faisait rien du tout (WebKit avale les navigations nouvelle-fenêtre sans UI delegate) — `createWebViewWith` ouvre l'URL dans le navigateur par défaut et retourne `nil`, même sortie qu'un lien externe.
  - `[low]` `[patch]` `requestedURL` n'était posé que dans `start()` différé d'un tick : plusieurs passages d'`updateNSView` dans un même cycle de layout empilaient des `start(url)` en rafale — l'identité est désormais réclamée synchroniquement dans `loadIfNeeded`, seul le reset d'état publié reste différé.
  - `[low]` `[patch]` `[` et `]` appartiennent aussi à `urlHostAllowed` : un IPv6 bracketé ou un crochet parasite produisait une URL au lieu de `nil` — rejet aligné sur `:` + 2 tests ; bornes valides du port (1, 65535) épinglées par un test.
  - `[low]` `[patch]` Aucun état de chargement : WebView blanche muette entre le clic d'onglet et `didCommit` sur un tailnet lent — `isLoading` publié depuis les callbacks delegate, `ProgressView` en overlay tant que rien n'a commité.
  - `[low]` `[patch]` fr : « Le tableau de bord n'a pas chargé » → « Le tableau de bord ne s'est pas chargé » (chargement pronominal idiomatique).

### 2026-08-23 — Review pass (follow-up 2)
- intent_gap: 0
- bad_spec: 0
- patch: 5: (high 0, medium 2, low 3)
- defer: 0
- reject: 21
- addressed_findings:
  - `[medium]` `[patch]` La branche `loadFailure` n'était pas subordonnée à `hasContent` : un échec de navigation postérieur au `didCommit` (lien interne mort, réseau coupé en cours de page) remplaçait une page affichée par l'empty-state — l'inverse d'UX-DR5 « conserve les dernières données », que la garde d'injoignabilité respectait pourtant déjà. Garde alignée (`!entry.hasContent`) ; `retry()` remettant `hasContent` à `false`, un retry en échec continue d'afficher son verdict.
  - `[medium]` `[patch]` Les deux sorties externes passaient `navigationAction.request.url` brute à `NSWorkspace.shared.open` : du contenu HTTP en clair, sous une exception ATS globale, pouvait déclencher n'importe quel schéma enregistré sur le Mac (`file:`, `javascript:`, schémas d'apps tierces) — `openExternally(_:)` restreint à `http`/`https`/`mailto`, le reste est ignoré.
  - `[low]` `[patch]` `fail(_:)` éteignait `isLoading` **avant** les filtres d'annulation : l'erreur `NSURLErrorCancelled` de la navigation abandonnée par un Retry arrivait après le `didStartProvisionalNavigation` de celle qui la remplace et effaçait le `ProgressView` d'un chargement toujours en vol — la vue blanche muette que `isLoading` devait supprimer. `isLoading = false` déplacé après les early returns.
  - `[low]` `[patch]` `loadIfNeeded` empilait encore deux chargements : après la réclamation synchrone de `requestedURL`, un second `updateNSView` du même cycle trouvait `requestedURL == url`, `webView.isLoading == false` (le `start` différé n'a pas encore chargé) et franchissait la garde — flag `pendingStart`, levé jusqu'à l'exécution du `start`.
  - `[low]` `[patch]` `urlHostAllowed` admet aussi tous les sous-délimiteurs (`& ; , + = …`) : `pi@rasp&yellow` produisait une URL syntaxiquement valide ne nommant aucune machine, au lieu de l'empty-state explicatif. Les rejets ponctuels de `:`/`[`/`]` sont remplacés par un allowlist positif de l'alphabet DNS (lettres, chiffres, `-`, `.`) qui les couvre tous + 3 tests (sous-délimiteurs, non-ASCII, forme MagicDNS valide).

## Design Notes

**L'URL vit dans le kit, la WebView dans l'app.** La dérivation d'URL est la seule logique testable par `swift test` (aucun target de tests app — DW-7) ; elle rejoint les helpers purs du kit. `WKWebView` est un objet de vue : le cache reste côté app, hors de `FleetModel` (AD-15 gouverne l'état UI observé, pas des vues AppKit).

**Cache possédé par `ControlCenterView`, pas par la fiche.** `MachineDetailView` porte `.id(machine.name)` : tout `@State` local meurt au changement de machine. Le critère « état conservé » impose de remonter la propriété d'un niveau — la fenêtre est unique, sa vue racine est le bon propriétaire, et son `onChange` des noms de machines fait déjà le ménage des sélections mortes.

**`NSAllowsArbitraryLoads` est l'exception unique voulue.** Les hosts du tailnet sont dynamiques (MagicDNS, IP 100.x) : des exceptions par domaine sont impossibles à énumérer. AD-3 assume une exception globale documentée, posée une fois, réutilisée par l'epic 2 — app Developer ID hors App Store, pas de justification de review à fournir.

**Ne jamais charger vers un échec connu.** Tenter le chargement d'une machine sue injoignable pour ensuite intercepter l'échec serait un détour ; la garde `reachable == false` (sans page en cache) court-circuite et affiche l'empty-state directement. L'échec WebKit reste intercepté pour le cas inverse : SSH répond, le serveur web non.

## Verification

**Commands:**
- `swift build` — expected: compilation sans erreur.
- `swift test` — expected: suite verte, dont `DashboardURLTests` ; aucune régression.
- `cd App && xcodegen generate && xcodebuild -project HomePortMenu.xcodeproj -scheme HomePortMenu -configuration Debug build CODE_SIGNING_ALLOWED=NO` — expected: `BUILD SUCCEEDED`, et `App/Info.plist` généré contient `NSAppTransportSecurity`/`NSAllowsArbitraryLoads`.

**Manual checks (if no CLI):**
- Fiche d'une machine réelle joignable : onglet Dashboard → la page Homeport se charge et répond à la saisie ; Logs puis retour → pas de rechargement.
- Machine éteinte : onglet Dashboard → empty-state « injoignable » + « Réessayer », aucun rendu d'erreur WebKit ; rallumer puis « Réessayer » → la page arrive.
- Basculer en fr/zh-Hans : les trois empty-states traduits, détail d'erreur mono inchangé.

## Auto Run Result

Status: done

**Change implémenté.** L'onglet Dashboard de la fiche machine embarque le dashboard web du Homeport : exception ATS unique d'AD-3 posée dans `App/project.yml` (donc dans l'Info.plist généré), dérivation d'URL pure et testée dans HomePortKit, et une `WKWebView` par machine mise en cache au niveau de la fenêtre pour que l'état de page survive aux changements d'onglet et de machine — gardée par les trois empty-states UX-DR5, jamais par une page d'erreur WebKit. Cette passe est une review de suivi sur une story déjà finalisée : elle n'a rien réimplémenté, elle a corrigé cinq défauts du code livré.

**Fichiers modifiés (cette passe).**
- `App/Sources/DashboardTabView.swift` — verdict d'échec subordonné à `hasContent` (une page commitée n'est plus détruite par un échec ultérieur) ; `openExternally(_:)` restreint les sorties `NSWorkspace` à `http`/`https`/`mailto` ; `isLoading` n'est plus éteint par une erreur filtrée ; flag `pendingStart` contre le double chargement.
- `Sources/HomePortKit/Dashboard.swift` — allowlist positif de l'alphabet DNS pour le host, en remplacement des rejets ponctuels de `:`/`[`/`]`.
- `Tests/HomePortKitTests/DashboardURLTests.swift` — 3 tests ajoutés (sous-délimiteurs, host non-ASCII, forme MagicDNS valide).
- `docs/build/spec-1-4-dashboard-homeport-intégré.md` — triage log de la passe et ce résultat.

**Findings.** 5 patches appliqués (0 high, 2 medium, 3 low), 0 différé, 0 intent_gap, 0 bad_spec, 21 rejets. Rejets notables et leur raison : le port loopback du healthz réutilisé pour un fetch tailnet (spéculatif, non établi par le code) ; le rejet catégorique d'IPv6 et la comparaison de host courte/FQDN dans la politique de navigation (comportement déjà arbitré aux passes 1-2) ; l'absence d'inspection des codes HTTP (non couvert par l'intent — une page d'erreur serveur n'est pas une page d'erreur WebKit — et la correction déplacerait le comportement plus qu'elle ne le corrige) ; `App/Info.plist` « édité à la main » (réfuté empiriquement : `xcodegen generate` a été relancé pendant la vérification et l'arbre est resté propre — le plist tracké se régénère à l'identique depuis `project.yml`, ce n'est pas une seconde source de vérité) ; `sprint-status.yaml` (propriété de l'orchestrateur, hors périmètre de cette session) ; DW-10 en français (entrée de ledger existante, non réécrite). Trois findings ont été écartés après vérification factuelle contre le dépôt : `Unreachable` et `Retry` existent déjà dans `Localizable.xcstrings` avec en/fr/zh-Hans, la chaîne placeholder « …embedded here by story 1.4. » a bien été retirée du catalogue, et `content` ne porte aucune branche `.dashboard` morte.

**Follow-up review.** Patches de cette passe : 0 high, 2 medium, 3 low → score `3×2 + 1×3 = 9` ≥ 5 → `followup_review_recommended: true`.

**Vérification.** `swift build` : succès. `swift test` : 183 tests, 0 échec (dont les 15 de `DashboardURLTests`). `cd App && xcodegen generate && xcodebuild … -configuration Debug build CODE_SIGNING_ALLOWED=NO` : `BUILD SUCCEEDED`, et `PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsArbitraryLoads" App/Info.plist` retourne `true`. Les checks manuels (machine réelle joignable, machine éteinte, bascule fr/zh-Hans) restent non exécutés : ils demandent du matériel et un opérateur.

**Risques résiduels.**
- DW-10 reste ouvert et couvre désormais aussi les quatre corrections de cette passe : la machine à états du cache (subordination à `hasContent`, filtre de schéma, filtres d'erreur, `pendingStart`) n'a toujours aucune vérification exécutable — le target App n'a pas de bundle de tests, et inverser n'importe laquelle de ces gardes laisse `swift test` vert. Le seul filet reste la lecture de code et les checks manuels.
- **Prix assumé du patch P1, à connaître :** une fois qu'une page a commité, aucun chemin ne ramène de verdict ni de rechargement. Un échec de navigation postérieur pose `loadFailure` qui restera invisible (la garde d'échec est subordonnée à `hasContent`), la garde d'injoignabilité ne peut plus se déclencher pour la même raison, et `loadIfNeeded` refuse de recharger tant que `hasContent` tient. Concrètement : plus de bouton « Réessayer » du tout dans cet état — seuls un redémarrage de l'app ou le retrait de la machine de `fleet.yaml` (qui purge l'entrée) rendent la main. Avant P1, l'utilisateur avait un verdict et un Retry fonctionnel, mais au prix de perdre la page affichée. Le choix retenu suit UX-DR5 (« conserver les dernières données ») ; s'il se révèle gênant à l'usage, le remède est un rechargement explicite dans la vue, pas un retour en arrière sur P1.
- Même famille, non corrigé et non couvert par l'intent : une page d'erreur HTTP du serveur (404, 502) commit normalement et se fige donc de la même manière.
- Piste non tracée, à surveiller avec DW-10 : P3 a supprimé le seul chemin qui éteignait `isLoading` inconditionnellement. Si un premier chargement pouvait se terminer sur une erreur filtrée sans navigation de remplacement — le candidat plausible étant une réponse convertie en téléchargement (WebKit 102) — l'overlay `isLoading && !hasContent` tiendrait indéfiniment : spinner éternel, sans verdict ni Retry. Le cas est peu vraisemblable à la racine d'un dashboard, et ajouter une garde de plus en fin de troisième passe de review coûterait plus qu'il ne rapporte.

