---
stepsCompleted: [1, 2, 3, 4]
inputDocuments:
  - docs/specs/spec-proxmox-inspired-fleet/SPEC.md
  - docs/specs/spec-proxmox-inspired-fleet/brownfield.md
  - docs/specs/spec-proxmox-inspired-fleet/stories.yaml
  - docs/specs/architecture/architecture-HomePortManager-2026-08-23/ARCHITECTURE-SPINE.md
  - docs/specs/ux-designs/ux-HomePortManager-2026-08-23/DESIGN.md
  - docs/specs/ux-designs/ux-HomePortManager-2026-08-23/EXPERIENCE.md
---

# HomePortManager - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for HomePortManager (chantier « centre de contrôle unifié »), decomposing the requirements from the SPEC package and Architecture spine into implementable stories.

## Requirements Inventory

### Functional Requirements

FR1: Un tableau de bord global affiche l'état de toute la flotte (santé, version, disque, âge du dernier backup) pour chaque machine de `fleet.yaml`, sans connexion manuelle à chaque machine. (CAP-1)
FR2: L'utilisateur sélectionne un Homeport et pilote les actions hpm — update, restart, backup, restore, config, doctor — depuis la console ; les actions destructives exigent une confirmation explicite. (CAP-2)
FR3: Le dashboard web propre de chaque Homeport s'ouvre intégré dans la console depuis la fiche machine, sans changer d'application. (CAP-3)
FR4: Les logs de n'importe quelle machine sont consultables et suivis en continu depuis la console, filtrables par machine et par texte, sans SSH manuel. (CAP-4)
FR5: Les événements côté machine (healthz KO, service redémarré, disque qui se remplit) remontent dans la console sans intervention ; les événements critiques déclenchent une notification macOS, les non-critiques n'en produisent pas. (CAP-5)
FR6: Chaque action menée sur la flotte via le centre est historisée centralement (horodatage, machine, action, statut, sortie) dans un journal des tâches consultable. (CAP-6)
FR7: Des jobs de backup programmés s'exécutent sur le Pi à l'heure dite, Mac éteint, avec rétention ; leurs résultats et archives apparaissent consolidés côté Mac ensuite, et une vue centrale montre les jobs et leurs derniers résultats. (CAP-7)
FR8: Des graphes CPU / RAM / disque / température par machine sont consultables avec historique, y compris pour des plages où la console était fermée. (CAP-8)
FR9: Un shell interactif vers la machine choisie s'ouvre en un geste depuis la console. (CAP-9)
FR10: La console montre par machine la version Homeport installée vs la dernière release taguée, et permet de déclencher l'update. (CAP-10)
FR11: Chaque capacité est exposée en CLI (`hpm events`, `hpm tasks`, `hpm backup jobs`, `hpm metrics`…) avant ou en même temps que dans l'app. (AD-13)

### NonFunctional Requirements

