---
version: alpha
name: HomePort-Control-Center
status: final
created: 2026-08-23
updated: 2026-08-23
sources:
  - ../../spec-proxmox-inspired-fleet/SPEC.md
  - ../../architecture/architecture-HomePortManager-2026-08-23/ARCHITECTURE-SPINE.md
  - imports/DESIGN-figma.md
description: "Le système éditorial monochrome de l'import Figma, adapté à une console d'administration dense : chrome blanc/noir, hairlines, pastilles pill, mono pour la donnée — et les color blocks pastel réinventés en identité par machine. Un outil sérieux, fait par quelqu'un qui aime la couleur."

colors:
  primary: "#000000"
  on-primary: "#ffffff"
  ink: "#000000"
  canvas: "#ffffff"
  inverse-canvas: "#000000"
  inverse-ink: "#ffffff"
  hairline: "#e6e6e6"
  hairline-soft: "#f1f1f1"
  surface-soft: "#f7f7f5"
  block-lime: "#dceeb1"
  block-lilac: "#c5b0f4"
  block-cream: "#f4ecd6"
  block-pink: "#efd4d4"
  block-mint: "#c8e6cd"
  block-coral: "#f3c9b6"
  block-navy: "#1f1d3d"
  accent-magenta: "#ff3d8b"
  semantic-success: "#1ea64a"
  semantic-warning: "#b45309"
  semantic-critical: "#d2372f"
  overlay-scrim: "#000000"

typography:
  window-title:
    fontFamily: Inter
    fontSize: 22px
    fontWeight: 340
    lineHeight: 1.15
    letterSpacing: -0.33px
  section-title:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: 540
    lineHeight: 1.30
    letterSpacing: -0.16px
  body:
    fontFamily: Inter
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: 0
  body-strong:
    fontFamily: Inter
    fontSize: 13px
    fontWeight: 600
    lineHeight: 1.45
    letterSpacing: 0
  button:
    fontFamily: Inter
    fontSize: 13px
    fontWeight: 480
    lineHeight: 1.40
    letterSpacing: -0.06px
  eyebrow:
    fontFamily: JetBrains Mono
    fontSize: 11px
    fontWeight: 400
    lineHeight: 1.30
    letterSpacing: 0.55px
  data:
    fontFamily: JetBrains Mono
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.50
    letterSpacing: 0
  caption:
    fontFamily: JetBrains Mono
    fontSize: 10px
    fontWeight: 400
    lineHeight: 1.20
    letterSpacing: 0.50px

rounded:
  xs: 2px
  sm: 6px
  md: 8px
  lg: 16px
  pill: 50px
  full: 9999px

spacing:
  hair: 1px
  xxs: 4px
  xs: 8px
  sm: 12px
  md: 16px
  lg: 24px
  xl: 32px

components:
  sidebar-row:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.sm}"
    padding: 6px 10px
  sidebar-row-selected:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.sm}"
    padding: 6px 10px
  machine-banner:
    backgroundColor: "{colors.block-lime}"
    textColor: "{colors.ink}"
    typography: "{typography.window-title}"
    rounded: "{rounded.lg}"
    padding: 16px 24px
  status-pill-ok:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.semantic-success}"
    typography: "{typography.eyebrow}"
    rounded: "{rounded.pill}"
    padding: 2px 10px
  status-pill-warning:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.semantic-warning}"
    typography: "{typography.eyebrow}"
    rounded: "{rounded.pill}"
    padding: 2px 10px
  status-pill-critical:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.semantic-critical}"
    typography: "{typography.eyebrow}"
    rounded: "{rounded.pill}"
    padding: 2px 10px
  tab-default:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: 5px 14px
  tab-selected:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: 5px 14px
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: 6px 16px
  button-secondary:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: 6px 16px
  button-destructive:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.semantic-critical}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: 6px 16px
  data-table:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.data}"
    rounded: "{rounded.md}"
  log-viewer:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.ink}"
    typography: "{typography.data}"
    rounded: "{rounded.md}"
    padding: 12px
  terminal-panel:
    backgroundColor: "{colors.inverse-canvas}"
    textColor: "{colors.inverse-ink}"
    typography: "{typography.data}"
    rounded: "{rounded.md}"
    padding: 12px
  metric-card:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: 16px
  empty-state:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.lg}"
    padding: 32px
  toast:
    backgroundColor: "{colors.inverse-canvas}"
    textColor: "{colors.inverse-ink}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: 10px 16px
---

## Overview

