# Correctifs de revue — story 1.1

Contraintes qui priment sur tout le reste :
- `machineWarnings`, `backupAge`, `transitions`, `Machine`, `MachineStatus`, `FleetStore` sont
  consommés **tels quels, jamais modifiés** (contrainte Always de la spec ; le CLI en dépend).
- Aucune valeur de style hors `App/Sources/Theme.swift`.
- Aucune chaîne d'interface en dur : tout passe par `Localizable.xcstrings` (en/fr/zh-Hans).
- Toute logique pure ajoutée vit dans `HomePortKit` et est couverte par `swift test`.
- Ne pas toucher `docs/build/sprint-status.yaml`.

## D1 + D2 — une seule source de vérité pour la santé (high)

Aujourd'hui `statusReasons`/`updateAvailable` (`App/Sources/DesignComponents.swift:46-62`)
réimplémentent la règle de `machineWarnings` (`Sources/HomePortKit/FleetHealth.swift:18-28`)
avec un ordre différent, hors du kit, non compilés par `swift test`. En parallèle
`dotColor` (`App/Sources/MenuContent.swift:146`) rend `.gray` pour une machine non sondée
alors que `severity(of: nil)` rend `.critical` (`Tests/HomePortKitTests/FleetRowTests.swift:85`).
Les deux surfaces se contredisent sur la même machine.

À faire :
1. Nouveau fichier `Sources/HomePortKit/MachineIssue.swift` — SANS toucher à `FleetHealth.swift` :
   `public enum MachineIssue: Equatable { case notPolled, unreachable, serviceInactive,
   healthzFailing, diskAlmostFull(Int), updateAvailable(String) }`
   et `public func machineIssues(_ status: MachineStatus?, latest: String?) -> [MachineIssue]`,
   fonction pure, sans SwiftUI. Ordre stable et documenté. Seuil disque `>= 90`, garde
   `installedVersion != "unknown"` — mêmes règles que le kit, une seule fois.
2. `severity(of:latest:)` (`Sources/HomePortKit/FleetRow.swift`) dérive de `machineIssues`.
   Le comportement pinné reste vrai : pas de statut → `.critical`.
3. `App/Sources/DesignComponents.swift` : `statusReasons` devient une simple projection
   `[MachineIssue] -> [LocalizedStringKey]`. Supprimer `updateAvailable` et sa règle dupliquée ;
   les appelants passent par `machineIssues`. Aucune règle métier ne reste dans `App/Sources`.
4. `dotColor` (`App/Sources/MenuContent.swift`) dérive de la même sévérité que le `StatusPill`.
   Une machine non sondée doit se lire pareil dans la barre de menus et dans le centre de contrôle.
5. Tests dans `Tests/HomePortKitTests/` : ordre des issues, seuil `disk == 90` ET `disk == 89`,
   version `"unknown"` ne réclame jamais de mise à jour, `nil` → `[.notPolled]` → `.critical`,
   injoignable → `[.unreachable]`. Plus un test qui verrouille l'accord entre la sévérité du
   pill et celle du point de la barre de menus.

## D3 — le repli de fonte est jeté (high)

`Theme.swift:136` : `guard let sansFamily, sansFamily == FontStack.sans.first else { .system }`.
La pile est résolue puis rejetée dès que ce n'est pas le premier choix. Inter et JetBrains Mono
n'étant pas embarqués par conception, l'app tombe systématiquement en `.system` — et la matrice
gelée exige « nom résolu = premier repli disponible de la pile documentée ».
À faire : utiliser la famille résolue telle quelle dans `sans()` et `mono()`, et ne retomber sur
`.system` que si la résolution ne rend rien.

## P1 — ⌘1-8 morts sur AZERTY (high)

`ControlCenterCommands.Command.init(event:)` lit `charactersIgnoringModifiers` puis `Int(key)`.
Sur AZERTY la rangée du haut donne `&`, `é`, `"`… jamais `1`-`8`. L'utilisateur est français.
À faire : résoudre les chiffres via `event.keyCode` (rangée physique 18-26 = 1…8, plus le pavé
numérique), ou via `charactersByApplyingModifiers`. Garder ⌘R et ⌘F sur les lettres.
Faire dépendre le retour de `performKeyEquivalent` de la prise en charge effective : ⌘3 sur la
vue de flotte ne doit pas être avalé sans effet, il doit repartir dans la chaîne de responders.

## Defects à corriger

- P2 `DesignComponents.swift:211` — `DataColumn.id = UUID()` dans une propriété calculée :
  identité neuve à chaque rendu, cellules reconstruites, focus perdu. Dériver l'id du titre.
- P3 `focusRing` trace `stroke(Theme.ink)` sur des éléments dont le fond sélectionné est déjà
  `Theme.ink` : le focus est invisible là où il atterrit le plus. Contraster sur fond inverse.
- P4 `Theme.semanticSuccess` #1ea64a ≈ 3,2:1 sur canvas blanc, sous 4,5:1, sur du mono 11 px.
  Assombrir dans `Theme.swift` en restant dans l'esprit de la palette.
