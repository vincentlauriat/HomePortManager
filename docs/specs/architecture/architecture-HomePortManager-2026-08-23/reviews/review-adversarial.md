# Revue adversariale — ARCHITECTURE-SPINE (Centre de contrôle Proxmox-like)

- **Cible** : `ARCHITECTURE-SPINE.md` (AD-1..AD-15) + `stories.yaml` (stories 1–9)
- **Méthode** : construction de paires d'unités (stories ou composants) qui obéissent chacune **à la lettre** à tous les AD et se construisent pourtant de façon incompatible. Chaque paire = un trou du spine, avec le resserrage proposé.
- **Date** : 2026-08-23 — relecteur adversarial

---

## Verdict

Le spine est solide sur la séparation lib/frontends et sur la propriété des données *au repos*, mais il sous-spécifie systématiquement le **temps** : tout ce qui se passe *pendant* qu'autre chose se passe (backup Pi autonome pendant une action Mac, reset du Pi pendant que le curseur avance, scp pendant qu'une archive s'écrit, deux process Mac en même temps). Quatre findings critical/high exigent un AD nouveau ou resserré avant le lancement des stories 5, 6 et 8.

---

## CRITICAL

### F1 — Story 8 (jobs Pi autonomes) × AD-12/Story 5 : le timer Pi est un deuxième chemin de mutation invisible

**La paire.**
- *Unité A* — Story 2 : `hpm update raspyellow` passe par la `MachineQueue` (AD-12), s'enregistre au journal (AD-7). Conforme à la lettre.
- *Unité B* — Story 8 : `homeport-backup.timer` se déclenche sur le Pi à 03:00, en pleine autonomie — c'est exactement ce qu'exige AD-9 (« le Pi tourne ensuite en autonomie », « planification indépendante du Mac allumé »). Conforme à la lettre.

**Le clash.** AD-12 promet « une seule action mutante à la fois par machine », mais la file est côté Mac : le timer Pi peut démarrer un backup pendant que la file Mac déroule un update sur la même machine. Deux mutations simultanées, chacune bénie par son AD. Le « Prevents » d'AD-12 (« backup pendant update… ») est précisément le scénario que AD-9 rend légal.

**Le clash secondaire (journal).** Story 5 définit le journal comme « toutes les actions lancées **via le centre** » ; Story 8 exige une « vue centrale des jobs et de leurs **derniers résultats** ». Les runs du timer ne sont pas lancés via le centre → deux constructions légales : (a) le dev de la story 8 écrit les résultats Pi dans `HistoryStore` → le Mac devient un second propriétaire durable d'un historique produit par le Pi, contredisant l'esprit d'AD-6 (« historique d'événements = le Pi ») ; (b) il les lit en live par SSH/API à chaque refresh → le journal reste aveugle aux backups nocturnes, et la « vue des derniers résultats » a une source différente du journal, non tranchée. Les deux devs peuvent livrer des stories vertes et incompatibles.

**Resserrage proposé — AD-12 étendu + AD nouveau (AD-16).**
1. *Verrou côté machine* : le script déployé par AD-9 prend un verrou machine (flock sur `/run/homeport/mutate.lock`, ou `systemd` conflicts) ; toute action mutante hpm distante prend **le même verrou** en début d'exécution. AD-12 devient : « la file Mac ordonne les intentions ; le verrou Pi arbitre l'exécution — verrou occupé = tâche journalisée `blocked`, retry borné ».
2. *AD-16 — Les résultats des jobs Pi sont des événements* : un run de backup Pi émet un événement Homeport (`type: backup.run`, severity selon résultat), propriété du Pi, servi par l'API événements (AD-5/AD-6). Le journal Mac ne contient **que** les tâches initiées côté Mac ; la « vue des jobs » de la story 8 est une projection lue au refresh (unités + derniers événements `backup.run`), cachée au plus, jamais une seconde copie durable.

---

### F2 — Story 6 (curseur d'événements) × Story 2 `restore` / réinstall Homeport : le curseur survit à un historique qui ne survit pas

**La paire.**
- *Unité A* — Story 6 : implémente `GET …/events?since=<curseur>` avec `id` entier monotone par machine et curseur persisté côté Mac (AD-5, conventions). Conforme à la lettre.
- *Unité B* — repo Homeport (AD-4/AD-5) : historise « localement » ; une réinstallation, un `hpm restore` (story 2 !), ou une purge de rétention légitime repart les ids à 1. Rien dans le contrat n'interdit ce reset — conforme à la lettre.

