# Revue rubric — ARCHITECTURE-SPINE.md (Centre de contrôle Proxmox-like)

- **Relecteur** : rubric walker indépendant (checklist good-spine)
- **Date** : 2026-08-23
- **Objet** : `docs/specs/architecture/architecture-HomePortManager-2026-08-23/ARCHITECTURE-SPINE.md`
- **Sources jugées** : `SPEC.md` (CAP-1..CAP-10), `brownfield.md`, `stories.yaml` (9 stories), code existant `Sources/HomePortKit/`

## Verdict

Spine solide et bien ancré dans le brownfield : les 10 capabilities sont couvertes et gouvernées, les décisions structurantes (propriété des données, file par machine, contrat API versionné, SQLite unique) empêchent les divergences majeures entre stories, et la question ouverte du spec (rétention métriques CAP-8) est tranchée comme demandé. **Aucun finding critical.** Restent deux angles morts transverses (schéma de transport HTTP/ATS, statut du shell interactif vis-à-vis de la file et du journal) et quelques dimensions sous-décidées (unification des notifications, rétention du journal, propriété du schéma hpm.db éclaté entre story-specs) qui laisseraient des stories diverger si rien n'est ajouté. Corrigeable par 2-3 ajouts ciblés sans restructurer le document.

---

## Findings

### Critical

Aucun.

### High

#### H-1 — Le shell interactif (CAP-9) échappe à AD-12 et AD-6 sans que le spine ne tranche

AD-12 pose : « toute action mutante passe par la file par-machine … et s'enregistre au journal des tâches ». Or un shell SwiftTerm (story 9) est par nature un canal de mutation arbitraire : l'utilisateur peut y lancer un restart, un `apt upgrade`, toucher `/var/backups/homeport` — pendant qu'un backup planifié (story 8) ou un update (CAP-10) tient la file. Le spine ne dit nulle part si une session shell :

- prend le verrou machine de `MachineQueue` (et alors bloque toute action pendant que le terminal est ouvert — probablement indésirable),
- ou est explicitement **hors** invariant (comme le SSH manuel l'est aujourd'hui), auquel cas AD-12 doit le dire (« la file gouverne les actions lancées *par le centre* ; le shell est un canal d'évasion assumé, non journalisé »).

En l'état, le dev de la story 9 et celui de la story 8 peuvent faire deux lectures opposées d'AD-12. La ligne CAP-9 de la map (« AD-13 (équiv. `ssh` documenté) ») ne couvre que la parité CLI, pas ce point. **Fix suggéré** : une phrase d'exclusion explicite dans AD-12 (ou un AD-16 court « le shell est hors file et hors journal, au même titre que le SSH manuel »).

#### H-2 — Schéma de transport HTTP (http vs https, ATS) non décidé, alors qu'il traverse trois stories

AD-3 et AD-14 posent « HTTP direct via tailnet », mais ni le scheme ni la conséquence macOS ne sont tranchés : App Transport Security bloque par défaut le `http://` en clair aussi bien dans `URLSession` (HomeportAPIClient, stories 6-7) que dans `WKWebView` (dashboard intégré, story 3). Trois issues possibles — exception ATS globale, exceptions par domaine tailnet, ou TLS via `tailscale serve` (qui change l'URL et le port du dashboard existant) — et rien dans le spine ne choisit. C'est exactement un point de divergence inter-stories : la story 3 peut poser une exception ATS locale à la WebView pendant que la story 6 en pose une autre pour l'API, ou que l'une bascule sur `tailscale serve` et pas l'autre. C'est aussi une décision de posture sécurité qui appartient à AD-14, pas à une story. **Fix suggéré** : une ligne dans AD-3 ou AD-14 (« http en clair sur le tailnet, exception ATS unique déclarée dans l'app pour \*.\<tailnet\> / les hosts de fleet.yaml ; TLS via tailscale serve = différé avec l'auth applicative »).

### Medium

#### M-1 — Propriété du schéma `hpm.db` éclatée entre story-specs, et le renvoi « (5-7) » est faux par rapport à stories.yaml

Le Deferred descend « le schéma détaillé des tables hpm.db » aux « story-specs (5-7) ». Or d'après `stories.yaml` : la story **5** (journal, CAP-6), la story **6** (curseurs, CAP-5) et la story **8** (état des jobs de backup, CAP-7 — explicitement dans le périmètre d'AD-7) écrivent toutes dans hpm.db ; la story 7 (métriques) n'y écrit rien. Deux problèmes :

1. le renvoi numérique est incohérent avec la liste des stories (probable confusion entre numéros de story et numéros de CAP) — un exécutant qui suit le pointeur à la lettre cherchera le schéma au mauvais endroit ;
2. trois story-specs définissent chacun leur tranche d'un même fichier SQLite sans qu'un propriétaire du schéma ni une règle de fusion/migration ne soit désigné. AD-7 garantit l'écrivain unique (`HistoryStore`) mais pas la cohérence du schéma ni son **versionnement/migration** (`PRAGMA user_version` ou équivalent — totalement silencieux, alors que le fichier vivra sur plusieurs releases).

**Fix suggéré** : corriger les numéros, désigner la story 5 comme propriétaire du schéma initial + de la stratégie de migration, les stories 6 et 8 comme extensions migrées.

#### M-2 — Deux politiques de notification macOS coexistent sans règle d'unification

Le brownfield ratifié dit : app menubar existante = « notifications sur transitions d'état uniquement » (refresh 5 min). La convention Événements ajoute : « seuls les `critical` déclenchent une notification macOS » (pull 30-60 s). Un healthz KO déclenchera vraisemblablement **les deux** : une transition d'état détectée au refresh et un événement `critical` remonté par l'API → notification en double, ou pire, deux stories qui « corrigent » le doublon chacune à leur façon. Le spine, qui possède la cohérence inter-frontends, doit dire qui est la source de vérité des notifications (par ex. : l'événement critical prime quand l'API est disponible, la transition d'état reste le fallback des machines sans API — ce qui s'articule bien avec la dégradation déjà prévue). Question annexe non tranchée : au rattrapage de curseur (app rouverte), notifie-t-on les criticals passés ?

#### M-3 — Rétention du journal des tâches non bornée (asymétrie avec AD-8)

AD-8 borne soigneusement le stockage côté Pi (4 échelles, « stockage borné »), et AD-6 confie le journal des tâches au Mac — mais aucune décision ne borne `hpm.db` : le journal enregistre « la sortie » de chaque action (AD-12 + CAP-6), c'est-à-dire potentiellement des sorties d'update/backup volumineuses, pour toujours. Sur une flotte de 2 machines ce n'est pas urgent, mais c'est une dimension que cette altitude possède (c'est le pendant exact d'AD-8) : soit la trancher (« rétention N jours / M entrées, sortie tronquée à K Ko »), soit la mettre explicitement en Deferred/Open question. Aujourd'hui elle est passée sous silence.

### Low

#### L-1 — Séquencement : AD-12 exige le journal dès la story 2, mais `HistoryStore` n'arrive qu'à la story 5

« Toute action mutante … s'enregistre au journal des tâches » est invérifiable pour les stories 2-4 puisque le journal (story 5) n'existe pas encore. Ce n'est pas une divergence entre unités, mais une règle temporairement insatisfiable ; une note (« l'enregistrement au journal devient obligatoire dès que HistoryStore existe ; MachineQueue arrive avec la story 2 ») éviterait un débat au premier checkpoint. À noter aussi qu'aucun AD ne dit quelle story introduit `MachineQueue`.