NFR1: App macOS native (SwiftUI, extension de l'existant) ; un seul livrable — l'app menubar existante ouvre la fenêtre centre de contrôle ; un seul DMG signé/notarisé (pipeline existant).
NFR2: Métriques et événements sont collectés via l'API de Homeport (pas d'agent dédié sur les Pi) ; la console dégrade proprement face à un Homeport sans l'API — trois états distincts : disponible, non disponible, injoignable.
NFR3: Backups planifiés côté Pi (systemd timer), indépendants du Mac ; le centre configure, consolide les résultats et rapatrie.
NFR4: Socle HomePortKit réutilisé ; SSH depuis le Mac pour les actions ; identité SSH par machine issue de `fleet.yaml` pour tous les canaux.
NFR5: Pas de secrets dans `fleet.yaml` ni la config hpm ; healthz vérifié via SSH sur la machine ; seules les versions taguées de Homeport sont déployables ; accès réseau limité au tailnet (le tailnet est l'authentification en v1).
NFR6: Flotte petite (< ~10 machines) — pas d'exigence de scalabilité au-delà ; intervalle de pull 30-60 s suffisant.
NFR7: Rétention bornée partout : métriques multi-échelles côté Pi (24h@1min, 7j@5min, 30j@1h, 1an@1j), journal des tâches purgé au-delà de 1 an / 10 000 entrées, rotations de backups 3 (Pi) / 10 (Mac).

### Additional Requirements

- Contrat API inter-repos versionné (AD-4) : source de vérité dans le repo Homeport, copie épinglée `docs/api/` ; `GET /api/capabilities` renvoie version, features et epoch ; le story-spec de la story « événements » rédige seul la v1 complète (capabilities + events + metrics).
- Événements en pull avec curseur (epoch, id) persisté côté Mac ; curseur de lecture et marqueur `notified_up_to` distincts ; décision de notification dans HomePortKit (AD-5).
- Un propriétaire unique par donnée (AD-6) ; état central Mac dans `~/.local/state/hpm/hpm.db` (SQLite WAL, `busy_timeout`), écrit exclusivement via `HistoryStore` ; schéma possédé par la story « journal », étendu par migrations `PRAGMA user_version` (AD-7).
- Verrou de mutation inter-process persistant dans hpm.db (une mutation à la fois par machine, CLI + app) ; flock partagé côté Pi entre timer de backup et actions hpm (AD-12).
- Script de backup Pi root et autonome : data dir résolu localement, mqtt.env inclus, backup Homeport natif si disponible sinon générique, archives atomiques (tmp + mv) ; précondition sudo NOPASSWD vérifiée par doctor avant déploiement (AD-9).
- Consolidation opportuniste au refresh + explicite (`hpm backup sync`), single-flight par machine (AD-11) ; les exécutions du timer Pi se racontent en événements, le journal Mac ne consigne que les actions initiées par le Mac (AD-16).
- Exception App Transport Security unique dans Info.plist, partagée URLSession + WKWebView (AD-3).
- Fenêtre en NavigationSplitView, même process que la menubar, un seul `FleetModel` `@MainActor` (AD-15).
- Shell = canal d'évasion assumé : pas de verrou, pas de journal détaillé, identité fleet.yaml obligatoire, une entrée informative à l'ouverture (AD-17) ; SwiftTerm épinglé 1.19.0, SSH via `LocalProcessTerminalView` + `/usr/bin/ssh`.
- Une seule politique de notification par machine : événements critical si l'API est disponible, sinon fallback sur les transitions existantes de la menubar — jamais les deux.
- Graphes en Swift Charts natif (macOS 13+) ; `Package.resolved` committé fait foi ; pas de starter template (brownfield sur socle v1.0.0 existant).

### UX Design Requirements

Contrat UX : `ux-designs/ux-HomePortManager-2026-08-23/` (DESIGN.md + EXPERIENCE.md, finaux).

UX-DR1: Implémenter les design tokens de DESIGN.md comme source unique de style SwiftUI : palette (canvas/ink/hairlines/blocks/sémantique), typographie Inter + JetBrains Mono avec fallback CJK PingFang SC, échelles rounded et spacing. Thème clair seul.
UX-DR2: Construire les composants réutilisables de DESIGN.md : `sidebar-row`(+selected), `machine-banner`, `status-pill-ok/-warning/-critical`, `tab-default/-selected`, `button-primary/-secondary/-destructive`, `data-table`, `log-viewer`, `terminal-panel`, `metric-card`, `empty-state`, `toast`.
UX-DR3: Identité par machine : block pastel stable assigné à l'ajout (raspcorse = lime, raspyellow = cream), porté par la pastille sidebar (8px) et le bandeau de fiche ; jamais réassigné.
UX-DR4: i18n trilingue (français, anglais, chinois simplifié) via String Catalogs dès la première story UI ; aucune chaîne en dur ; formats dates/tailles/durées via FormatStyle ; hauteurs de ligne vérifiées en zh-Hans ; notifications localisées ; contenu machine (logs, sorties) jamais traduit.
UX-DR5: Trois états API par machine avec empty-states rédigés par onglet : « non disponible » guide vers Updates (jamais une erreur), « injoignable » conserve les dernières données avec mention « Vu pour la dernière fois à HH:MM ».
UX-DR6: Confirmations destructives en sheet : titre au verbe, conséquence en une phrase, nom de machine répété, bouton destructif à fond `semantic-critical` (seul endroit avec fond rouge).
UX-DR7: Accessibilité plancher : navigation clavier complète (⌘1-7 onglets, ⌘F filtre, ⌘R refresh), focus visible, labels VoiceOver sur actions et pills, couleur jamais seule porteuse d'état (pill = couleur + libellé), `prefers-reduced-motion` respecté.
UX-DR8: Comportements verrou : pendant une mutation, boutons d'action de la machine désactivés + indicateur dans le bandeau, lectures actives ; suivi de logs auto-suspendu quand l'utilisateur remonte (bouton « Reprendre ») ; au plus une session shell par machine.
UX-DR9: Notification macOS sur événement critical uniquement, localisée ; le clic ouvre la fiche machine sur l'onglet Événements.

### FR Coverage Map

FR1: Epic 1 — tableau de bord global (vue Flotte)
FR2: Epic 1 — actions machine avec confirmations
FR3: Epic 1 — dashboard Homeport intégré (WebView)
FR4: Epic 1 — logs centralisés
FR6: Epic 1 — journal des tâches (porte le schéma hpm.db)
FR5: Epic 2 — événements + notifications critiques
FR8: Epic 2 — métriques historisées
FR7: Epic 3 — backups planifiés côté Pi
FR9: Epic 3 — shell intégré
FR10: Epic 3 — gestion des mises à jour
FR11: transversal — la commande CLI correspondante est nommée dans les critères d'acceptation de chaque story concernée (jamais une story UI sans sa jumelle CLI)

**Couverture story par story :** FR1 → 1.1 · FR6 → 1.2 · FR2 → 1.3 · FR3 → 1.4 · FR4 → 1.5 · FR5 → 2.1 + 2.2a + 2.2b · FR8 → 2.3 · FR7 → 3.1 + 3.2 · FR10 → 3.3 · FR9 → 3.4 · FR11 → 1.2, 1.3, 1.5, 2.1, 2.2a, 2.3, 3.1, 3.2, 3.3.
**UX-DR :** UX-DR1/3/4/7 → 1.1 · UX-DR2 → 1.1, 1.3, 1.5, 2.3, 3.2, 3.4 · UX-DR5 → 1.1, 1.4, 2.2a, 2.2b, 2.3 · UX-DR6 → 1.3, 3.3 · UX-DR8 → 1.3, 1.5, 3.4 · UX-DR9 → 2.2b.

## Epic List

### Epic 1: Piloter la flotte depuis une seule fenêtre
Vincent ouvre le centre de contrôle et administre toute la flotte sans terminal : vue d'ensemble, fiche machine, actions hpm confirmées, dashboard Homeport intégré, logs suivis, chaque action tracée. La console est utilisable et utile à elle seule à la fin de cet epic.
**FRs covered:** FR1, FR2, FR3, FR4, FR6 (+ FR11)
**Stories** : 1.1 fenêtre + tableau de bord · 1.2 journal + socle hpm.db · 1.3 actions machine · 1.4 dashboard intégré · 1.5 logs.
**Ordre interne (amendement party mode)** : le journal (1.2) précède les actions (1.3) car le verrou AD-12 vit dans le schéma hpm.db possédé par la story journal (AD-7).
**Notes** : UX-DR1 (tokens) et UX-DR4 (i18n trilingue, String Catalogs) sont des critères d'acceptation de la première story, pas des vœux transversaux.

### Epic 2: La flotte se raconte toute seule
Les événements Homeport remontent sans intervention (notification macOS sur les critiques) et les métriques historisées se consultent en graphes. S'appuie sur l'epic 1 ; dégrade proprement face à un Homeport sans API.
**FRs covered:** FR5, FR8 (+ FR11)
**Stories** : 2.1 contrat API v1 · 2.2a flux d'événements + onglet Événements · 2.2b notifications critiques + politique de repli · 2.3 métriques historisées.
**Notes** : 🚧 **jalon bloquant levé le 28/08** — l'API v1 est mergée et releasée (Homeport v0.8.0), en prod sur raspcorse. Le contrat est né en 2.1 (close). **Story 2.2 scindée en 2.2a/2.2b le 28/08** (`bmad-loop`, timeout de session 90 min + budget de tokens dépassés sur le périmètre unifié, aucun code committé) : 2.2a porte `HomeportAPIClient`, le curseur `(epoch, id)`, l'onglet Événements à 3 états et `hpm events` ; 2.2b (dépend de 2.2a) porte la décision de notifier, `notified_up_to`, le repli menubar single-policy et la navigation clic-notification. UX-DR5, UX-DR9.

### Epic 3: La flotte s'entretient sans le Mac
Backups planifiés exécutés sur les Pi Mac éteint (consolidés au réveil), gestion des mises à jour depuis la console, shell intégré en dernier recours. S'appuie sur les epics 1-2 (les jobs se racontent en événements) mais complet en lui-même.
**FRs covered:** FR7, FR9, FR10 (+ FR11)
**Stories** : 3.1 déploiement des jobs · 3.2 consolidation + vue · 3.3 mises à jour · 3.4 shell intégré.
**Notes** : AD-9..AD-11, AD-16, AD-17 ; SwiftTerm 1.19.0 épinglé ; précondition sudo vérifiée avant tout déploiement.

## Epic 1: Piloter la flotte depuis une seule fenêtre

Vincent administre toute la flotte sans terminal : vue d'ensemble, fiche machine, actions confirmées, dashboard intégré, logs suivis, chaque action tracée.

### Story 1.1: Fenêtre centre de contrôle et tableau de bord global

As a administrateur de flotte,
I want ouvrir depuis la menubar une fenêtre montrant l'état de toutes mes machines,
So that je vois la santé de la flotte d'un coup d'œil sans SSH ni navigation machine par machine.

**Acceptance Criteria:**

**Given** l'app installée avec 2 machines dans `fleet.yaml`
**When** Vincent clique « Ouvrir le centre de contrôle » dans la menubar
**Then** une fenêtre NavigationSplitView (min 900×600) s'ouvre — sidebar « Flotte » + une entrée par machine (pastille block pastel stable, nom, pill d'état)
**And** menubar et fenêtre partagent le même `FleetModel` @MainActor (AD-15).

