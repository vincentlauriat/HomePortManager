# Review — Réconciliation des inputs du spine

- **Cible :** `ARCHITECTURE-SPINE.md` (architecture-HomePortManager-2026-08-23)
- **Inputs porteurs :** `SPEC.md` (contrat canonique), `brownfield.md`, `.memlog.md` (journal des décisions du spec)
- **Date :** 2026-08-23
- **Méthode :** marche claim par claim — chaque contrainte du SPEC, chaque capability, chaque fait brownfield et chaque décision du memlog est tracé vers un AD, une convention, la Capability Map ou la section Deferred du spine.

## Verdict

Le spine est globalement fidèle : les 10 capabilities sont mappées, les 8 contraintes du SPEC ont un AD ou une convention porteuse, les trois open questions tranchées dans le memlog (notifications critiques uniquement, granularité métriques déléguée puis tranchée en AD-8, une seule app) ont atterri, et aucune décision n'est contredite. En revanche, une grappe d'exigences discrètes — presque toutes issues du brownfield opérationnel — n'a pas atterri, et deux d'entre elles touchent directement la faisabilité d'AD-9/AD-10 (backups planifiés côté Pi).

---

## 1. Contraintes du SPEC → spine

| # | Contrainte SPEC | Atterrissage | Statut |
|---|---|---|---|
| C1 | App macOS native d'abord ; console web = étape ultérieure explicite | Paradigme + Deferred « Console web Proxmox-like » | ✅ |
| C2 | Un seul livrable : l'app menubar ouvre la fenêtre centre de contrôle — un seul DMG, une seule identité, pas de seconde app | AD-15 (« même process ») + convention Opérations (« DMG unique ») | ✅ |
| C3 | Métriques/événements via l'API Homeport, pas d'agent dédié sur les Pi | AD-3, AD-8 | ✅ (mais « pas d'agent dédié » n'est qu'implicite — voir NL-7) |
| C4 | Dégradation propre face à un Homeport sans API | Convention Erreurs (« API absente/incompatible = état non disponible, jamais une erreur ») + AD-4 (capabilities + plage de versions) | ✅ |
| C5 | Backups planifiés côté Pi (systemd timer), indépendants du Mac ; le centre configure, consolide, rapatrie | AD-9, AD-10, AD-11 | ✅ |
| C6 | Socle HomePortKit réutilisé ; SSH depuis le Mac pour les actions | Paradigme, AD-1, AD-2 | ✅ |
| C7 | Pas de secrets dans fleet.yaml ; healthz toujours via SSH local ; versions taguées seulement | Convention Sécurité + AD-3 (healthz SSH) + convention Opérations (tags only) | ✅ |
| C8 | Livrable DMG signé/notarisé (pipeline existant) | Convention Opérations (`Scripts/release.sh` existant) | ✅ |

Toutes les contraintes ont un porteur. Aucune contradiction.

## 2. Capabilities → spine

Les 10 CAP figurent dans `binds:` du frontmatter et dans la Capability → Architecture Map, chacune avec un « Lives in » et un « Governed by ». Vérifications de détail :

- **CAP-1** — santé, version, disque, âge du dernier backup : porté par FleetModel + AD-15. Le détail des colonnes est story-level, acceptable. ✅
- **CAP-2** — « les actions destructives exigent une confirmation » : seulement diffus dans AD-1 (« confirmation utilisateur » comme responsabilité frontend). L'exigence spécifique destructif → confirmation obligatoire n'est règle nulle part → **NL-4**.
- **CAP-3** — WebView tailnet, AD-3 + AD-14. ✅
- **CAP-4** — logs suivis en continu et filtrables : mappé (Manager+Service SSH) ; le filtrage est story-level. ✅
- **CAP-5** — pull à curseur (AD-5), propriété des données (AD-6), notifications : convention Événements « seuls les critical notifient ». Mais la liste des événements critiques décidée en OQ1 n'est pas reprise → **NL-3**.
- **CAP-6** — HistoryStore + AD-7. ✅
- **CAP-7** — AD-9..AD-11, rotations 3/10 reconduites (AD-6, AD-9, AD-11) conformes à l'assumption du SPEC et au brownfield. ✅ (mais voir NL-1, NL-2, NL-6 pour les conditions d'exécution côté Pi)
- **CAP-8** — AD-8 tranche l'open question OQ2 (multi-échelles 24h@1min / 7j@5min / 30j@1h / 1an@1j, stockage borné, côté Pi) — exactement la délégation demandée par le SPEC (« l'architecture tranchera entre multi-échelles type RRD et schéma simple selon le coût côté Pi »). ✅
- **CAP-9** — TerminalTab SwiftTerm, parité CLI par équivalence `ssh` documentée. ✅ (mais voir NL-1 : user SSH par machine)
- **CAP-10** — ReleaseService + Manager+Install, tags only. ✅