#### L-2 — SwiftTerm n'est qu'un émulateur de terminal, pas un transport SSH

Le Structural Seed nomme `TerminalTab.swift (SwiftTerm)` mais le mécanisme de connexion n'est pas décidé : pty local exécutant `ssh` (cohérent avec le modèle « SSH pur sans agent » du brownfield et avec `SSHClient` existant) vs bibliothèque SSH Swift (nouvelle dépendance, gestion de clés dupliquée). Une seule story est concernée donc le risque de divergence est faible, mais le choix engage la stack (nouvelle dépendance ou non) — une demi-ligne suffirait (« pty local sur `/usr/bin/ssh`, réutilise la config SSH système comme SSHClient »).

#### L-3 — Deux boucles de polling sans propriétaire de cadence

Refresh flotte existant (5 min, TaskGroup) + pull événements (30-60 s par machine, AD-5) + rapatriement opportuniste « à chaque refresh » (AD-11). Qui possède l'ordonnancement (FleetModel ? un scheduler HomePortKit partagé CLI/app ?) n'est pas dit ; le CLI (`hpm events`, AD-13) fait-il un pull one-shot avec le même curseur persisté que l'app ? AD-7 (curseur en base unique) protège l'essentiel, mais une collision app-qui-pull / CLI-qui-pull sur le même curseur mérite une ligne.

#### L-4 — « Âge du dernier backup » (CAP-1) : source non désignée depuis que les backups tournent côté Pi

Avec la story 8, le dernier backup peut exister sur le Pi sans être encore consolidé côté Mac (Mac éteint à l'heure du timer). Le tableau de bord (story 1) affiche-t-il l'âge d'après `/var/backups/homeport` (vérité Pi, via SSH) ou d'après `~/HomePortBackups` (copie Mac) ? AD-6 dit « archives = les deux côtés » sans désigner la source d'affichage ; deux stories (1 et 8) peuvent répondre différemment.

#### L-5 — Stack : plausible, deux remarques mineures

Rien d'obsolète : Swift Charts natif macOS 13+ ✓, swift-argument-parser ≥ 1.3 ✓, Yams ≥ 5.0 ✓, SQLite via API C sans ORM ✓ (cohérent avec AD-7), SwiftTerm annoté « vérifié actif 2026-08 » — bonne pratique. Deux remarques : « tools 5.9 » est conservateur en 2026 (ratifie l'existant, acceptable, mais dire explicitement « on ne migre pas la toolchain dans cet incrément » serait plus net) ; « dernière release SPM » pour SwiftTerm n'est pas une contrainte épinglable — préférer une borne de version comme pour les autres dépendances.