- P5 la clé `"OK"` sert au `StatusPill` et au bouton de validation `NSAlert` : le bouton s'affiche
  `正常` en chinois. Deux clés distinctes ; laisser `NSAlert` fournir son libellé système.
- P6 `MachineRow.reasons` rend `[]` dès que la machine est injoignable : la ligne d'avertissement
  disparaît. Résolu naturellement par `machineIssues` (`.unreachable` est une issue).
- P7 « Last seen » en heure seule (`FleetOverviewView.clockTime`) : trois jours d'absence lisent
  « 14:32 ». Passer en relatif comme la colonne Backup, dans la vue de flotte et le résumé.
- P8 `lastReachableStatus`, `lastSeenAt`, `lastError` jamais purgés d'une machine retirée de
  `fleet.yaml` ; `selection` reste sur une machine disparue. Purger dans `reloadFleet()`,
  retomber sur `.fleet`.
- P9 la table de flotte n'est pas opérable au clavier : `.onTapGesture` sans `Button`,
  `focusable` ni trait d'accessibilité, et VoiceOver énonce six cellules détachées par ligne.
  Rendre les lignes focalisables et activables, et grouper l'énoncé autour du nom de machine.
- P10 `accessibilityLabel` du bouton Update figé même quand `latestTag == nil` : VoiceOver
  n'annonce pas pourquoi il est désactivé. Aligner le label sur le `.help`.
- P11 palette dupliquée : `Theme.color(of:)` fait un switch au lieu de lire `block.hex`.
  Une seule source pour les 7 valeurs.
- P12 code mort : `ControlCenterCommands.matches`, `Theme.accentMagenta`, `Rounded.xs`,
  `Rounded.full`, et la clé `"the latest release"` rendue inatteignable par `.disabled`.
- P13 `raspcorse` (nom personnel) livré comme exemple dans l'état vide — mettre un nom générique.
- P14 `FleetRow.warnings` peuplé, asserté, lu par aucune vue, et ses assertions figent la
  formulation anglaise du CLI. Le retirer ou le faire consommer par les vues via `machineIssues`.

## Vérification obligatoire après correctifs

Relancer les six commandes de la section `## Verification` de la spec, toutes vertes :
`swift build`, `swift test`, `xcodegen generate`, `xcodebuild … Debug`, présence de
`en/fr/zh-Hans.lproj` dans le bundle, et le grep de littéraux ne trouvant que `Theme.swift`.
Toute nouvelle clé d'interface doit exister en `en`, `fr` et `zh-Hans`.

## Compléments (issus de la version finale du rapport verification-gap)

### D2b — une TROISIÈME échelle de santé : l'icône agrégée de la barre de menus (high)

`FleetHealth.aggregate` (appelé depuis `App/Sources/FleetModel.swift:29`) fait un `compactMap`
qui **écarte purement et simplement les machines non sondées**, et peut donc rendre `.allGreen`
pendant que la table de flotte affiche `CRITICAL` pour ces mêmes machines
(`severity(of: nil) == .critical`, pinné par `FleetRowTests.swift:85`).
Cas réels : le premier refresh, et le cas où `status(of:)` lève une erreur non-`HPMError` et où
`FleetModel.swift:85` supprime la clé.
L'unification D1/D2 doit donc couvrir **trois** surfaces, pas deux : le `StatusPill`, le point
de `MachineRow`, et l'icône globale de la barre de menus. Une machine non sondée doit peser le
même poids dans les trois. `aggregate` n'est pas dans la liste des symboles gelés par la spec
et peut être ajusté ; vérifier ses éventuels autres appelants (CLI) avant de le faire.
Ajouter un test qui verrouille l'accord des trois lectures sur une flotte non sondée.

### D4 — `lastBackupDate` duplique le parseur de `backupAge`, et son test porte sur une forme fictive (high)

`lastBackupDate(_:)` (`Sources/HomePortKit/FleetRow.swift:44-51`) rejoue la regex
`#"\d{8}-\d{6}"#` et le `timestampFormatter` déjà portés par `backupAge(_:now:)`
(`Sources/HomePortKit/FleetHealth.swift:49-60`). Deux copies dans le kit, qu'aucun test ne lie.
Plus grave : la fixture de `FleetRowTests.swift:33` est le littéral
`"homeport-20231114-201000.tar.gz"`, **une forme que le code de backup n'émet jamais** — il
produit `homeport_<nom>_<version>_<stamp>.tar.gz` (`Sources/HomePortKit/Manager+Backup.swift:35-36`).
Le test valide donc un format fictif, et `backupAge("garbage") == "never"` est pinné pour l'ancien
parseur quand rien n'assert `lastBackupDate` sur un nom sans horodatage.

À faire : une seule extraction d'horodatage dans le kit, consommée par les deux fonctions.
Construire les fixtures de test depuis `HomeportManager.timestampFormatter` et la vraie forme
d'archive, comme `FleetHealthTests.testBackupAge` le fait déjà. Ajouter
`XCTAssertNil(lastBackupDate("garbage"))` et une assertion que les deux fonctions s'accordent
sur la même entrée. Ne pas modifier la signature ni le comportement de `backupAge` (symbole gelé).