**Given** un premier lancement avec `fleet.yaml` absent ou sans machine
**When** la fenêtre s'ouvre
**Then** un état vide accueillant remplace la table : ce qu'est le centre de contrôle en une phrase, et comment déclarer une première machine (emplacement du fichier, exemple minimal, commande `hpm` correspondante)
**And** aucune erreur ni sidebar vide muette.

**Given** une machine nouvellement ajoutée à `fleet.yaml`
**When** elle apparaît pour la première fois dans la console
**Then** elle reçoit le prochain block pastel libre dans l'ordre documenté (lime, cream, lilac, mint, pink, coral), enregistré durablement
**And** l'assignation ne change jamais ensuite — ni au retrait d'une autre machine, ni au renommage, ni entre deux lancements (UX-DR3).

**Given** la vue Flotte affichée
**When** le refresh périodique (5 min) ou manuel (⌘R) s'exécute
**Then** la table montre par machine : état (pill ok/warning/critical), version, disque, âge du dernier backup
**And** une machine injoignable garde ses dernières données avec « Vu pour la dernière fois à HH:MM » (UX-DR5).

**Given** le design system DESIGN.md
**When** toute vue de cette story se rend
**Then** les tokens (Inter + JetBrains Mono + fallback PingFang SC, palette, pills) sont l'unique source de style (UX-DR1)
**And** aucune chaîne en dur : String Catalogs fr/en/zh-Hans, langue système, défaut anglais (UX-DR4).

