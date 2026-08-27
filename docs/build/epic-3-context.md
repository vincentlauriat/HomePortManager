# Epic 3 Context: La flotte s'entretient sans le Mac

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Trois formes d'autonomie que le reste de la flotte n'a pas encore : des backups qui se
déclenchent sur le Pi selon un planning, Mac éteint ou pas, et qui reviennent d'eux-mêmes
consolidés côté Mac au réveil ; une console qui sait dire « cette machine a du retard » et
qui met à jour sans quitter la fenêtre ; et, en dernier recours, un terminal intégré vers
n'importe quelle machine quand tout le reste ne suffit plus. L'epic s'appuie sur les
epics 1 (verrou, journal, fiche machine) et 2 (les jobs se racontent en événements) mais
reste complet en lui-même — aucune de ses stories n'est bloquée par le chantier miroir
Homeport de l'epic 2.

## Stories

- Story 3.1: Déploiement des jobs de backup planifiés
- Story 3.2: Consolidation des archives et vue des jobs
- Story 3.3: Gestion des mises à jour
- Story 3.4: Shell intégré

## Requirements & Constraints

- **Les backups tournent sans le Mac.** Le planning et la rétention se déclarent côté Mac ;
  une fois appliqués, le Pi s'auto-suffit — l'exécution ne dépend ni du Mac allumé ni de la
  console ouverte.
- **Seules les versions taguées sont déployables.** Les mises à jour proposées à l'utilisateur
  ne portent que sur des releases GitHub taguées, jamais une branche ou un commit arbitraire.
- **Rétention bornée des deux côtés.** Rotation locale de 3 archives sur le Pi, 10 une fois
  consolidées côté Mac.
- **Chaque capacité a sa jumelle CLI**, disponible avant ou en même temps que la surface app :
  `hpm backup apply`, `hpm backup jobs`, `hpm backup sync`, `hpm releases`, `hpm update
  <machine>`. Le shell n'a pas de commande dédiée — il *est* la CLI d'évasion.
- **Aucun secret dans la config hpm ni dans `fleet.yaml`** ; l'identité SSH par machine
  (`user@host`) déclarée dans `fleet.yaml` est le seul canal d'authentification, y compris
  pour le shell.

## Technical Decisions

- **Backup Pi autonome et idempotent.** hpm déploie `homeport-backup.service`/`.timer` et un
  script root qui résout localement son environnement (data dir via drop-ins systemd,
  `mqtt.env` inclus), utilise le backup natif de Homeport si la version installée l'expose,
  sinon un backup générique. Chaque archive s'écrit atomiquement (tmp + mv) — une archive
  visible est toujours complète. Rejouer le déploiement ne change rien. Précondition sudo
  NOPASSWD vérifiée par `doctor` *avant* tout déploiement, avec refus explicite et actionnable
  si elle manque ; aucun déploiement partiel.
- **L'état désiré des jobs appartient au Mac.** La définition (planning, rétention) se déclare
  côté Mac et s'applique côté Pi de façon idempotente. Un écart entre déclaré et réellement
  installé remonte en warning via `doctor`, jamais en erreur silencieuse.
- **Les résultats de jobs sont des événements, pas des tâches.** Une exécution du timer Pi
  (succès ou échec) est émise en événement Homeport ; le journal des tâches du Mac ne consigne
  que ce que le Mac a lui-même initié — jamais d'entrée de journal fabriquée pour un job Pi.
- **Consolidation opportuniste + explicite, single-flight.** Chaque refresh de flotte rapatrie
  en scp les archives complètes absentes côté Mac (rotation 10) ; `hpm backup sync` (et son
  bouton) déclenchent la même routine. Deux déclenchements concurrents sur une même machine ne
  produisent qu'un seul transfert.
- **Verrou de mutation partagé entre le Mac et le Pi.** Toute mutation initiée du Mac (update,
  `backup apply`) prend le verrou persistant par machine dans `hpm.db` ; côté Pi, le timer de
  backup et les actions hpm partagent un flock local — le timer saute son tour si une action
  est en cours, et inversement. Un verrou périmé (détenteur mort ou pris depuis plus de 30 min)
  est repris automatiquement, la tâche interrompue close en `interrupted`.
- **Le shell n'entre jamais dans ce système de verrou.** Une session shell n'acquiert pas le
  verrou de mutation et n'écrit pas de détail au journal — seulement une entrée informative
  unique à l'ouverture (« session shell ouverte »). Elle se connecte obligatoirement avec
  l'identité SSH `fleet.yaml` de la machine, au plus une session par machine.
- **Stack shell figée.** SwiftTerm épinglé en 1.19.0 (la 2.0 exigerait Swift tools 6.2, hors
  scope) ; connexion via `LocalProcessTerminalView` + `/usr/bin/ssh`.
- **Effets isolés derrière des owners uniques.** `ReleaseService` reste le seul type qui touche
  au cache des releases GitHub ; `SSHClient`/`ProcessRunner` restent le seul chemin d'exécution
  distante — aucun autre code n'ouvre ces ressources.

## UX & Interaction Patterns

- Onglets concernés : Backups, Updates, Shell — trois des sept onglets pills de la fiche
  machine, avec leurs empty-states propres (aucun job défini, première ouverture du shell).
- L'onglet Backups montre en un coup d'œil : définition du job, derniers résultats (issus des
  événements), archives présentes des deux côtés, bouton Sync — et permet d'éditer et
  d'appliquer le planning directement, pas seulement de le lire.
- Une mise à jour est une action destructive : sheet de confirmation (titre au verbe, nom de
  machine répété, bouton à fond `semantic-critical`), puis progression visible et boutons
  d'action de la machine désactivés le temps de la mutation — les lectures restent actives.
- Le terminal utilise le seul aplat noir de contenu de l'interface (`terminal-panel`), coins
  arrondis, mono ; fermer la fenêtre termine la session proprement.
- Une session shell ouverte pendant une mutation en cours n'est ni bloquée ni signalée comme un
  conflit — elle vit hors du système de verrou.

## Cross-Story Dependencies

- **3.1 précède 3.2** : la consolidation et la vue des jobs n'ont de sens qu'une fois des jobs
  réellement déployés, et l'atomicité tmp + mv de 3.1 est la garantie sur laquelle 3.2 s'appuie
  pour ne jamais rapatrier une archive incomplète.
- **3.2 réutilise le chemin de 3.1** : éditer et appliquer le planning depuis l'onglet Backups
  emprunte le même code que `hpm backup apply`, pas une route parallèle.
- **3.1, 3.2 et 3.3 dépendent du verrou et du journal de l'epic 1** (story 1.2/1.3) — même
  mécanisme de mutation, pas de logique dupliquée.
- **3.2 dépend du canal d'événements de l'epic 2** pour afficher les derniers résultats de job
  (un job Pi se raconte en événement, jamais en entrée de journal Mac) ; cette dépendance
  fonctionnelle n'empêche pas l'epic d'être livré indépendamment, mais tant que l'API
  événements n'est pas disponible sur une machine, la vue des résultats de job dégrade comme
  le reste de l'onglet Événements.
- **3.4 (Shell) est indépendante des trois autres stories** — pas de verrou, pas de journal
  détaillé, aucun partage d'état avec backups ou updates au-delà de l'identité SSH commune.
