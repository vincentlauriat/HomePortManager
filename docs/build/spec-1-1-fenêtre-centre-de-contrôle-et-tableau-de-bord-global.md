---
title: '1.1 — Fenêtre centre de contrôle et tableau de bord global'
type: 'feature'
created: '2026-08-23'
status: 'done'
baseline_revision: '1581489d2e68c556a16842d861520567174f556c'
baseline_commit: '1581489d2e68c556a16842d861520567174f556c'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/build/epic-1-context.md'
  - '{project-root}/docs/specs/ux-designs/ux-HomePortManager-2026-08-23/DESIGN.md'
warnings: [oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** L'app menubar v1.0.0 n'offre qu'un popover étroit : pas de vue d'ensemble de la flotte, pas de fiche machine, pas de design system, pas d'i18n. Vincent ne peut pas juger la santé de sa flotte d'un coup d'œil.

**Approach:** Ouvrir depuis la menubar une fenêtre « Centre de contrôle » (NavigationSplitView, min 900×600) partageant le `FleetModel` existant, et y poser les trois socles UI de tout l'epic : tokens DESIGN.md comme source unique de style, composants réutilisables, String Catalogs fr/en/zh-Hans. La fenêtre affiche la vue Flotte (table état/version/disque/âge backup) et la coquille de fiche machine (bandeau + 8 onglets pills).

## Boundaries & Constraints

**Always:**
- Un seul `FleetModel` `@MainActor` partagé entre menubar et fenêtre (AD-15) ; aucun second modèle d'état.
- Toute couleur, fonte, rayon et espacement vient des tokens de `DESIGN.md` via un unique type `Theme` ; aucune valeur littérale dans les vues.
- Aucune chaîne d'interface en dur : tout passe par `Localizable.xcstrings` (en source, fr, zh-Hans). Le contenu produit par les machines (noms, versions, chemins, sorties) n'est jamais traduit et se rend en mono.
- L'état est porté par couleur **et** libellé (pill = les deux) ; chaque action et chaque pill porte un label VoiceOver.
- Le block pastel d'une machine est assigné une fois et n'est jamais réassigné, y compris entre deux lancements.
- Toute logique de présentation **pure** (sévérité d'état, assignation de block, construction des lignes de flotte, résolution de fonte) vit dans `HomePortKit` et est couverte par `swift test` (AD-1) ; les vues SwiftUI ne portent que du rendu. Les types existants du kit (`Machine`, `MachineStatus`, `FleetStore`, `machineWarnings`, `backupAge`, `transitions`) sont consommés tels quels, jamais modifiés.

**Block If:**
- `fleet.yaml` devrait changer de schéma pour porter l'identité visuelle — ne pas y toucher, c'est un fichier utilisateur possédé par `FleetStore`.
- Une décision imposerait de créer `hpm.db` ou d'en définir le schéma — il appartient à la story 1.2.

**Never:**
- Pas de dark mode, pas de nouvelle couleur hors palette, pas de fond sémantique plein, pas de bouton carré, pas de gris pour le texte secondaire (le poids porte la hiérarchie).
- Pas d'implémentation des onglets Dashboard / Logs / Événements / Métriques / Backups / Shell / Updates : ils existent, sont atteignables au clavier, et affichent un `empty-state` annonçant la story qui les livrera.
- Pas de commande CLI nouvelle (FR11 ne couvre pas 1.1), pas de dépendance ajoutée, pas de fonte binaire téléchargée dans le dépôt.
- Pas de modification de `docs/build/sprint-status.yaml`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Flotte peuplée | 2 machines, statuts joignables | `FleetRow` par machine : sévérité dérivée, version, disque et âge du dernier backup renseignés | Aucune erreur attendue |
| Flotte vide | `Fleet(machines: [])` | Aucune ligne produite ; l'appelant sait que la flotte est vide | Jamais d'erreur |
| Machine injoignable | statut `reachable == false` + un dernier statut joignable et sa date | Ligne construite sur les **dernières** données connues, `lastSeen` = cette date, sévérité `critical` | Pas d'erreur ; ligne conservée |
| Jamais jointe | statut `reachable == false`, aucun statut antérieur | Ligne aux valeurs inconnues, `lastSeen == nil`, sévérité `critical` | Idem |
| Sévérité warning | machine joignable avec un avertissement (`machineWarnings` non vide) | Sévérité `warning`, avertissements portés par la ligne | Aucune |
| Première assignation | nom inconnu, magasin de blocks vide | Reçoit `lime` — premier de l'ordre lime, cream, lilac, mint, pink, coral | Aucune |
| Ordre documenté | `["raspcorse", "raspyellow"]`, magasin vide | `raspcorse → lime`, `raspyellow → cream` | Aucune |
| Retrait puis ajout | magasin `{A: lime, B: cream}`, ajout de `C` | A et B inchangés ; `C → lilac` (le block de B reste réservé à B) | Aucune |
| Plus de 6 machines | 7 noms successifs, magasin vide | Les 6 premiers prennent l'ordre documenté ; le 7ᵉ reprend `lime` (index modulo 6) | Aucune |
| Fonte absente | famille préférée indisponible sur le système | Nom résolu = premier repli disponible de la pile documentée, **en sautant les familles qui n'y figurent que pour la couverture CJK** ; aucune famille éligible ⇒ fonte système | Aucune |
| Pile mono | seules la famille de couverture CJK et un repli à chasse fixe installés | Le repli à chasse fixe est résolu — la pile mono ne rend jamais une fonte proportionnelle | Aucune |

</intent-contract>

## Code Map

- `App/Sources/FleetModel.swift` — `@MainActor final class FleetModel: ObservableObject`. `machines`, `statuses`, `latestTag`, `refreshing`, `inFlight`, `lastError`, timer 300 s, `refresh()`, `reloadFleet()`, `run(_:on:)`, `fetchLogs(for:lines:)`. **Point d'extension** : `statuses` doit rester l'observation brute — `transitions(old:new:)` en dépend pour les notifications menubar. Ajouter un cache d'affichage séparé.
- `App/Sources/HomePortMenuApp.swift` — `@main`, `MenuBarExtra` + `@StateObject model`. Le `FleetModel` à partager vient d'ici.
- `App/Sources/MenuContent.swift` — popover menubar ; `MachineRow`, `footer`. Chaînes en dur à localiser ; y ajouter l'entrée d'ouverture de la fenêtre.
- `App/Sources/LogsWindow.swift` — **patron à réutiliser** : `enum` `@MainActor` + `NSWindow` + `NSHostingView`, cache statique, `isReleasedWhenClosed = false`. Le même patron sert pour la fenêtre centre de contrôle (contrôle explicite de `contentMinSize`, pas d'ouverture automatique au lancement contrairement à une `Window` scene).
- `Sources/HomePortKit/FleetStore.swift` — `Machine {name, ssh, port, notes}`, `Fleet {machines}`, `FleetStore.defaultPath = "~/.config/hpm/fleet.yaml"`. **Lecture seule.**
- `Sources/HomePortKit/Manager+Status.swift` — `MachineStatus {name, reachable, installedVersion, serviceActive, healthzOK, lastBackup, uptimeSeconds, diskUsedPercent, sshLatencyMs}`, `formatUptime(_:)`. **Lecture seule.**
- `Sources/HomePortKit/FleetHealth.swift` — `machineWarnings(_:latest:)` (source de la sévérité de la pill), `backupAge(_:now:)` (âge du dernier backup), `transitions(old:new:)`. **Lecture seule.**
- `Sources/HomePortKit/` — accueille les **nouveaux** fichiers de présentation pure de cette story (`MachineBlock.swift`, `FleetRow.swift`, `FontStack.swift`) ; aucun import SwiftUI, aucune couleur `Color` — les blocks sont des cas d'énumération portant leur hex, l'app les traduit en `Color` dans `Theme`.
- `Tests/HomePortKitTests/` — cible de test SPM existante (`MockProcessRunner.swift` fournit le patron) ; les tests de matrice de cette story y atterrissent et tournent via `swift test`.
- `App/project.yml` + `App/Info.plist` — XcodeGen ; ajouter `developmentLanguage: en` et vérifier que `Localizable.xcstrings` entre en phase `resources`.
- `docs/specs/ux-designs/ux-HomePortManager-2026-08-23/DESIGN.md` — frontmatter = valeurs exactes des tokens (couleurs hex, tailles, poids, rayons, spacing, composants).

## Tasks & Acceptance

**Execution:**
- [x] `App/Sources/Theme.swift` — créer le type `Theme` : palette (`canvas`, `ink`, `hairline`, `hairlineSoft`, `surfaceSoft`, `inverseCanvas`, `inverseInk`, les 6 `block*` + `blockNavy`, `accentMagenta`, `semanticSuccess/Warning/Critical`) en hex de DESIGN.md, échelles `rounded` et `spacing`, et une fabrique de fontes résolvant Inter / JetBrains Mono avec repli documenté, plus les 8 rôles typographiques et la traduction `MachineBlock` → `Color` — source unique de style pour toutes les vues (UX-DR1).
- [x] `App/Sources/DesignComponents.swift` — créer les composants réutilisables sur les tokens : `StatusPill` (ok/warning/critical, couleur **+** libellé), `TabPill`, `PillButtonStyle` (primary/secondary/destructive), `MachineBanner`, `DataTable` (en-têtes eyebrow, lignes 26 px, séparateurs hairline-soft, tabular-nums), `EmptyStateView`, `SidebarRow` — pour que 1.3/1.4/1.5 les consomment sans les redéfinir (UX-DR2).
- [x] `Sources/HomePortKit/MachineBlock.swift` — créer l'énumération `MachineBlock` (lime, cream, lilac, mint, pink, coral, navy hors rotation ; chaque cas porte son hex) et la fonction pure `assignBlocks(to:existing:)` : ordre documenté, jamais de réassignation, block d'une machine retirée jamais recyclé, cycle modulo 6 au-delà de six — logique testable, hors SwiftUI (AD-1).
- [x] `Sources/HomePortKit/FleetRow.swift` — créer `FleetRow` (nom, block, sévérité `ok|warning|critical`, avertissements, version, disque, âge backup, `lastSeen: Date?`) et la fonction pure `fleetRows(machines:statuses:lastReachable:lastSeen:latest:blocks:)` qui retombe sur les dernières données connues quand la machine n'est pas joignable — c'est le cœur observable du tableau de bord.
- [x] `Sources/HomePortKit/FontStack.swift` — créer `resolveFontFamily(preferred:isAvailable:)` renvoyant le premier nom disponible d'une pile de repli, plus les deux piles documentées — rend le repli de fonte testable sans dépendre des fontes installées.
- [x] `Tests/HomePortKitTests/MachineBlockTests.swift` — couvrir les cinq lignes de matrice d'assignation (première assignation, ordre documenté raspcorse/raspyellow, retrait puis ajout, au-delà de six, stabilité) — l'identité machine est la seule donnée durable introduite ici.
- [x] `Tests/HomePortKitTests/FleetRowTests.swift` — couvrir les lignes de matrice de construction de lignes (flotte peuplée, flotte vide, injoignable avec dernier statut, jamais jointe, sévérité warning) et la ligne de repli de fonte — ce sont les comportements que la vue Flotte se contente d'afficher.
- [x] `App/Sources/MachineBlockStore.swift` — créer le magasin de persistance côté app : lit/écrit la table nom→block dans `UserDefaults`, délègue le calcul à `assignBlocks` et n'écrit que les nouvelles entrées — l'identité doit survivre aux relances (UX-DR3).
- [x] `App/Sources/FleetModel.swift` — ajouter `lastReachableStatus: [String: MachineStatus]` et `lastSeenAt: [String: Date]` alimentés au refresh quand `reachable`, plus un `displayStatus(for:)` exposant le couple (dernières données, date de dernière vue) — sans jamais altérer `statuses`, dont dépendent `transitions` et les notifications menubar (UX-DR5, AD-15).
- [x] `App/Sources/ControlCenterWindow.swift` — créer la fenêtre : `NSWindow` + `NSHostingView`, `contentMinSize` 900×600, instance unique ramenée au premier plan, contenu `NavigationSplitView` (sidebar 220 px : entrée « Flotte » + une `SidebarRow` par machine) — la coquille exigée par AD-15.
- [x] `App/Sources/FleetOverviewView.swift` — créer la vue Flotte : `DataTable` alimentée par `fleetRows(...)` (pastille, nom, pill, version, disque, âge backup, « Vu pour la dernière fois »), champ de filtre par nom porté par `⌘F` (`@FocusState`), bouton de refresh `⌘R`, et bascule vers `EmptyStateView` quand la flotte est vide — c'est le tableau de bord global de FR1.
- [x] `App/Sources/MachineDetailView.swift` — créer la fiche : `MachineBanner` au block de la machine + barre des 8 onglets pills (Résumé, Dashboard, Logs, Événements, Métriques, Backups, Shell, Updates) raccourcis `⌘1`…`⌘8`, onglet Résumé peuplé (santé, version vs dernière release, disque, uptime, latence SSH), les 7 autres en `EmptyStateView` nommant leur story — pour que les raccourcis d'accessibilité soient réels dès 1.1.
- [x] `App/Sources/Localizable.xcstrings` — créer le String Catalog : langue source `en`, localisations `fr` et `zh-Hans` pour chaque clé d'interface introduite ici et dans la menubar — aucune chaîne en dur ne doit subsister (UX-DR4).
- [x] `App/Sources/MenuContent.swift` — ajouter l'entrée « Ouvrir le centre de contrôle » (`⌘O`) ouvrant la fenêtre avec le modèle partagé, et remplacer les chaînes en dur par des clés du catalogue — la fenêtre n'a pas d'autre point d'entrée.
- [x] `App/project.yml` — déclarer `developmentLanguage: en` et, si XcodeGen ne classe pas seul `Localizable.xcstrings`, l'épingler en `buildPhase: resources` — sans quoi les traductions n'entrent pas dans le bundle.

**Acceptance Criteria:**
- Given l'app lancée avec 2 machines déclarées, when Vincent choisit « Ouvrir le centre de contrôle » dans la menubar, then une fenêtre non redimensionnable sous 900×600 s'ouvre avec la sidebar « Flotte » + 2 entrées, et une seconde invocation ramène la même fenêtre au premier plan au lieu d'en créer une deuxième.
- Given la fenêtre et la menubar ouvertes simultanément, when un refresh se termine, then les deux surfaces affichent le même état sans second rafraîchissement, et les notifications de transition de la menubar continuent d'être émises.
- Given une machine sélectionnée dans la sidebar, when Vincent presse `⌘1` à `⌘8`, then l'onglet correspondant s'active ; `⌘R` relance le refresh ; le focus clavier est visible sur la sidebar et sur les onglets.
- Given la vue Flotte affichée avec 2 machines, when Vincent presse `⌘F` et saisit une partie d'un nom de machine, then le champ de filtre prend le focus et la table ne montre que les lignes correspondantes ; vider le champ restaure la table complète.
- Given VoiceOver actif, when le curseur atteint une pill d'état ou un bouton d'action, then un label est annoncé, et l'état reste identifiable sans la couleur (libellé présent dans la pill).
- Given le catalogue de chaînes, when l'app tourne en `fr`, `en` puis `zh-Hans`, then aucune chaîne anglaise résiduelle n'apparaît hors contenu machine, et les libellés de pills et d'en-têtes de table ne sont ni tronqués ni chevauchés en `zh-Hans`.
- Given `grep` sur les vues de l'app, when on cherche des littéraux de couleur, de taille de fonte ou de rayon, then seules les définitions de `Theme.swift` en contiennent.

## Spec Change Log

- **2026-08-23 — planification.** Contradiction dans les artefacts amont : `DESIGN.md` (`tab-default`) et `epics.md` UX-DR7 décrivent « 7 onglets / ⌘1-7 » (sans Dashboard), tandis que `EXPERIENCE.md` et le critère d'acceptation de la story 1.1 décrivent 8 onglets / ⌘1-8 (Dashboard inclus, livré en 1.4). **Tranché : 8 onglets / ⌘1-8** — le critère d'acceptation de la story fait foi et Dashboard appartient au même epic. Évite un renumérotage des raccourcis en 1.4. KEEP : la liste et l'ordre des onglets (Résumé · Dashboard · Logs · Événements · Métriques · Backups · Shell · Updates) doivent survivre à toute re-dérivation.

- **2026-08-23 — revue, lacune d'intention sur les piles de fontes.** La matrice exigeait « premier repli disponible de la pile documentée ». Appliquée à la lettre, elle résolvait les deux piles vers `PingFang SC` : interface française dessinée en fonte chinoise, et pile *mono* résolue vers une fonte **proportionnelle**, ce qui casse l'alignement `tabular-nums` de `DataTable` et le rendu mono du contenu machine. Cause racine : les piles de `DESIGN.md` sont des piles **CSS**, où le repli est résolu *glyphe par glyphe* et où `PingFang SC` ne couvre que le chinois ; `Font.custom` de SwiftUI prend **une seule famille pour tout le texte**. **Tranché : les familles de couverture CJK sont ignorées lors du choix de la famille d'interface** — macOS couvre déjà le CJK seul. Résolution réelle obtenue : sans ⇒ fonte système, mono ⇒ `Menlo`. KEEP : la pile mono ne doit jamais résoudre une fonte proportionnelle ; `FontStack.coverageOnly` est le seul endroit où cette exception est déclarée.

## Review Triage Log

## Design Notes

**Poids typographiques.** `DESIGN.md` exprime les poids en valeurs variables (340/400/480/540/600) que SwiftUI n'accepte pas. Table de correspondance à figer dans `Theme.swift`, seul endroit où la conversion existe :

```
340 → .light      400 → .regular    480 → .medium
540 → .semibold   600 → .bold
```

**Fontes.** Inter et JetBrains Mono ne sont pas embarquées : `DESIGN.md` documente lui-même les piles de repli (`Inter, PingFang SC, SF Pro Display, system-ui` / `JetBrains Mono, PingFang SC, SF Mono, Menlo`). Le repli est donc le contrat, pas un compromis — `Theme` tente `Font.custom` puis retombe sur `Font.system(size:weight:design:)`. Aucun binaire de fonte n'entre dans le dépôt.

**Persistance de l'identité machine.** `UserDefaults` côté app, pas `hpm.db` : AD-7 énumère journal, curseurs, marqueurs, état des jobs et verrous — l'identité visuelle n'en fait pas partie, le CLI n'en a aucun usage (AD-6 tient), et `hpm.db` appartient à la story 1.2 qui n'est pas encore livrée. L'ordre courant de `fleet.yaml` (raspcorse puis raspyellow) produit mécaniquement l'assignation documentée raspcorse = lime, raspyellow = cream.

**Renommage.** Non supporté en v1 (ARCHITECTURE-SPINE, Deferred) : une machine renommée est une machine nouvelle et reçoit le block libre suivant. Aucun block n'est jamais recyclé, ce qui rend l'assignation monotone et reproductible.

**« Vu pour la dernière fois »** vit en mémoire dans `FleetModel` pour la durée de la session : le persister exigerait un magasin d'état central, qui appartient à 1.2. Une machine jamais jointe depuis le lancement affiche « Jamais vue ».

**Objectif unique.** La question « plusieurs objectifs livrables ? » a été posée : tokens (UX-DR1) et i18n (UX-DR4) pourraient sembler transversaux, mais `epics.md` les pose explicitement comme critères d'acceptation de cette story, « pas des vœux transversaux ». Un seul objectif — pas d'avertissement `multiple-goals`.

## Verification

**Commands:**
- `swift build` — expected: compilation sans erreur.
- `swift test` — expected: toute la suite `HomePortKitTests` passe, y compris les nouveaux `MachineBlockTests` et `FleetRowTests` qui couvrent chaque ligne de la matrice ; aucune régression sur les tests existants.
- `cd App && xcodegen generate` — expected: `HomePortMenu.xcodeproj` régénéré sans avertissement sur les ressources.
- `xcodebuild -project App/HomePortMenu.xcodeproj -scheme HomePortMenu -configuration Debug build CODE_SIGNING_ALLOWED=NO` — expected: `BUILD SUCCEEDED`.
- `find <chemin du .app construit>/Contents/Resources -name '*.lproj'` — expected: `en.lproj`, `fr.lproj` et `zh-Hans.lproj` présents (preuve que le String Catalog est bien compilé dans le bundle).
- `grep -nE '#[0-9a-fA-F]{6}|Color\(red:|\.font\(\.(system|custom|caption|body|title)|\.(foregroundStyle|foregroundColor|fill)\(\.(gray|red|green|orange|blue|yellow|secondary|primary)\)' App/Sources/*.swift` — expected: aucune occurrence hors `App/Sources/Theme.swift`.
  Le motif d'origine ne couvrait que `.font(.system(size:` et laissait passer `.font(.caption)`, `.font(.system(.caption, design:))` et les couleurs système `.secondary`/`.orange`/`.red` — six occurrences ont ainsi traversé la revue dans `MenuContent.swift` et `LogsWindow.swift`.

**Manual checks (if no CLI):**
- Ouvrir la fenêtre depuis la menubar : min 900×600 respecté, sidebar 220 px, une seule fenêtre quel que soit le nombre d'invocations.
- Renommer temporairement `~/.config/hpm/fleet.yaml` : l'état vide s'affiche avec chemin, exemple YAML et commande `hpm machine add` — aucune erreur.
- Relancer l'app : les blocks pastel des machines sont identiques à la session précédente.
- `⌘1`…`⌘8` sur une machine sélectionnée, `⌘R` et `⌘F` sur la vue Flotte : chaque raccourci agit, le focus reste visible.

## Suggested Review Order

**Le verdict de santé — une seule règle, trois lectures**

- Le point d'entrée : la règle de santé écrite une fois, en faits plutôt qu'en phrases.
  [`MachineIssue.swift:40`](../../Sources/HomePortKit/MachineIssue.swift#L40)

- La sévérité en dérive ; l'absence d'observation reste `critical`, jamais « rien à signaler ».
  [`FleetRow.swift:62`](../../Sources/HomePortKit/FleetRow.swift#L62)

- Troisième lecture : l'icône globale reçoit désormais les `nil` au lieu de les filtrer.
  [`FleetHealth.swift:18`](../../Sources/HomePortKit/FleetHealth.swift#L18)

- Côté app, plus une seule règle métier : une simple projection en clés traduisibles.
  [`DesignComponents.swift:55`](../../App/Sources/DesignComponents.swift#L55)

- Le point de la barre de menus passe par le même verdict que la pastille.
  [`MenuContent.swift:151`](../../App/Sources/MenuContent.swift#L151)

**Typographie — pourquoi la pile CSS ne se transpose pas**

- L'exception déclarée à un seul endroit : les familles de couverture CJK ne sont pas des faces.
  [`FontStack.swift:33`](../../Sources/HomePortKit/FontStack.swift#L33)

- Source unique de style ; `semanticSuccess` assombri pour tenir le contraste 4,5:1.
  [`Theme.swift:28`](../../App/Sources/Theme.swift#L28)

**La fenêtre et son clavier**

- Les chiffres sont lus sur le `keyCode` : sans cela ⌘1-8 est mort sur AZERTY.
  [`ControlCenterWindow.swift:83`](../../App/Sources/ControlCenterWindow.swift#L83)

- Ne consomme la touche que si une vue affichée la prend en charge.
  [`ControlCenterWindow.swift:46`](../../App/Sources/ControlCenterWindow.swift#L46)

- Fenêtre unique, `contentMinSize` épinglé — une `Window` scene s'ouvrirait au lancement.
  [`ControlCenterWindow.swift:26`](../../App/Sources/ControlCenterWindow.swift#L26)

- Les 8 onglets et leur numérotation : le contrat, pas un ordre accidentel.
  [`MachineDetailView.swift:6`](../../App/Sources/MachineDetailView.swift#L6)

**État partagé et durée de vie**

- `statuses` reste l'observation brute ; les caches d'affichage vivent à côté.
  [`FleetModel.swift:19`](../../App/Sources/FleetModel.swift#L19)

- Purge des machines retirées — mais seulement si le chargement a réellement réussi.
  [`FleetModel.swift:69`](../../App/Sources/FleetModel.swift#L69)

**Accessibilité et rendu du tableau**

- Une ligne = un énoncé VoiceOver, au lieu de six cellules détachées.
  [`FleetOverviewView.swift:133`](../../App/Sources/FleetOverviewView.swift#L133)

- L'identité de colonne dérive du titre : un `UUID()` la régénérait à chaque rendu.
  [`DesignComponents.swift:229`](../../App/Sources/DesignComponents.swift#L229)

**Périphérie**

- Extraction d'horodatage unique du kit, consommée par `backupAge` et par l'interface.
  [`FleetHealth.swift:66`](../../Sources/HomePortKit/FleetHealth.swift#L66)

- Les tests qui verrouillent l'accord des trois surfaces sur une flotte non sondée.
  [`MachineIssueTests.swift:1`](../../Tests/HomePortKitTests/MachineIssueTests.swift#L1)

- La pile mono ne doit jamais résoudre une fonte proportionnelle.
  [`FleetRowTests.swift:111`](../../Tests/HomePortKitTests/FleetRowTests.swift#L111)