**Le clash.** Curseur Mac = 4812, ids Pi repartis à 1 → `since=4812` renvoie vide **pour toujours** : perte silencieuse et permanente de tous les événements, y compris les `critical` censés notifier (CAP-5). Variante : un restore qui rejoue l'historique produit des doublons de notifications. Le produit contient lui-même le déclencheur (`hpm restore`) qui invalide son propre curseur. Aucun AD ne parle de la vie du curseur quand l'historique amont meurt.

**Resserrage proposé — AD-5 resserré.** L'API événements expose un **epoch** (UUID de génération du store d'événements, renouvelé à toute recréation ; renvoyé par `/api/capabilities` et dans chaque réponse `/events`). Le curseur Mac devient le couple `(epoch, id)`. Epoch inconnu → curseur remis à zéro (ou à « maintenant » selon un choix explicite du contrat, à trancher dans le story-spec 6), et l'incident est journalisé `warning`. À inscrire dans le contrat v1 (AD-4) avant que les deux repos codent.

---

## HIGH

### F3 — AD-12 « partagée CLI + app » × AD-1/AD-7 : la file est un objet mémoire, mais CLI et app sont deux process

**La paire.**
- *Unité A* — app SwiftUI : instancie `MachineQueue` de HomePortKit, toute action passe par elle. Conforme.
- *Unité B* — `hpm` CLI : process séparé, instancie **sa propre** `MachineQueue` de HomePortKit, toute action passe par elle. Conforme — la lettre d'AD-12 dit « passe par la file par-machine de HomePortKit », pas « par la même instance ».

**Le clash.** `hpm backup raspyellow` en terminal + clic « Update » dans l'app = deux mutations simultanées sur la même machine, chacune sagement seule dans sa file. Le WAL d'AD-7 protège hpm.db, pas l'exclusion mutuelle des actions. Le Structural Seed (`MachineQueue.swift`, un type in-process) encourage la mauvaise lecture.

**Resserrage proposé — AD-12 reformulé.** « La file par-machine est un **verrou inter-process** matérialisé dans `hpm.db` (ligne `active_task {machine, pid, started_at, heartbeat}`, acquisition transactionnelle via `HistoryStore`), pas un objet mémoire. Une instance de file en RAM n'est qu'un frontal du verrou persistant. Verrou périmé (heartbeat mort) = récupérable, événement journalisé. » Se combine avec le verrou côté Pi de F1 (Mac-vs-Mac ici, Mac-vs-Pi là — les deux sont nécessaires).

---

### F4 — Story 6 × AD-13 : deux consommateurs légaux, un seul curseur — la notification critique part en silence

**La paire.**
- *Unité A* — app : polle `/events?since=` toutes les 30-60 s, notifie les `critical`, avance le curseur (AD-5, conventions). Conforme.
- *Unité B* — `hpm events` (exigé par AD-13, parité CLI) : lit avec le même curseur persisté « par machine » et l'avance après lecture. Conforme — AD-5 dit « persisté côté Mac par machine », un seul curseur.

**Le clash.** L'utilisateur (ou un script cron) lance `hpm events` ; le curseur avance ; l'app ne reverra jamais ces événements ; le `critical` ne notifie jamais. Symétriquement, si chaque frontend garde son curseur privé pour éviter ça, AD-6 est fissuré (le Mac ne persiste « que le curseur » — lequel ?). Les deux implémentations respectent la lettre ; l'une casse CAP-5, l'autre casse AD-6.

**Resserrage proposé — AD-5 + conventions resserrés.** Deux marqueurs distincts dans hpm.db, tous deux via `HistoryStore` : `fetch_cursor` (partagé, avance à toute ingestion, quel que soit le frontend) et `notified_up_to` (avancé uniquement quand la notification macOS des `critical` du lot a été émise). L'obligation de notifier vit dans HomePortKit (le `Notifier` du Capability Map) au moment de l'ingestion — pas dans un frontend — si bien que `hpm events` déclenche aussi les notifications des critical non encore notifiés, ou laisse `notified_up_to` en retrait pour que l'app rattrape.

---

