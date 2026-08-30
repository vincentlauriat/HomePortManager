---
title: 'Déploiement des jobs de backup planifiés'
type: 'feature'
created: '2026-08-30'
status: 'done'
review_loop_iteration: 0
context: ['{project-root}/docs/build/epic-3-context.md']
baseline_commit: 'fc87f32c954b7b1e4eb759643a5ce0fb94706883'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Un backup Homeport ne se produit que si le Mac est allumé et que Vincent lance
`hpm backup <machine>` à la demande — aucune protection périodique si le Mac est éteint.

**Approach:** Un job de backup se déclare côté Mac (planning, rétention) et se déploie de façon
idempotente comme des units systemd `homeport-backup.service`/`.timer` + un script root
autonome sur le Pi, coordonné avec le verrou de mutation existant (AD-12) via un flock local.
Le check de drift `doctor` est différé (`deferred-work.md`) pour tenir le budget de tokens.

## Boundaries & Constraints

**Always:** La précondition sudo NOPASSWD (probe `sudo -n true`, `Manager+Prereqs.swift`) est
vérifiée avant tout déploiement — refus explicite et actionnable si absente, aucun déploiement
partiel. Le déploiement des units suit le pattern idempotent de `Manager+Install.swift` (heredoc
sudo, rejouer ne change rien). Le script Pi-side est autonome : il résout le data dir localement
(drop-ins systemd, dernier override gagne), écrit son archive atomiquement (tmp + mv), garde 3
archives locales, et sauvegarde `/etc/homeport` (dont `mqtt.env`) + le data dir (sqlite-safe si
possible sinon copie brute) — même contenu que `performBackup` (`Manager+Backup.swift`), porté en
bash pur. Il prend un flock local avant de s'exécuter (AD-12/F1) ; une action hpm mutante en cours
sur la machine lui fait sauter son tour, et inversement. Le résultat d'un run n'est jamais écrit
dans le journal des tâches du Mac (AD-16) — reste observable via l'archive et, si le collecteur
`backups.py` de Homeport est configuré pour la surveiller, via l'événement `backup.*` déjà défini
au contrat v1 (config-only côté Homeport, aucun code à y changer pour cette story). La définition
du job (schedule, rétention) vit sous `~/.config/hpm/` (XDG) — jamais dans `hpm.db`, qui ne garde
que l'état observé (F8). L'identité SSH par machine (`fleet.yaml`) est le seul canal de connexion.
`hpm backup <machine>` (comportement actuel) devient `hpm backup now <machine>` ;
`hpm backup apply <machine>` est la nouvelle commande de déploiement — `backup` devient un groupe
de sous-commandes (pattern `MachineCmd`).

**Ask First:** Si le format du fichier de définition de job doit suivre une convention distincte
de celle proposée ici, HALT et demander. Si la précondition NOPASSWD échoue sur `raspyellow`
(cible mémoire du memlog, non garantie — NL-2) au moment d'un déploiement réel, HALT et demander
comment procéder plutôt que de contourner silencieusement.

**Never:** Pas d'invocation d'un « backup natif Homeport » — Homeport n'expose aujourd'hui aucune
fonction d'exécution de backup, seulement de l'observation passive. Cette story utilise
uniquement le script générique autonome ; la détection/invocation d'un backup natif est un
chantier séparé côté `../Homeport`, tracé mais hors périmètre ici (décision de Vincent : à
ouvrir). Pas de retrait ni modification du mécanisme de backup manuel déjà installé sur
raspcorse/raspyellow (`../Homeport/deploy/backup/*`) — cohabitation assumée, réconciliation
différée (décision de Vincent). Pas de check de drift `doctor` (différé). Ne pas toucher au
comportement existant de `Manager+Backup.swift` au-delà du renommage de commande CLI.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Déploiement propre | Job défini, sudo NOPASSWD OK | Units déployées idempotemment | N/A |
| Sudo NOPASSWD absent | Job défini, `sudo -n true` échoue | Refus explicite avant tout déploiement, aucune unit touchée | Message actionnable, même pattern que `doctor` |
| Rejeu du déploiement | Units déjà installées, identiques | Aucun changement | N/A |
| Timer déclenché, Mac éteint | Aucune connexion Mac | Archive atomique produite localement, rotation à 3, flock pris | Échec jamais écrit dans le journal Mac |
| Verrou Mac actif pendant le tick du timer | Action hpm mutante en cours sur cette machine | Le timer Pi saute son tour (flock local) | Prochain tick réessaie |

</frozen-after-approval>

## Code Map