**Given** un utilisateur au clavier ou sous VoiceOver
**When** il navigue dans la fenêtre
**Then** sidebar et onglets sont atteignables au clavier (⌘1-8 pour les huit onglets, ⌘F, ⌘R), le focus est visible, les actions et pills portent un label VoiceOver, et aucun état n'est porté par la couleur seule (UX-DR7).

### Story 1.2: Journal des tâches et socle hpm.db

As a administrateur de flotte,
I want que chaque action menée sur la flotte soit historisée et consultable,
So that je sais toujours qui a fait quoi, quand, et avec quel résultat.

**Acceptance Criteria:**

**Given** HomePortKit
**When** la story est livrée
**Then** `~/.local/state/hpm/hpm.db` existe (SQLite WAL, `busy_timeout`, `PRAGMA user_version=1`), créée et écrite exclusivement par `HistoryStore` (AD-7)
**And** le schéma initial couvre journal des tâches et table de verrous — verrou porteur de son détenteur (PID) et de son horodatage de prise (AD-12) ; les extensions ultérieures passent par migration.

**Given** une action exécutée via le kit (CLI ou app)
**When** elle se termine (succès ou échec)
**Then** une entrée journal est enregistrée : horodatage ISO 8601 UTC, machine, action, statut, sortie.

**Given** le CLI
**When** `hpm tasks` (option `--machine <nom>`)
**Then** le journal s'affiche filtré, du plus récent au plus ancien (FR11)
**And** dans l'app, le Résumé machine montre ses tâches récentes et la vue Flotte l'historique global.