### F5 — AD-11 (consolidation au refresh) × AD-9/AD-12 (backup Pi en cours) : scp d'une archive en train de s'écrire

**La paire.**
- *Unité A* — Story 1 : le refresh de flotte réutilise le FleetModel existant ; par AD-11, chaque refresh rapatrie « les archives non encore présentes côté Mac ». Conforme.
- *Unité B* — Story 8 : le timer Pi écrit `/var/backups/homeport/<archive>` à son rythme. Conforme.

**Le clash.** AD-12 classe les lectures « libres et parallèles » ; la consolidation est-elle une lecture (elle ne mute pas le Pi) ou une mutation (elle écrit côté Mac, rotation 10) ? Deux constructions légales : hors file → le refresh peut scp une archive **partielle** en cours d'écriture par le timer (copie corrompue promue « backup consolidé », rotation qui éjecte un bon backup pour garder le corrompu) ; dans la file → chaque refresh de statut se sérialise derrière les actions longues et le tableau de bord (story 1) gèle. Bonus : menubar et fenêtre partagent le FleetModel (AD-15) mais deux déclencheurs de refresh rapprochés = deux scp concurrents de la même archive.

**Resserrage proposé — AD-11 resserré.** (1) Écriture atomique côté Pi imposée au script AD-9 : écrire sous `.tmp/` puis `mv` final ; la consolidation ne considère **que** les noms finaux. (2) La consolidation est un job Mac-side *single-flight* (dédupliqué par archive, une exécution à la fois par machine), découplé de la cadence du FleetModel (déclenché par le refresh mais débounced), hors file AD-12 puisqu'elle ne mute jamais le Pi. (3) Un run = une entrée de journal, même vide.

---

### F6 — Story 1 (« âge du dernier backup ») × Story 8 : deux sources de vérité légales pour la même tuile

**La paire.**
- *Unité A* — Story 1, livrée en premier : affiche l'âge du dernier backup en lisant le journal des tâches (seule source locale existante à ce stade) ou un scan des archives Mac. Conforme.
- *Unité B* — Story 8 : introduit des backups que ni le journal (F1) ni les archives Mac (avant consolidation) ne voient. Conforme.

**Le clash.** Après la story 8, le tableau de bord affiche « dernier backup : il y a 6 j » alors que le Pi a sauvegardé cette nuit. Aucun AD ne désigne le propriétaire de la donnée « dernier backup » — AD-6 tranche archives (les deux côtés) mais pas le *fait* du dernier run.

**Resserrage proposé — AD-6 complété.** « La vérité du "dernier backup" d'une machine est côté Pi (répertoire d'archives, ou événement `backup.run` de F1/AD-16) ; le tableau de bord la lit au refresh ; le journal Mac n'est jamais une source pour cette tuile. » Une ligne dans AD-6 suffit, mais elle doit exister avant la story 1 (première livrée, `spec_checkpoint`).

---

## MEDIUM

### F7 — AD-4 × stories 6 et 7 : deux story-specs habilités à écrire « la v1 » du contrat

Le spine dit « le story-spec des stories **6-7** rédige la v1 ». Deux stories à `spec_checkpoint` séparés, potentiellement deux auteurs : la 6 fige un contrat v1 « events + capabilities », la 7 fige un contrat v1 « metrics » avec ses propres conventions (noms d'échelles, format d'erreur) — deux documents semver v1 légaux sous `docs/api/`, un serveur Homeport incapable de servir les deux. **Resserrage** : un seul document de contrat, créé par le story-spec de la 6 (capabilities + events), **amendé** en v1.1 par la 7 (metrics) ; `docs/api/` contient exactement un fichier épinglé ; la disponibilité par domaine passe par les *features* de `/api/capabilities` (`events`, `metrics`), pas par des versions parallèles.

### F8 — AD-10 (« définition des jobs = config hpm ») × AD-7 (« état des jobs de backup = hpm.db ») : la frontière définition/état n'est pas tracée

Le planning d'un job est-il « définition » (donc YAML dans `~/.config/hpm/`, AD-10) ou « état des jobs de backup » (donc hpm.db, AD-7) ? Un dev de la story 8 qui range planning + rétention dans hpm.db respecte la lettre d'AD-7 et contredit AD-10 ; l'inverse laisse « l'état » sans définition. Un état désiré dans SQLite n'est en outre plus diffable/versionnable par l'utilisateur. **Resserrage** : AD-10 précise « définition (planning, rétention, machines) = fichiers déclarés sous `~/.config/hpm/` exclusivement ; hpm.db ne stocke que l'*observé* : empreinte du dernier apply, derniers résultats, timestamps » — la frontière suit la ligne XDG config/état déjà posée dans les conventions.