- `Sources/HomePortKit/Manager+Backup.swift` -- `performBackup(on:)` (lignes 36-74) : contenu à reproduire côté bash (config + data dir sqlite-safe, tar, rotation `ls -1t | tail -n +4 | xargs -r rm`)
- `Sources/HomePortKit/Manager+Install.swift` -- `performInstall(on:version:)` (lignes 11-39) : pattern heredoc sudo idempotent à suivre
- `Sources/HomePortKit/Manager+Prereqs.swift:68-80` -- `runPrereqProbes`, probe `"sudo"` (`sudo -n true`) réutilisable tel quel
- `Sources/HomePortKit/RemotePaths.swift` -- ajouter les constantes du nouveau unit/timer/flock path ici
- `Sources/HomePortKit/HistoryStore.swift:289-323,343-355` -- `acquireLock`/`releaseLock` (verrou Mac existant, AD-12, ne pas dupliquer)
- `Sources/hpm/Commands.swift:202-214` -- `BackupCmd` actuel (flat) à convertir en groupe (pattern `MachineCmd:7-12`)
- `docs/api/homeport-api-v1.md:257` -- famille d'événements `backup.*` déjà définie au contrat, aucune extension nécessaire

## Tasks & Acceptance

**Execution:**
- [x] `Sources/HomePortKit/BackupJobStore.swift` (nouveau) -- format + lecture/écriture des définitions de job (YAML sous `~/.config/hpm/jobs/<machine>.yaml` : schedule, rétention) -- frontière F8, jamais dans `hpm.db`
- [x] `Sources/HomePortKit/RemotePaths.swift` -- ajouter unit/timer/flock path pour le job de backup
- [x] `Sources/HomePortKit/Manager+BackupJob.swift` (nouveau) -- `applyBackupJob(on:)` : précondition sudo (réutilise `prereqs`), déploiement idempotent des units + script bash autonome (contenu porté de `performBackup`, résolution data dir locale sans SSH-roundtrip)
- [x] `Sources/hpm/Commands.swift` -- `BackupCmd` devient un groupe (`apply`, `now` reprenant le comportement actuel)
- [x] `Tests/HomePortKitTests/BackupJobStoreTests.swift`, `ManagerBackupJobTests.swift` -- couvrir la matrice I/O (parsing job, précondition sudo, idempotence détectée, aucune écriture journal)

**Acceptance Criteria:**
- Given une définition de job déclarée dans la config hpm côté Mac, when Vincent l'applique (`hpm backup apply <machine>`), then la précondition sudo NOPASSWD est vérifiée d'abord (refus explicite sinon), et les units + script sont déployés idempotemment.
- Given le timer installé, when il s'exécute Mac éteint, then le script root autonome produit une archive atomique (rotation locale 3), résout le data dir localement, et prend le flock partagé.
- Given une exécution terminée sur le Pi, when elle réussit ou échoue, then le résultat n'est jamais écrit au journal des tâches du Mac.

## Spec Change Log