**Given** un journal de plus de 1 an ou 10 000 entrées
**When** l'app démarre (l'app seule — le CLI, outil ponctuel, ne fait jamais le ménage)
**Then** les entrées excédentaires sont purgées (NFR7).

### Story 1.3: Actions machine avec confirmations

As a administrateur de flotte,
I want déclencher les actions hpm sur une machine depuis sa fiche,
So that j'administre sans terminal, avec des garde-fous sur le destructif.

**Acceptance Criteria:**

**Given** une machine sélectionnée
**When** Vincent déclenche Backup, Restart, Doctor ou Config depuis le Résumé
**Then** l'action s'exécute via HomePortKit avec l'identité SSH de `fleet.yaml`, son résultat s'affiche et atterrit au journal (story 1.2).

**Given** une action destructive (restore, remove, update)
**When** elle est déclenchée
**Then** une sheet de confirmation s'affiche : titre au verbe, conséquence en une phrase, nom de la machine répété, bouton à fond `semantic-critical` (UX-DR6).

**Given** une mutation en cours sur une machine
**When** une autre mutation est tentée — depuis l'app OU le CLI
**Then** elle est refusée proprement via le verrou persistant de hpm.db (AD-12)
**And** les boutons d'action de la machine sont désactivés avec indicateur « … en cours » dans le bandeau ; les lectures restent actives (UX-DR8).

**Given** un verrou laissé par un process mort (crash, kill) ou pris depuis plus de 30 min
**When** une nouvelle action est tentée sur cette machine
**Then** le verrou est détecté périmé, repris automatiquement, et la tâche interrompue est close en `interrupted` au journal — la machine ne devient jamais inadministrable (AD-12)
**And** `hpm unlock <machine>` ne libère qu'un verrou réellement périmé : si le détenteur est vivant, la commande refuse et affiche qui tient le verrou et depuis quand — jamais de déverrouillage d'une opération en cours.

**Given** le CLI existant
**When** une commande mutante s'exécute
**Then** elle acquiert le même verrou et journalise pareil (FR11 — parité par construction).

### Story 1.4: Dashboard Homeport intégré

As a administrateur de flotte,
I want ouvrir le dashboard web de chaque Homeport dans la console,
So that je passe de la gestion à l'usage sans changer d'application.

**Acceptance Criteria:**

**Given** une machine dont le dashboard répond sur le tailnet
**When** Vincent ouvre l'onglet Dashboard de sa fiche
**Then** une WebView charge le dashboard, utilisable (navigation interne, saisie)
**And** l'accès HTTP passe par l'exception ATS unique d'Info.plist (AD-3), partagée avec le futur client API.

**Given** une machine injoignable
**When** l'onglet Dashboard s'ouvre
**Then** un empty-state « injoignable » s'affiche avec action « Réessayer » — jamais une page d'erreur WebKit brute (UX-DR5).

### Story 1.5: Logs centralisés

As a administrateur de flotte,
I want lire et suivre les logs de n'importe quelle machine dans la console,
So that je diagnostique sans ouvrir un terminal SSH.

**Acceptance Criteria:**

