# Epic 1 Context: Piloter la flotte depuis une seule fenêtre

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Donner à l'administrateur une fenêtre unique depuis laquelle il pilote toute sa flotte Homeport sans ouvrir un terminal : vue d'ensemble de l'état des machines, fiche par machine avec ses actions confirmées, dashboard web de chaque Homeport intégré, logs suivis en continu, et chaque action tracée dans un journal central. À la fin de cet epic la console est utilisable et utile à elle seule, sans dépendre des capacités livrées plus tard. Cet epic pose aussi les deux socles dont tout le reste dépend : le design system + i18n côté UI, et la base d'état `hpm.db` côté kit.

## Stories

- Story 1.1 : Fenêtre centre de contrôle et tableau de bord global
- Story 1.2 : Journal des tâches et socle hpm.db
- Story 1.3 : Actions machine avec confirmations
- Story 1.4 : Dashboard Homeport intégré
- Story 1.5 : Logs centralisés

## Requirements & Constraints

- **Vue de flotte** : une ligne par machine de `fleet.yaml` — état (pill ok/warning/critical), version, disque, âge du dernier backup ; refresh périodique (5 min) et manuel. Flotte < ~10 machines : pas de pagination ni d'exigence de scalabilité.
- **Actions machine** : backup, restart, doctor, config depuis la fiche ; toute action destructive (restore, remove, update) exige une confirmation explicite dans chaque frontend.
- **Dashboard intégré** : le dashboard web de la machine s'affiche et reste utilisable dans la fenêtre, sans changer d'application.
- **Logs** : dernières lignes, suivi continu commutable, filtre texte, sélection/copie, lignes d'erreur distinguées.
- **Journal** : chaque action initiée depuis le Mac (app ou CLI) est enregistrée à sa fin — horodatage ISO 8601 UTC, machine, action, statut, sortie. Rétention bornée à 1 an / 10 000 entrées, purgée au démarrage de l'app uniquement (le CLI, outil ponctuel, ne fait jamais le ménage).
- **Parité CLI** : jamais une capacité UI sans sa jumelle CLI. Ici : `hpm tasks [--machine]`, `hpm unlock <machine>`, et préservation du comportement existant de `hpm logs <machine> [-f]`.
- **Trois états machine distincts** : disponible ; non disponible (la version installée n'expose pas la fonctionnalité — dégradation guidante, jamais une erreur) ; injoignable (erreur réseau — dernières données conservées avec « Vu pour la dernière fois à HH:MM »).
- **Sécurité et livraison** : aucun secret dans `fleet.yaml` ni la config ; réseau limité au tailnet, qui fait office d'authentification ; healthz vérifié via SSH sur la machine elle-même ; un seul livrable — l'app menubar existante ouvre la fenêtre, un seul DMG signé/notarisé via le pipeline existant.
- **État vide produit** : `fleet.yaml` absent ou vide affiche un accueil expliquant ce qu'est le centre de contrôle et comment déclarer une première machine — jamais une sidebar vide muette.

## Technical Decisions

- **Lib cœur + frontends minces** : toute capacité naît dans `HomePortKit` ; CLI et app ne portent que présentation, parsing d'arguments et confirmation. Les frontends ne se connaissent pas.
- **Un propriétaire unique par effet** : `SSHClient`/`ProcessRunner` (exécution distante), `FleetStore` (`fleet.yaml`, y compris l'identité SSH par machine), `ReleaseService` (releases), `HistoryStore` (`hpm.db`, nouveau). Aucun autre code n'ouvre ces ressources.
- **État central Mac** : `~/.local/state/hpm/hpm.db` (SQLite, WAL, `busy_timeout` obligatoire, API C système — pas d'ORM), écrit exclusivement par `HistoryStore`. La story 1.2 possède le schéma initial (journal + verrous) et le mécanisme de migration `PRAGMA user_version` ; toute extension passe par migration, jamais par table parallèle.
- **Verrou de mutation** : une mutation à la fois par machine, via un verrou inter-process **persistant en base** (pas une file en RAM) couvrant app et CLI. Il porte son détenteur (PID) et son horodatage de prise ; il est périmé dès que son process ne tourne plus ou passé un TTL de 30 min ; un verrou périmé est repris automatiquement et la tâche close en `interrupted`. `hpm unlock` refuse tant que le détenteur est vivant et affiche qui tient le verrou et depuis quand. Les lectures restent libres et parallèles.
- **Journal = actions initiées par le Mac uniquement** : un seul écrivain, pas de fausse entrée pour ce qui se passe côté machine.
- **Accès HTTP** : une **exception App Transport Security unique** dans `Info.plist`, partagée par `URLSession` et `WKWebView` — aucune story n'introduit son propre contournement. HTTP clair sur le tailnet ; HTTPS différé.
- **Modèle UI** : menubar et fenêtre partagent le même process et le même `FleetModel` `@MainActor`, source unique d'état. Fenêtre `NavigationSplitView` (sidebar machines + détail en onglets), min 900×600. Les opérations longues tournent hors MainActor via le kit et rapportent au modèle et au journal.
- **Conventions** : le nom d'inventaire `fleet.yaml` est l'identifiant unique partout, et l'identité SSH (`user@host`) en vient pour **tous** les canaux. ISO 8601 UTC en base ; `HPMError` reste l'enveloppe d'erreur unique du kit. Config `~/.config/hpm/`, état `~/.local/state/hpm/`, cache `~/.cache/hpm/`. Identifiants et commits en anglais. Brownfield sur socle v1.0.0 : pas de starter template, `Package.resolved` committé fait foi.

## UX & Interaction Patterns

- **Tokens du design system = source unique de style SwiftUI** (palette, Inter + JetBrains Mono avec fallback CJK, échelles rounded et spacing), thème clair seul, chrome monochrome où la couleur ne sert qu'à identifier ou signaler. Critère d'acceptation de la story 1.1, pas vœu transversal.
- **Composants réutilisables à construire** : `sidebar-row`(+selected), `machine-banner`, `status-pill-ok/-warning/-critical`, `tab-default/-selected`, `button-primary/-secondary/-destructive`, `data-table`, `log-viewer`, `empty-state`, `toast`.
- **Identité par machine** : un block pastel stable assigné à l'ajout dans l'ordre documenté (lime, cream, lilac, mint, pink, coral), persisté, porté par la pastille sidebar et le bandeau de fiche — jamais réassigné (retrait d'une autre machine, renommage, relancement).
- **Huit onglets pills** (Résumé, Dashboard, Logs, Événements, Métriques, Backups, Shell, Updates) atteignables par ⌘1-8 ; ⌘F filtre, ⌘R refresh ; toute surface à ≤ 2 clics depuis la sidebar. Cet epic implémente Résumé, Dashboard et Logs.
- **i18n trilingue** (fr, en, zh-Hans) via String Catalogs dès la première story UI : aucune chaîne en dur, langue système parmi les trois, anglais par défaut ; dates/tailles/durées via `FormatStyle` ; hauteurs de ligne vérifiées en zh-Hans. Le contenu produit par les machines (logs, sorties, chemins, versions) n'est jamais traduit et reste en mono.
- **Confirmations destructives en sheet** : titre au verbe, conséquence en une phrase, nom de la machine répété, bouton destructif à fond critique — seul endroit de l'app avec un fond rouge.
- **Verrou visible dans l'UI** : pendant une mutation, boutons d'action de la machine désactivés + indicateur « … en cours » dans le bandeau, lectures actives. L'UI reflète le verrou, ne le contourne jamais.
- **Logs** : le suivi continu s'auto-suspend dès que l'utilisateur remonte, avec bouton « Reprendre le suivi ».
- **Empty-states rédigés par onglet** ; « injoignable » garde les dernières données et propose « Réessayer » — jamais une page d'erreur WebKit brute.
- **Plancher d'accessibilité** : clavier complet, focus visible, labels VoiceOver sur actions et pills, couleur jamais seule porteuse d'état (pill = couleur + libellé), `prefers-reduced-motion` respecté. Ton sobre : le bouton dit ce qu'il fait, le toast confirme au passé, l'erreur donne le fait puis le remède.

## Cross-Story Dependencies

- **1.2 avant 1.3** : le verrou vit dans le schéma `hpm.db` possédé par la story journal ; 1.3 y écrit aussi ses résultats.
- **1.1 avant 1.3, 1.4, 1.5** : tokens, composants, i18n et coquille `NavigationSplitView` viennent de la première story ; les suivantes les consomment sans les redéfinir.
- **Vers l'epic 2** : l'exception ATS posée par 1.4 est celle que le futur client API réutilise — ne pas en ajouter une seconde ; le schéma de 1.2 est étendu par migration pour les curseurs et marqueurs d'événements.
- **Vers l'epic 3** : même schéma étendu par migration pour l'état des jobs ; mises à jour et backups reprennent le verrou et le journal établis ici.
- **Aucune dépendance externe bloquante ici** : tout passe par SSH et le socle v1.0.0 existant ; l'API Homeport n'est requise qu'à partir de l'epic 2, dont le contrat est rédigeable dès la fin de cet epic (chemin critique du planning).