- **Format de `hpm backup apply`** : aucune commande séparée n'existe dans cette story pour
  déclarer un job avant de l'appliquer (`hpm backup jobs` est story 3.2) — `hpm backup apply
  <machine> [--schedule <expr>] [--retention <n>]` déclare (ou met à jour) le job dans
  `~/.config/hpm/jobs/<machine>.yaml` puis le déploie en un seul geste. `--schedule` est requis
  la première fois qu'un job est déclaré pour une machine ; `--retention` défaut à 3. Un
  `hpm backup apply <machine>` nu, sans option, redéploie le job déjà déclaré sans le modifier.
- **Coordination flock (AD-12/F1) partielle par construction** : le script autonome déployé
  prend le flock local (`/run/lock/homeport-backup.lock`) avant de s'exécuter et saute son tour
  s'il est tenu — ce que la matrice I/O demande. La réciproque (une action hpm Mac-initiée qui
  prendrait le même flock avant de muter la machine) n'est pas implémentée ici : le Never
  boundary interdit de toucher `Manager+Backup.swift`/`Manager+Install.swift` au-delà du
  renommage CLI, et aucune ligne de la matrice ne demande cette réciproque. Le fichier de lock
  est le point de rendez-vous que de futures actions pourront adopter sans le renommer.
- **Atomicité renforcée par rapport à `performBackup`** : `performBackup` (Mac-initiée) écrit
  déjà son tarball directement vers sa destination finale ; le script Pi-side de cette story va
  plus loin (tmp + `mv -f`, comme demandé par les Boundaries de 3.1) parce qu'il peut être
  interrompu sans supervision Mac. Le contenu métier (config + data dir sqlite-safe) reste
  identique à `performBackup`, warts inclus (`*.sqlite*` ne couvre pas `-wal`/`-shm` — hérité,
  non corrigé ici).

## Design Notes

Cohabitation assumée avec le mécanisme de backup manuel existant
(`../Homeport/deploy/backup/*`) — pas de migration dans cette story. La détection d'un backup
natif Homeport (AD-9) est un chantier séparé côté `../Homeport`, à ouvrir mais non spécifié ici.
Le check de drift `doctor` (4e AC d'epics.md) est différé — voir `deferred-work.md`.

## Verification

**Commands:**
- `swift build && swift test` -- expected: rc 0, suite verte
- `Scripts/verify-app-build.sh` -- expected: rc 0

**Manual checks (if no CLI):**
- Déploiement réel sur `raspyellow` (cible mémoire du memlog) : vérifier la précondition NOPASSWD
  au préalable (non garantie — NL-2) ; tester sur `raspcorse` d'abord si elle manque.
- `systemctl list-timers` confirme le timer actif après `hpm backup apply`.

## Suggested Review Order

**Entry point**

- Le flux complet : précondition sudo, puis déploiement idempotent — départ pour saisir l'intention.
  [`Manager+BackupJob.swift:9`](../../Sources/HomePortKit/Manager+BackupJob.swift#L9)

**Injection guard & validation CLI**

- Rejette newline et marqueurs heredoc avant que schedule/machine n'atteignent le script déployé.
  [`Manager+BackupJob.swift:54`](../../Sources/HomePortKit/Manager+BackupJob.swift#L54)
- Les trois délimiteurs heredoc avec lesquels une valeur hostile pourrait entrer en collision.
  [`Manager+BackupJob.swift:50`](../../Sources/HomePortKit/Manager+BackupJob.swift#L50)
- Validation et branchement déclarer/redéployer côté CLI, désormais extraits et testables.
  [`Commands.swift:232`](../../Sources/hpm/Commands.swift#L232)

**Script de déploiement idempotent**

- Construit tout le déploiement en un seul script heredoc ; seul le timer est activé.
  [`Manager+BackupJob.swift:76`](../../Sources/HomePortKit/Manager+BackupJob.swift#L76)
- Le service n'a pas de `[Install]` — invoqué par le timer seul, jamais activé directement.
  [`Manager+BackupJob.swift:98`](../../Sources/HomePortKit/Manager+BackupJob.swift#L98)
- Restart explicite après `enable --now` pour qu'un schedule modifié prenne effet sans délai.
  [`Manager+BackupJob.swift:109`](../../Sources/HomePortKit/Manager+BackupJob.swift#L109)
- Portage bash de `performBackup`, plus le rendez-vous flock et l'écriture atomique tmp+mv.
  [`Manager+BackupJob.swift:130`](../../Sources/HomePortKit/Manager+BackupJob.swift#L130)

**Stockage de la déclaration de job**

- État désiré uniquement — schedule + rétention, jamais un résultat ni un verrou.
  [`BackupJobStore.swift:6`](../../Sources/HomePortKit/BackupJobStore.swift#L6)
- Un fichier YAML par machine sous `~/.config/hpm/jobs` — jamais `hpm.db`.
  [`BackupJobStore.swift:22`](../../Sources/HomePortKit/BackupJobStore.swift#L22)

**Surface CLI**

- `backup` devient un groupe de sous-commandes : `apply` (nouveau) et `now` (renommage de l'ancien `backup`).
  [`Commands.swift:202`](../../Sources/hpm/Commands.swift#L202)
- Première déclaration exige `--schedule` ; un `apply` nu redéploie sans changement.
  [`Commands.swift:209`](../../Sources/hpm/Commands.swift#L209)
- Nouvelles constantes de chemin pour l'unit/le timer/le script/le lock déployés.
  [`RemotePaths.swift:12`](../../Sources/HomePortKit/RemotePaths.swift#L12)
- `jobsRoot` enfilé dans l'init du manager aux côtés de `backupRoot`/`configRoot`.
  [`Manager+Prereqs.swift:18`](../../Sources/HomePortKit/Manager+Prereqs.swift#L18)

**Périphériques**

- README documente la nouvelle commande, sa rétention et sa portée Pi-local.
  [`README.md:39`](../../README.md#L39)
- Correctif de l'indice CLI obsolète dans `restore` : `backup` → `backup now`.
  [`Manager+Restore.swift:17`](../../Sources/HomePortKit/Manager+Restore.swift#L17)
- L'arithmétique de rotation exécutée pour de vrai contre un dossier temporaire, pas seulement affirmée sur du texte.
  [`ManagerBackupJobTests.swift:180`](../../Tests/HomePortKitTests/ManagerBackupJobTests.swift#L180)
- Nouvelle cible de test pour la couche CLI — le trou de couverture que cette revue a comblé.
  [`BackupCmdApplyTests.swift:9`](../../Tests/HomePortKitTests/BackupCmdApplyTests.swift#L9)
- Aller-retour de la déclaration de job et isolation par machine.
  [`BackupJobStoreTests.swift:4`](../../Tests/HomePortKitTests/BackupJobStoreTests.swift#L4)