### F9 — Convention « le nom fleet.yaml est l'id unique partout » × renommage : curseurs et journal orphelins

Curseurs (story 6), journal (story 5), units systemd déployées (story 8) sont tous cléés par le nom d'inventaire. Renommer une machine dans fleet.yaml — opération anodine côté FleetStore — orphelise le curseur (re-livraison ou perte d'événements), détache l'historique du journal et laisse des units nommées sur le Pi. Chaque story est conforme ; la collision est au renommage. **Resserrage** : déclarer le renommage opération destructive détectée par `doctor` (curseurs/journal orphelins, units à re-déployer) avec une migration `hpm machine rename <old> <new>` qui réécrit les clés dans hpm.db — ou introduire un id machine stable distinct du nom d'affichage.

## LOW

### F10 — Story 9 (SwiftTerm) × AD-2/AD-12 : le shell interactif est un contournement non déclaré

`TerminalTab` ouvrira en pratique son propre process `ssh` (pty interactif — hors du modèle requête/réponse de `SSHClient`) : second chemin d'« exécution distante » face au owner unique d'AD-2, et l'utilisateur peut y lancer des mutations hors file AD-12 et hors journal. C'est un escape hatch légitime, mais le spine doit le dire plutôt que le laisser en violation tacite. **Resserrage** : exemption explicite dans AD-2/AD-12 — « le shell interactif (CAP-9) est un canal d'opérateur hors file et hors owner, spawné via `ProcessRunner`, dont l'ouverture/fermeture de session est journalisée ». L'équivalence `ssh` documentée d'AD-13 couvre déjà la parité CLI.

### F11 — Conventions (« API absente = jamais une erreur ») × story 6 : l'indistinction panne/absence masque les notifications perdues

Les stories 6-7 imposent « API absente → affichage dégradé, pas d'erreur ». Une API présente hier mais injoignable aujourd'hui (service Homeport tombé) est indistinguable d'une API pas encore déployée — or dans le premier cas des événements `critical` s'accumulent sans notification et l'utilisateur croit que « tout est calme ». **Resserrage** : distinguer dans le modèle trois états (`jamais vue` / `disponible` / `perdue depuis <ts>`) ; `perdue` au-delà d'un seuil = warning `doctor` et badge UI, toujours pas une erreur.

---

## Récapitulatif

| # | Sév. | Paire | Resserrage |
|---|------|-------|------------|
| F1 | critical | Story 2/file Mac × Story 8/timer Pi ; journal × résultats de jobs | Verrou côté Pi partagé + AD-16 « résultats de jobs = événements Pi, journal = tâches Mac seulement » |
| F2 | critical | Curseur story 6 × reset/restore de l'historique Pi | Epoch de génération dans le contrat ; curseur = (epoch, id) |
| F3 | high | File in-process app × file in-process CLI | AD-12 : verrou inter-process persistant dans hpm.db |
| F4 | high | Polling app × `hpm events` sur le même curseur | `fetch_cursor` + `notified_up_to` distincts ; notification dans le Kit |
| F5 | high | Consolidation au refresh × archive en cours d'écriture | Écriture atomique Pi (tmp+mv) + consolidation single-flight débounced |
| F6 | high | Tuile « dernier backup » story 1 × backups invisibles story 8 | AD-6 : vérité du dernier backup = côté Pi, jamais le journal |
| F7 | medium | Story-spec 6 × story-spec 7, chacun « rédige la v1 » | Un seul document de contrat ; features capabilities, pas versions parallèles |
| F8 | medium | AD-10 config × AD-7 « état des jobs » | Définition = config XDG ; hpm.db = observé uniquement |
| F9 | medium | Clé = nom fleet.yaml × renommage | `hpm machine rename` migrateur + détection doctor |
| F10 | low | SwiftTerm × owner SSH unique / file | Exemption explicite journalisée pour le shell interactif |
| F11 | low | « jamais une erreur » × API perdue avec criticals en attente | Trois états d'API ; `perdue` = warning doctor |