## 3. Décisions du memlog → spine

| Décision memlog | Atterrissage | Statut |
|---|---|---|
| OQ1 : notifications macOS pour les événements critiques (healthz KO, disque presque plein) uniquement | Convention Événements (« seuls les critical déclenchent une notification macOS ») | ⚠️ partiel — le mécanisme atterrit, la définition de « critical » non (**NL-3**) |
| OQ2 : granularité/rétention déléguée à l'architecture | AD-8 tranche : multi-échelles type RRD | ✅ |
| OQ3 : un seul livrable, app menubar ouvre la fenêtre, un seul DMG, une seule identité | AD-15 + convention Opérations | ✅ |
| Dégradation sans API (notes dev stories 6-7) | Convention Erreurs + AD-4 | ✅ |
| Rotations backups reconduites 3 machine / 10 Mac | AD-6, AD-9 (rotation locale 3), AD-11 (rotation 10) | ✅ |
| Découpage 9 stories, ordre, checkpoints, notes `invoke_dev_with` | Frontmatter `scope: … 9 stories` ; le détail vit dans stories.yaml (niveau story, pas spine) | ✅ acceptable |
| Note dev story 8 : « raspyellow d'abord » | Absent du spine | ⚠️ story-level en soi, mais elle pointe le cas le plus contraint (sudo, Tailscale SSH) que le spine n'adresse pas non plus (**NL-1, NL-2**) |
| Non-goals validés (HA, RBAC, firewall, stockage, virtualisation, services tiers, agent dédié) | Seule la console web figure en Deferred | ⚠️ non contredits, mais aucune trace (**NL-7**) |

## 4. Faits brownfield → spine

- SSH pur sans agent, Mac télécharge les releases et pousse en scp (Pi sans accès GitHub) : compatible AD-2/AD-9 (script de backup **déployé par hpm**, jamais téléchargé par le Pi). ✅
- fleet.yaml sans secrets, healthz via SSH local, notifications menubar existantes sur transitions d'état, pipeline release : tous repris ou compatibles. ✅ (coexistence des deux sources de notifications non arbitrée → **NL-5**)
- `raspyellow` : SSH obligatoirement `vincent@raspyellow` (policy Tailscale SSH), subnet router : **absent du spine** → **NL-1**.
- sudo NOPASSWD garanti uniquement sur `raspcorse` : AD-9/AD-10 exigent l'installation d'units systemd (sudo) sans dire comment se comporte une machine sans NOPASSwd → **NL-2**.
- Data dir effectif résolu via `systemctl show homeport -p Environment` (drop-ins, dernier override gagne) : le script de backup autonome d'AD-9 devra refaire cette résolution localement, sans hpm — non contraint → **NL-6a**.
- `/etc/homeport/mqtt.env` root-only, staging sudo `/tmp/hpm-cfg-pull` : le contenu du backup générique Pi-side (inclut-il la config root-only ?) n'est pas contraint → **NL-6b**.
- `install.sh` ne redémarre pas un service actif → hpm enchaîne restart : détail d'implémentation existant, hors spine. ✅ acceptable.
- Assumption SPEC « flotte < 10 machines, aucune exigence de scalabilité » : absente du spine alors qu'elle justifie plusieurs AD (pull 30-60 s, SQLite, TaskGroup) → **NL-8**.

## 5. Claims non atterris (NL)