**Given** une machine sélectionnée
**When** l'onglet Logs s'ouvre
**Then** les dernières lignes s'affichent dans le log-viewer (mono, sélection/copie possibles) avec suivi continu commutable
**And** les lignes d'erreur sont teintées `semantic-critical`.

**Given** le suivi continu actif
**When** Vincent fait défiler vers le haut
**Then** le suivi se suspend et un bouton « Reprendre le suivi » apparaît (UX-DR8).

**Given** un filtre texte saisi (⌘F)
**When** les logs défilent
**Then** seules les lignes correspondantes s'affichent, en flux comme en historique.

**Given** le CLI
**When** `hpm logs <machine>` (et `-f`)
**Then** le comportement v1.1 existant est préservé — la parité était déjà acquise (FR11).

## Epic 2: La flotte se raconte toute seule

Les événements remontent sans intervention, les métriques se consultent en graphes ; tout dégrade proprement sans l'API.

> 🚧 **Jalon bloquant — chantier miroir Homeport.** Le contrat API v1 est rédigé ici (story 2.1) mais son **implémentation serveur vit dans le repo Homeport**, hors de ce backlog. Aucune story de cet epic ne peut être clôturée tant que l'API n'est pas live sur au moins une machine de test. Le contrat est rédigeable dès la fin de l'epic 1 : ouvrir le chantier Homeport en parallèle, c'est le chemin critique du planning.

### Story 2.1: Contrat API v1 et flux d'événements

As a administrateur de flotte,
I want voir dans la console les événements que chaque machine a enregistrés,
So that je découvre ce qui s'est passé sur la flotte sans me connecter à chaque Pi.

**Acceptance Criteria:**

**Given** le story-spec de cette story
**When** il est rédigé
**Then** il contient le contrat API v1 complet (capabilities + events + metrics, semver, epoch d'historique) — rédacteur unique (AD-4)
**And** la copie épinglée existe sous `docs/api/` et hpm déclare la plage de versions qu'il consomme.

**Given** un Homeport exposant l'API
**When** `HomeportAPIClient` interroge `capabilities` puis `events?since=<curseur>` (30-60 s)
**Then** les nouveaux événements apparaissent dans l'onglet Événements (sévérité en pill, filtre par sévérité), curseur (epoch, id) persisté par machine dans hpm.db
**And** après un restore côté Pi (epoch changé), le client détecte le nouvel epoch et repart de son début, sans erreur ni perte silencieuse (AD-5).

**Given** le CLI
**When** `hpm events [--machine <nom>] [--severity <niveau>]`
**Then** les événements s'affichent filtrés (FR11).

### Story 2.2a: Flux d'événements et onglet Événements

> Scindée le 28/08 depuis l'ex-story 2.2 (`bmad-loop` a dépassé sa limite de session de 90 min et
> son budget de tokens sur le périmètre unifié client+notifications, sans rien committer). Porte le
> flux lui-même ; 2.2b porte la décision de notifier par-dessus.

As a administrateur de flotte,
I want voir dans la console les événements que chaque machine a enregistrés,
So that je découvre ce qui s'est passé sur la flotte sans me connecter à chaque Pi.

**Acceptance Criteria:**

**Given** un Homeport exposant l'API
**When** `HomeportAPIClient` interroge `capabilities` puis `events?since=<curseur>` (30-60 s)
**Then** les nouveaux événements apparaissent dans l'onglet Événements (sévérité en pill, filtre par sévérité), curseur (epoch, id) persisté par machine dans hpm.db
**And** après un restore côté Pi (epoch changé, ou `latest_id` inférieur au curseur), le client détecte l'anomalie et repart du début du nouvel epoch, sans erreur ni perte silencieuse (AD-5)
**And** tant que `has_more` est vrai, la lecture pagine jusqu'à `has_more == false` avant de retenir la fenêtre la plus récente — jamais bloquée sur les événements les plus anciens d'un epoch qui dépasse `limit` (leçon retenue de la 1ʳᵉ tentative, cf. `deferred-work.md`).

**Given** une machine dont Homeport n'a pas l'API (404 ou version hors plage, ou `events` absent de `features`)
**When** l'onglet Événements s'ouvre
**Then** empty-state « Cette version de Homeport ne fournit pas encore les événements » avec pill vers Updates — jamais une erreur (UX-DR5).

