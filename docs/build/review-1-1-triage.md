# Triage de revue — story 1.1 (itération 0)

Trois couches : `blind-hunter`, `edge-case-hunter`, `verification-gap`.
Sévérité réassignée ici par conséquence pour l'utilisateur de l'app (celle des relecteurs est ignorée par construction).

⚠️ Biais connu : le diff soumis aux relecteurs excluait la spec et `epic-1-context.md`.
Aucun d'eux ne pouvait donc signaler une déviation de contrat — le contrôle spec est fait ici.

## Déviations du contrat d'intention (confirmées dans le code)

| # | Constat | Preuve | Sévérité |
|---|---|---|---|
| D1 | Logique de santé pure (`statusReasons`, `updateAvailable`) placée dans `App/Sources/DesignComponents.swift:46-62`, hors de `HomePortKit`, donc jamais compilée par `swift test` | Viole la contrainte Always « toute logique de présentation pure … vit dans HomePortKit et est couverte par swift test (AD-1) » | high |
| D2 | Deux échelles de santé divergentes : `dotColor` (`MenuContent.swift:146`) rend `.gray` pour une machine non sondée, `severity(of: nil)` rend `.critical` (`FleetRowTests.swift:85`). Ordre des raisons également inversé entre kit et app | L'app se contredit sur la santé d'une même machine, entre barre de menus et centre de contrôle | high |
| D3 | Repli de fonte calculé puis jeté : `guard let sansFamily, sansFamily == FontStack.sans.first` (`Theme.swift:136`) | La matrice gelée exige « Nom résolu = premier repli disponible de la pile documentée ». Inter étant absent par conception, toute l'app tombe en `.system` | high |

## Defects (causés par le changement)

| # | Constat | Sévérité |
|---|---|---|
| P1 | ⌘1-8 inopérants sur clavier AZERTY (`charactersIgnoringModifiers` → `&`, `é`… jamais `1`). Critère d'acceptation « ⌘1 à ⌘8 : l'onglet correspondant s'active » non tenu sur le clavier de l'utilisateur | high |
| P2 | `DataColumn.id = UUID()` régénéré à chaque passe de `body` : toutes les cellules reconstruites à chaque refresh, focus perdu | medium |
| P3 | Bague de focus invisible : `stroke(Theme.ink)` sur `SidebarRow`/`TabPill` sélectionnés, dont le fond est déjà `Theme.ink`. Critère « le focus clavier est visible » non tenu | medium |
| P4 | `Theme.semanticSuccess` #1ea64a ≈ 3,2:1 sur canvas blanc, sous le seuil 4,5:1, appliqué à du mono 11 px | medium |
| P5 | Clé `"OK"` partagée entre `StatusPill` et le bouton de validation `NSAlert` : le bouton s'affiche `正常` en chinois | medium |
| P6 | `MachineRow.reasons` renvoie `[]` dès que la machine est injoignable : la ligne d'avertissement disparaît, régression vs `machineWarnings` qui rendait `["unreachable"]` | medium |
| P7 | « Last seen » rendu en heure seule : trois jours d'absence s'affichent « 14:32 » | medium |
| P8 | `lastReachableStatus`, `lastSeenAt`, `lastError` jamais purgés d'une machine retirée ; `selection` non réinitialisée quand la machine disparaît | medium |
| P9 | Table de flotte non opérable au clavier : `.onTapGesture` sans `Button`, `focusable` ni trait d'accessibilité | medium |
| P10 | `accessibilityLabel` du bouton Update figé même quand `latestTag == nil` : VoiceOver n'annonce pas pourquoi il est désactivé | low |
| P11 | Palette dupliquée : `MachineBlock.hex` (kit) et `Theme.block*` (app) portent les mêmes valeurs, `Theme.color(of:)` fait un switch au lieu de lire `block.hex` | low |
| P12 | Code mort : `ControlCenterCommands.matches`, `Theme.accentMagenta`, `Rounded.xs/full`, clé `"the latest release"` inatteignable | low |
| P13 | `raspcorse` (nom personnel) livré comme exemple dans l'état vide | low |
| P14 | `FleetRow.warnings` peuplé et asserté mais lu par aucune vue ; les assertions figent la formulation anglaise du CLI | low |

## Reportés (pré-existants, hors périmètre de la story)

| # | Constat |
|---|---|
| R1 | `App/Sources` absent du graphe SwiftPM : `swift test` ne compile jamais le code de l'app. `MachineBlockStore`, `FleetModel`, `Color(hex:)` sont structurellement non testables en l'état |
| R2 | `reloadFleet()` avale les erreurs de parsing (`try?`) : un `fleet.yaml` malformé est indistinguable d'un fichier vide |
| R3 | Aucune typographie dynamique (tailles fixes, `lineLimit(1)`, largeurs de colonnes figées) |

## Rejetés

- Absence de mode sombre — explicitement exclu par la section Never de la spec.
- Réécriture `Button("…")` → `Button { } label:` sans effet — cosmétique.

## Lacune d'intention découverte après correctifs — D3 / piles de fontes

Le correctif D3 (ne plus jeter le repli de fonte) est conforme à la matrice gelée
« Fonte absente → nom résolu = premier repli disponible de la pile documentée ».
Appliqué, il donne sur ce Mac :

| Pile | Familles réellement installées | Résolue |
|---|---|---|
| `Inter, PingFang SC, SF Pro Display, system-ui` | `PingFang SC` | **PingFang SC** |
| `JetBrains Mono, PingFang SC, SF Mono, Menlo` | `PingFang SC`, `Menlo` | **PingFang SC** |

Deux conséquences : toute l'interface française est dessinée dans une fonte chinoise, et
la pile *mono* résout une fonte **qui n'est pas à chasse fixe** — ce qui casse l'alignement
`tabular-nums` de `DataTable` et la restitution en mono du contenu machine exigée par la spec.

Cause racine : les piles de `DESIGN.md` sont des piles **CSS**, où le navigateur bascule
de fonte **glyphe par glyphe** — `PingFang SC` n'y sert qu'à couvrir les caractères chinois.
`Font.custom` de SwiftUI prend **une seule famille pour tout le texte** : transposer la pile
littéralement est un contresens.

La matrice gelée ne permet pas de trancher — elle n'a pas anticipé la différence de sémantique.
Classement : `intent_gap`, remonté à l'utilisateur.