| ID | Sévérité | Claim | Détail |
|---|---|---|---|
| NL-1 | **high** | User SSH par machine (`vincent@raspyellow`, policy Tailscale SSH) | Aucune convention ne dit que l'identité de connexion SSH par machine vient de fleet.yaml et s'impose à **tous** les canaux : actions Manager+*, scp de consolidation (AD-11), déploiement des units (AD-9), et surtout le TerminalTab CAP-9 (nouveau chemin SSH). Un TerminalTab qui ouvre `ssh raspyellow` sans user échoue sur la moitié de la flotte réelle. |
| NL-2 | **high** | Précondition sudo pour AD-9/AD-10 | Installer `homeport-backup.service`/`.timer` exige root. Le brownfield ne garantit NOPASSWD que sur raspcorse ; story 8 cible raspyellow **en premier** (décision memlog). Le spine ne dit ni la précondition (NOPASSWD requis ? check `doctor` ?) ni le comportement en son absence. |
| NL-3 | medium | Définition des événements critiques (décision OQ1) | Le spine dit « seuls les `critical` notifient » mais ne fige ni quels événements sont critical (healthz KO, disque presque plein — décision explicite de Vincent) ni qui assigne la sévérité (Homeport côté producteur vs centre côté consommateur). Sans cela, la décision OQ1 peut se re-perdre dans le contrat API v1 (AD-4) rédigé aux stories 6-7. |
| NL-4 | medium | CAP-2 : confirmation obligatoire des actions destructives | Exigence de succès du SPEC. AD-1 mentionne « confirmation utilisateur » comme responsabilité frontend, mais aucune règle ne dit *quelles* actions (restore, update…) exigent confirmation ni que c'est obligatoire dans les deux frontends (CLI : `--yes`/prompt ; app : NSAlert existant). |
| NL-5 | medium | Arbitrage des deux sources de notifications | Brownfield : notifications menubar existantes sur transitions d'état. CAP-5 en ajoute pour les événements critiques. Un healthz KO déclenchera potentiellement les deux (transition unhealthy + événement critical). Pas contredit, mais non arbitré — risque de doublons que la structure en AD a fait tomber. |
| NL-6 | medium | Autonomie réelle du script de backup Pi-side (AD-9) | (a) la résolution du data dir effectif (drop-ins systemd, dernier override gagne) doit être refaite localement par le script, sans hpm ; (b) le périmètre du backup générique (inclut-il `/etc/homeport/mqtt.env` root-only ?) n'est pas contraint, alors que le backup à la demande existant le gère via staging sudo. Deux faits brownfield qui plient AD-9 et n'y figurent pas. |
| NL-7 | low | Non-goals hors console web | HA/failover, RBAC/multi-user, firewall, gestion stockage, virtualisation, supervision de services tiers, agent dédié Pi : validés par Vincent, aucun repris dans le spine (ni Deferred ni conventions). Non contredits, mais rien n'empêche un story-spec de les réintroduire. |
| NL-8 | low | Assumption « flotte < 10 machines » | Justifie le dimensionnement de plusieurs AD (pull 30-60 s, SQLite sans ORM, file par machine). Absente, elle prive les story-specs du garde-fou « aucune exigence de scalabilité au-delà ». |
| NL-9 | low | « Une seule identité » (décision OQ3) | La convention Opérations dit « DMG unique signé/notarisé » ; l'exigence « une seule identité » (pas de second bundle id / cert) n'est qu'implicite via le pipeline existant. |

## 6. Contradictions

**Aucune.** Vérifié explicitement : rotations 3/10 (AD-6/AD-9/AD-11 = brownfield), healthz SSH (AD-3 = C7), notifications critiques uniquement (convention = OQ1), une seule app (AD-15 = OQ3), pull sans agent (AD-3/AD-5 = C3), tags only (convention = C7), dégradation sans API (convention Erreurs = C4), délégation OQ2 correctement consommée par AD-8, console web bien en Deferred et non réintroduite.

## 7. Recommandations

1. **NL-1** : ajouter une ligne aux Consistency Conventions — « Connexion SSH : `user@host` par machine défini dans fleet.yaml, seul chemin de connexion pour tous les canaux (actions, scp, terminal CAP-9) » — avec raspyellow comme cas de référence.
2. **NL-2** : compléter AD-9 (ou AD-10) d'une précondition explicite : sudo non interactif requis pour le déploiement des units ; écart = warning `doctor` (le mécanisme d'AD-10 est déjà là, il suffit de l'étendre).
3. **NL-3** : compléter la convention Événements : la sévérité est assignée par Homeport (producteur) et le contrat v1 (AD-4) DOIT classer healthz KO et disque presque plein en `critical`.
4. **NL-4/NL-5/NL-6** : soit une phrase dans l'AD concerné, soit un renvoi explicite en Deferred vers les story-specs concernés (2, 6, 8) pour que rien ne tombe.
5. **NL-7/NL-8** : une ligne « Hors périmètre (SPEC) » et l'assumption d'échelle dans le frontmatter ou les conventions suffisent.