Le centre de contrôle HomePortManager hérite du système éditorial de l'import Figma (`imports/DESIGN-figma.md`) et l'adapte à une console d'administration dense. Le chrome reste rigoureusement monochrome — canvas blanc `{colors.canvas}`, encre noire `{colors.ink}`, hairlines, CTAs pill — et la donnée parle en mono `{typography.data}`. La signature pastel du système est réinventée : **chaque machine de la flotte possède son color block** (bandeau de fiche + pastille sidebar), transformant la joie décorative du système source en repère fonctionnel. Thème clair uniquement en v1.

**Key Characteristics:**
- Chrome monochrome : noir/blanc porte toute l'interface ; la couleur n'apparaît que pour identifier (blocks machine) ou signaler (sémantique).
- Échelle typographique « app » : corps 13px, données 12px mono — dérivée de la voix du système source (poids fins 340/480/540, tracking négatif sur les titres, mono = taxonomie et donnée).
- Un block pastel par machine, assigné à l'ajout dans l'ordre : lime, cream, lilac, mint, pink, coral (navy réservé — surface sombre).
- Sémantique en glyphes et pills, jamais en surfaces pleines : `{colors.semantic-success}` / `{colors.semantic-warning}` / `{colors.semantic-critical}`.
- Pill = seule forme de bouton et d'onglet ; sélection = surface primaire noire (le pattern « selected = primary » du système source).

## Colors

### Brand & Accent
- **Black** ({colors.primary}) : CTAs primaires, onglet sélectionné, ligne sidebar sélectionnée, panneau terminal.
- **White** ({colors.on-primary}) : texte inverse sur surfaces noires.
- **Magenta** ({colors.accent-magenta}) : réservé — au plus un usage promotionnel ponctuel (ex. bandeau de nouvelle version disponible). Jamais un état.

### Surface
- **Canvas** ({colors.canvas}) : fond de fenêtre et de tout contenu.
- **Surface Soft** ({colors.surface-soft}) : visionneuse de logs, états vides, tuiles.
- **Hairline / Hairline Soft** ({colors.hairline} / {colors.hairline-soft}) : bordures de tables, séparateurs de lignes, cartes.
- **Blocks machine** ({colors.block-lime}, {colors.block-cream}, {colors.block-lilac}, {colors.block-mint}, {colors.block-pink}, {colors.block-coral}) : identité stable par machine — bandeau `{components.machine-banner}` et pastille 8px dans la sidebar. Assignés à l'ajout de la machine, jamais réassignés. raspcorse = lime, raspyellow = cream. `[ASSUMPTION]` l'assignation des deux machines existantes.
- **Block Navy** ({colors.block-navy}) : hors rotation machine — surface sombre disponible pour un moment éditorial (onboarding, à-propos).

### Semantic
- **Success** ({colors.semantic-success}) : santé OK, job réussi, check.
- **Warning** ({colors.semantic-warning}) : dégradé, API non disponible, drift doctor, disque qui se remplit.
- **Critical** ({colors.semantic-critical}) : healthz KO, job échoué, machine injoignable, action destructive.
- Les trois tiennent le contraste AA sur `{colors.canvas}` et sur chaque block pastel ; toujours en glyphe, texte ou pill — jamais en fond de section.

## Typography

### Font Family
- **Inter** (variable) — stack : `Inter, PingFang SC, SF Pro Display, system-ui`. Poids retenus : 340, 400, 480, 540, 600.
- **JetBrains Mono** — stack : `JetBrains Mono, PingFang SC, SF Mono, Menlo`. Données, eyebrows, captions — jamais un paragraphe.
- Le fallback **PingFang SC** (natif macOS) couvre le chinois simplifié : aucune fonte CJK embarquée. `[ASSUMPTION]` PingFang SC accepté comme voix CJK.

### Hierarchy

| Token | Taille | Poids | Usage |
|---|---|---|---|
| `{typography.window-title}` | 22px | 340 | Nom de machine dans le bandeau, titre de la vue flotte |
| `{typography.section-title}` | 16px | 540 | Titres de sections et de cartes |
| `{typography.body}` | 13px | 400 | Corps par défaut |
| `{typography.body-strong}` | 13px | 600 | Emphase (le poids porte la hiérarchie, jamais un gris) |
| `{typography.button}` | 13px | 480 | Boutons pill et onglets |
| `{typography.data}` | 12px | 400 | Tables, logs, terminal, valeurs de métriques — tabular-nums |
| `{typography.eyebrow}` | 11px | 400 | Labels mono uppercase : états, catégories, pills |
| `{typography.caption}` | 10px | 400 | Horodatages, légendes de graphes |