**Given** une machine injoignable (erreur réseau ou 5xx)
**When** l'onglet Événements s'ouvre
**Then** l'état affiché est « injoignable » (pill critical), distinct de « non disponible », avec les derniers événements connus et « Vu pour la dernière fois à HH:MM ».

**Given** le CLI
**When** `hpm events [--machine <nom>] [--severity <niveau>]`
**Then** les événements s'affichent filtrés, avec exactement le même contenu que l'onglet correspondant (AD-13/FR11).

### Story 2.2b: Notifications critiques et politique de repli

> Scindée le 28/08 depuis l'ex-story 2.2 ; dépend de **2.2a** (le flux d'événements et son curseur
> doivent exister avant que la décision de notifier puisse s'y brancher).

As a administrateur de flotte,
I want être notifié des incidents graves et ne jamais recevoir deux fois la même alerte,
So that j'apprends les pannes sans surveiller, et une machine ne relève jamais de deux politiques de notification à la fois.

**Acceptance Criteria:**

**Given** un événement `critical` reçu (2.2a) et un marqueur `notified_up_to` déjà établi pour cette machine
**When** l'`id` de l'événement dépasse `notified_up_to`
**Then** une notification macOS localisée part ; le clic ouvre la fiche machine sur l'onglet Événements ; les non-critiques n'en produisent pas (UX-DR9)
**And** la décision de notifier vit dans HomePortKit, et `hpm events` peut avancer la lecture sans jamais faire perdre une notification — lecture et notification sont deux marqueurs distincts (AD-5).

**Given** une machine sans marqueur `notified_up_to` stocké (premier pull, ou machine qui vient de gagner `events` dans ses `features`)
**When** ce premier pull s'exécute, même si sa première page contient déjà des événements `critical`
**Then** `notified_up_to` s'initialise silencieusement au plus grand `id` reçu — aucune notification rétroactive sur un historique déjà peuplé (même doctrine que `transitions(old: nil) -> []`, leçon retenue de la 1ʳᵉ tentative).

**Given** une machine dont Homeport n'a pas l'API, ou dont `events` est absent de `features` (2.2a)
**When** les notifications de cette machine sont évaluées
**Then** elles retombent sur les transitions menubar existantes — jamais les deux politiques à la fois pour une même machine.

### Story 2.3: Métriques historisées

As a administrateur de flotte,
I want des graphes CPU, RAM, disque et température par machine avec historique,
So that je comprends les tendances même pour les périodes où la console était fermée.

**Acceptance Criteria:**