---

## Passage de la checklist good-spine

| # | Critère | Verdict | Commentaire |
|---|---|---|---|
| 1 | Fixe les vrais points de divergence, n'en rate aucun | **Partiel** | Les gros points sont fixés (contrat API, propriété des données, concurrence, stockage central, état UI, pipeline backup unique). Ratés : transport/ATS (H-2), statut du shell (H-1), unification des notifications (M-2), source de l'âge du backup (L-4). |
| 2 | Chaque AD a une Rule applicable/vérifiable | **Oui, à une nuance près** | Les 15 Rules sont concrètes et testables (écrivain unique, endpoints, échelles chiffrées, warning doctor…). Nuance : AD-9 « si la version installée l'expose » ne dit pas *comment* le script détecte l'exposition (capabilities API ? présence d'une commande ?) — petit trou de vérifiabilité, à combler au story-spec 8. |
| 3 | Rien dans Deferred ne laisse deux unités diverger | **Partiel** | Console web, auth token, SSE, Sparkle, détail visuel des onglets : différés sûrs, bien gardés par AD-14/AD-5/AD-15. Le différé « schéma hpm.db + contrat API v1 » est le risqué : renvoi de stories erroné et schéma éclaté sur 3 story-specs sans propriétaire (M-1). |
| 4 | Technologies plausiblement à jour | **Oui** | Voir L-5 ; rien d'obsolète ou de fantaisiste. |
| 5 | Ratifie le brownfield au lieu de le contredire | **Oui — point fort** | Vérifié contre le code : `FleetStore`, `ReleaseService`, `SSHClient`, `ProcessRunner`, `HPMError`, extensions `Manager+*` existent tous dans `Sources/HomePortKit/` et sont repris tels quels (AD-2, conventions de nommage). FleetModel `@MainActor` ratifié (AD-15), rotations 3/10 reconduites (AD-6, conforme à l'assumption du spec), healthz via SSH préservé (AD-3, contrainte spec respectée), XDG paths conformes au brownfield, pipeline release.sh réutilisé, « un seul DMG » respecté (AD-15 : même process). Seule friction : la double politique de notification (M-2) — pas une contradiction, mais une superposition non arbitrée. |
| 6 | Couvre CAP-1..CAP-10 | **Oui** | La Capability → Architecture Map couvre les 10, chacune avec un lieu et des ADs gouvernants ; `binds` du frontmatter cohérent. CAP-9 est la ligne la plus mince (voir H-1). La question ouverte du spec (CAP-8) est tranchée par AD-8 comme le spec le demandait. |
| 7 | Chaque dimension de l'altitude est décidée/différée/questionnée | **Partiel** | L'enveloppe opérationnelle n'est pas oubliée : la ligne « Opérations » des conventions couvre la livraison (DMG signé + symlink hpm, tags only), AD-4 couvre le rollout inter-repos (capabilities + plage de versions), AD-10 couvre la dérive déclaré/installé (warning doctor), la dégradation sans API est une convention. Manquent en silence : migration de schéma hpm.db (M-1), rétention du journal (M-3), posture ATS/TLS (H-2). Environnements : un seul environnement (flotte personnelle de 2 machines) — silence acceptable à cette échelle, cohérent avec l'assumption < 10 machines. |

## Points forts (à conserver tels quels)

- **AD-6 + AD-8** répondent exactement à l'open question du spec, avec des chiffres bornés — c'est le bon niveau d'altitude.
- **AD-4** (contrat semver, copie épinglée, endpoint capabilities, plage consommée) est le meilleur AD du document : il rend la contrainte « dégrader proprement » mécaniquement vérifiable.
- **AD-9/AD-10/AD-11** forment un trio cohérent qui règle proprement le problème « Mac éteint » du success signal, sans agent sur les Pi (non-goal respecté).
- **AD-13** (CLI d'abord) est la meilleure protection structurelle contre la dérive app-only, et colle au paradigme déclaré.
- Le Structural Seed nomme des fichiers qui s'insèrent dans les conventions existantes du repo (extensions `Manager+*`) — un dev peut commencer sans réinterprétation.

## Recommandation

Amender le spine avant le lancement des stories 3, 6-9 : une phrase dans AD-12 (statut du shell, H-1), une phrase dans AD-3/AD-14 (scheme + ATS, H-2), correction des numéros de stories dans Deferred + désignation d'un propriétaire du schéma hpm.db avec versionnement (M-1), une règle d'arbitrage des notifications (M-2), et une décision ou un différé explicite sur la rétention du journal (M-3). Les stories 1-2 peuvent démarrer sans attendre ces amendements (avec la note L-1 en tête).