## Layout & Spacing

- Base 8px ; tokens `{spacing.*}` (1/4/8/12/16/24/32).
- Sidebar : 220px, lignes `{components.sidebar-row}` hauteur 28px.
- Bandeau machine : `{components.machine-banner}`, padding 16px 24px, coins `{rounded.lg}` — le seul aplat de couleur de la vue.
- Contenu d'onglet : padding `{spacing.lg}`, sections espacées de `{spacing.xl}`.
- Tables : lignes 26px, séparateurs `{colors.hairline-soft}`, en-têtes `{typography.eyebrow}`.
- Le blanc respire : jamais deux blocks pastel visibles côte à côte hors sidebar (pastilles exemptées).

## Elevation & Depth

| Niveau | Traitement | Usage |
|---|---|---|
| 0 | aucun | Bandeaux machine, contenus, sidebar |
| 1 | bordure 1px `{colors.hairline}` | Cartes métriques, tables, inputs |
| 2 | ombre 0 4px 16px rgba(0,0,0,0.06) | Popovers, menus |
| 3 | ombre + `{colors.overlay-scrim}` ~60% | Confirmations destructives (sheet) |

La couleur (block machine) est le dispositif de profondeur ; l'ombre reste l'exception.

## Shapes

- `{rounded.sm}` 6px : lignes sidebar, chips. `{rounded.md}` 8px : cartes, logs, terminal, inputs. `{rounded.lg}` 16px : bandeau machine, états vides. `{rounded.pill}` : boutons et onglets. `{rounded.full}` : pastilles machine (8px) et glyphes d'état.
- Aucun bouton carré ; aucune photo/avatar.

## Components

- **`sidebar-row` / `sidebar-row-selected`** — nom de machine + pastille block 8px `{rounded.full}` + pill d'état à droite. Sélection = surface primaire (pattern « selected = primary »).
- **`machine-banner`** — bandeau de fiche machine : block pastel de la machine, nom en `{typography.window-title}`, host mono en `{typography.data}`, pill d'état. Le `backgroundColor` documenté (lime) est la variante par défaut ; chaque machine substitue son `{colors.block-*}`.
- **`status-pill-ok` / `-warning` / `-critical`** — état en un coup d'œil : fond canvas, texte sémantique, bordure 1px de la même couleur à 25%.
- **`tab-default` / `tab-selected`** — les 7 onglets (Résumé, Logs, Événements, Métriques, Backups, Shell, Updates) en pills.
- **`button-primary` / `button-secondary` / `button-destructive`** — pattern noir/blanc du système ; le destructif reste blanc à texte `{colors.semantic-critical}` et n'obtient un fond rouge que dans la sheet de confirmation.
- **`data-table`** — flotte, journal des tâches, jobs de backup : mono 12px, tabular-nums, en-têtes eyebrow.
- **`log-viewer`** — surface `{colors.surface-soft}`, mono, suivi continu ; lignes critical teintées texte `{colors.semantic-critical}`.
- **`terminal-panel`** — le seul aplat noir du contenu : SwiftTerm, coins `{rounded.md}`.
- **`metric-card`** — carte hairline : titre eyebrow, valeur courante en `{typography.section-title}`, graphe Swift Charts ; courbe encre, remplissage 8%, grille `{colors.hairline-soft}`.
- **`empty-state`** — surface douce `{rounded.lg}`, message `{typography.body}`, action pill : c'est ici (et seulement ici) que la voix pastel peut sourire.
- **`toast`** — confirmation transitoire noire, coin bas droit.

## Do's and Don'ts

### Do
- Un block pastel = une machine, pour toujours ; la couleur identifie avant d'orner.
- Le poids porte la hiérarchie du texte ; l'état porte la couleur sémantique.
- Mono pour toute donnée (chemins, versions, tailles, horodatages), Inter pour toute phrase.
- Sélection = surface primaire noire, partout (sidebar, onglets).
- Revenir au blanc entre deux moments colorés.

### Don't
- Pas de gris moyen pour le texte secondaire — poids 400 vs 600, jamais l'opacité.
- Pas de surfaces pleines en couleur sémantique ; pas d'état exprimé par un block pastel.
- Pas de nouvelle couleur hors palette ; le magenta n'est jamais un état.
- Pas d'ombres sur les bandeaux machine.
- Pas de mono en paragraphe ; pas de bouton carré.
- Pas de dark mode improvisé en v1 — `{colors.block-navy}` est le seul moment sombre autorisé.