**Given** un Homeport exposant l'API métriques
**When** l'onglet Métriques s'ouvre
**Then** 4 metric-cards (CPU, RAM, disque, température) rendent en Swift Charts avec sélecteur de plage 24 h / 7 j / 30 j / 1 an
**And** l'API sert l'échelle adaptée à la plage (AD-8) et les plages couvrent les périodes console fermée (l'historique vit sur le Pi, AD-6).

**Given** une machine sans l'API
**When** l'onglet s'ouvre
**Then** empty-state guidant vers Updates (UX-DR5) — le contrat consommé sans extension (AD-4).

**Given** le CLI
**When** `hpm metrics <machine> [--range 24h|7d|30d|1y]`
**Then** les valeurs s'affichent en table mono (FR11).

## Epic 3: La flotte s'entretient sans le Mac

Backups planifiés autonomes sur les Pi, mises à jour pilotées depuis la console, shell de dernier recours.

### Story 3.1: Déploiement des jobs de backup planifiés

As a administrateur de flotte,
I want déclarer un planning de sauvegarde et le déployer sur une machine,
So that le Pi se sauvegarde tout seul, même quand mon Mac est éteint.

**Acceptance Criteria:**

**Given** une définition de job (planning, rétention) déclarée dans la config hpm côté Mac (AD-10)
**When** Vincent l'applique (`hpm backup apply <machine>`)
**Then** la précondition sudo NOPASSWD est vérifiée d'abord — refus explicite et actionnable sinon, aucun déploiement partiel (AD-9)
**And** les units `homeport-backup.service`/`.timer` et le script sont déployés de façon idempotente (rejouer l'application ne change rien).

**Given** le timer installé
**When** il s'exécute, Mac éteint
**Then** le script root autonome produit une archive atomique (tmp + mv, rotation locale 3) — data dir résolu localement via les drop-ins systemd, `mqtt.env` inclus, backup Homeport natif si la version l'expose sinon générique (AD-9)
**And** il prend le flock partagé : le timer saute son tour si une action hpm est en cours, et inversement (AD-12).

**Given** une exécution terminée sur le Pi
**When** elle réussit ou échoue
**Then** le résultat est émis en **événement Homeport** — jamais écrit au journal des tâches du Mac, qui ne consigne que les actions initiées par le Mac (AD-16).

**Given** un écart entre planning déclaré côté Mac et units réellement installées
**When** `hpm doctor <machine>` s'exécute
**Then** l'écart remonte en warning (AD-10).

### Story 3.2: Consolidation des archives et vue des jobs

As a administrateur de flotte,
I want retrouver les archives produites sur les Pi rapatriées côté Mac et voir l'état de mes jobs,
So that mes sauvegardes existent en double et je vérifie d'un coup d'œil qu'elles tournent.

**Acceptance Criteria:**

**Given** des archives produites sur le Pi pendant que le Mac dormait
**When** un refresh de flotte passe ou `hpm backup sync` est lancé
**Then** les archives complètes absentes côté Mac sont rapatriées en scp (rotation 10) et le résultat est journalisé
**And** l'opération est single-flight par machine : deux déclenchements concurrents ne produisent qu'un seul transfert (AD-11).

**Given** une archive en cours d'écriture sur le Pi
**When** la consolidation passe au même moment
**Then** elle n'est pas rapatriée — l'atomicité tmp + mv (story 3.1) garantit qu'une archive visible est complète.

**Given** l'onglet Backups d'une machine
**When** il s'affiche
**Then** définition du job, derniers résultats (issus des événements), archives présentes des deux côtés et bouton Sync sont visibles
**And** le planning et la rétention s'y éditent et s'appliquent (même chemin que `hpm backup apply`, story 3.1) — l'onglet n'est pas qu'une vue en lecture.

**Given** le CLI
**When** `hpm backup jobs [--machine <nom>]`
**Then** jobs et derniers résultats s'affichent (FR11).

### Story 3.3: Gestion des mises à jour

As a administrateur de flotte,
I want voir les versions installées face aux releases disponibles et mettre à jour depuis la console,
So that la flotte reste à jour sans quitter la fenêtre.

**Acceptance Criteria:**

**Given** l'onglet Updates
**When** il s'affiche
**Then** version installée vs dernière release taguée (avec notes) par machine — seules les versions taguées sont proposées (NFR5).

**Given** un update déclenché
**When** Vincent confirme (sheet destructive, UX-DR6)
**Then** l'update s'exécute sous verrou (AD-12), sa progression s'affiche et le résultat atterrit au journal.

**Given** le CLI
**When** `hpm releases` et `hpm update <machine>`
**Then** le comportement existant est préservé et prend le verrou (FR11).

### Story 3.4: Shell intégré

As a administrateur de flotte,
I want un terminal vers n'importe quelle machine dans la console,
So that le dernier recours reste à portée sans ouvrir Terminal.app.

**Acceptance Criteria:**

**Given** une fiche machine
**When** l'onglet Shell s'ouvre
**Then** un terminal SwiftTerm 1.19.0 (`LocalProcessTerminalView` + `/usr/bin/ssh`) se connecte avec l'identité SSH de `fleet.yaml` dans le terminal-panel
**And** au plus une session par machine ; une entrée informative unique « session shell ouverte » part au journal (AD-17).

**Given** une session active
**When** la fenêtre se ferme
**Then** la session se termine proprement.

**Given** le statut d'évasion assumé (AD-17)
**When** une session est ouverte pendant une action en cours
**Then** elle n'acquiert pas le verrou et n'est pas bloquée — FR11 sans objet : le shell est la CLI.
