---
title: '2.1 — Contrat API v1 et flux d''événements'
type: 'feature'
created: '2026-08-24'
status: 'in-review'
baseline_commit: '1b41a2df7e4906edca43339550ce1ae1accb280b'
review_loop_iteration: 0
context:
  - '{project-root}/docs/build/epic-2-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Les trois stories de l'epic 2 et l'implémentation serveur dans le repo miroir Homeport
attendent un contrat qui n'existe pas. Homeport 0.7.2 n'expose aucune route `/api/v1/` : ses routes
actuelles servent son propre front web, sans identifiant de curseur exposé, sans notion d'epoch,
sans sévérités normalisées, et sans historique de métriques multi-échelles. Tant que le contrat
n'est pas écrit, ni le serveur ni le client ne peuvent démarrer sans risquer de diverger.

**Approach:** Rédiger la v1 complète du contrat (capabilities + events + metrics) comme un document
versionné en semver, l'épingler sous `docs/api/`, et faire déclarer par HomePortKit la plage de
versions que hpm consomme, avec le test de compatibilité qui va avec. Rien de plus : ni client HTTP,
ni onglet, ni commande CLI.

## Boundaries & Constraints

**Always:**
- Le contrat est **rédigé une seule fois, ici** (AD-4). Les stories 2.2 et 2.3 le consomment sans
  l'étendre.
- `/api/v1/` **s'ajoute** aux routes non versionnées existantes de Homeport ; aucune d'elles n'est
  modifiée, renommée ni supprimée — le front web de Homeport en dépend.
- Le contrat couvre les trois surfaces d'un coup : `capabilities`, `events`, `metrics`. Un contrat
  partiel obligerait à une v2 dès la story 2.3.
- **Un seul epoch, pour tout l'historique.** Vérifié côté Homeport : événements, échantillons de
  métriques et actions vivent dans un unique fichier (`history.db`, surchargeable par
  `HOMEPORT_DB_PATH`). Une restauration les remplace donc ensemble ; deux epochs séparés
  décriraient une désynchronisation qui ne peut pas se produire.
- **`capabilities` et `/healthz` restent indépendants**, délibérément. `/healthz` est le
  diagnostic interrogé par SSH (AD-3) et `FleetHealth` raisonne dessus ; `capabilities` est la
  poignée de main du contrat HTTP. Les fusionner casserait le chemin SSH — le contrat doit
  l'interdire explicitement pour qu'aucun implémenteur ne « simplifie » dans ce sens.
- Toute forme décrite dans le contrat doit être **servable par un Pi réel** : ce qui n'existe pas
  encore côté Homeport est décrit comme à construire, jamais supposé présent.
- Le document versionné et la déclaration de version dans le code disent la **même** plage.

**Ask First:**
- Toute rupture de compatibilité avec une route non versionnée existante de Homeport.
- Tout ajout d'authentification ou de chiffrement au transport (AD-3 fige HTTP clair sur tailnet).

**Never:**
- Écrire le client `HomeportAPIClient`, l'onglet Événements, `hpm events`, ou quoi que ce soit qui
  consomme le contrat — c'est la story 2.2.
- Toucher au repo Homeport depuis cette story : l'implémentation serveur est un chantier distinct.
- Marquer la story `done`. Ses critères 2 et 3 exigent « un Homeport exposant l'API » ; aucune story
  de cet epic ne se clôt tant que l'API n'est pas live sur une machine de test.
- Introduire un stream (SSE/WebSocket) : le pull à curseur est le mécanisme de vérité en v1.
- Persister côté Mac une copie d'événements ou de métriques (AD-6 : le Pi en est propriétaire).

## I/O & Edge-Case Matrix

La matrice porte sur la **seule logique exécutable livrée ici** : la décision de compatibilité entre
la version de contrat annoncée par un serveur et la plage que hpm déclare consommer.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Version dans la plage | `1.0.0`, plage `>=1.0.0 <2.0.0` | compatible | N/A |
| Mineure plus récente | `1.4.2` | compatible — les ajouts mineurs sont rétro-compatibles | N/A |
| Majeure en avance | `2.0.0` | incompatible, motif « trop récente » | jamais une erreur : c'est un état affichable |
| Antérieure au plancher | `0.9.0` | incompatible, motif « trop ancienne » | idem |
| Version illisible | `""`, `abc`, `1.2` | incompatible, motif « illisible » | aucune exception levée |
| Suffixe de pré-version | `1.1.0-rc1` | incompatible — une pré-version n'engage pas le contrat | aucune exception levée |

</frozen-after-approval>

## Code Map

- `docs/api/` -- **à créer**. Reçoit la copie épinglée du contrat (AD-4).
- `docs/specs/architecture/architecture-HomePortManager-2026-08-23/ARCHITECTURE-SPINE.md` --
  lecture seule. AD-3 (transport), AD-4 (contrat, rédacteur unique), AD-5 (curseur `(epoch, id)`,
  deux marqueurs distincts), AD-6 (propriétaire unique), AD-8 (4 échelles de métriques), AD-16
  (jobs du Pi en événements).
- `Sources/HomePortKit/RemotePaths.swift` -- modèle de style pour une déclaration `enum` sans
  dépendance ; c'est le voisin le plus proche du fichier à créer.
- `Sources/HomePortKit/ReleaseService.swift` -- vérifié : **aucune** comparaison semver réutilisable
  n'existe (il ne fait que lister des tags). La comparaison est donc à écrire.
- `Sources/HomePortKit/HPMError.swift` -- l'erreur maison ; ici inutile, la compatibilité se répond
  par une valeur, jamais par un `throw`.
- `Tests/HomePortKitTests/MachineIssueTests.swift` -- modèle de test d'énumération pure du Kit.
- **Repo miroir `../Homeport` (0.7.2), lecture seule, hors périmètre d'écriture** — état constaté
  qui contraint ce que le contrat peut exiger :
  - `homeport/main.py` -- routes non versionnées existantes (`/api/status`, `/api/history`,
    `/api/devices`, `/api/actions`, `/api/events`, `/api/logs/{name}`, `/healthz`…). `/healthz`
    renvoie `{status, version}` et ne connaît pas le contrat.
  - `homeport/collectors/events.py` -- table `events` avec `id INTEGER PRIMARY KEY AUTOINCREMENT` :
    l'identifiant monotone du curseur **existe déjà**, il n'est simplement pas exposé.
  - `homeport/events_watch.py` -- les seules sévérités émises sont `up`, `warn`, `down`, et le
    vocabulaire de `kind` est fermé (`service.*`, `internet.*`, `livebox.*`, `ip.changed`,
    `backup.*`, `power.undervoltage`, `temp.high`, `boot`, `action.*`).
  - `homeport/collectors/history.py` -- table `samples` (`ts`, `cpu_pct`, `mem_pct`, `temp_c`,
    `nvme_temp_c`) : une seule échelle, **pas de disque**. Les 4 échelles d'AD-8 et la série disque
    sont à construire côté serveur.
  - Aucun epoch nulle part : c'est le mécanisme entièrement neuf du contrat.
- `Sources/HomePortKit/Dashboard.swift` -- vérifié : HomePortManager ne consomme **aucune** route
  `/api/` (il n'ouvre qu'une WebView sur `/`). Ajouter `/api/v1/` ne peut donc rien régresser côté
  Mac.

## Tasks & Acceptance

**Execution:**
- [x] `docs/api/homeport-api-v1.md` -- rédiger le contrat v1 complet -- c'est le livrable de la
      story : base `/api/v1/` coexistant avec l'existant ; `capabilities` (version de contrat,
      version serveur, epoch, features servies, et son indépendance assumée vis-à-vis de
      `/healthz`) ; `events` (pagination par curseur `(epoch, id)`, `latest_id` et la règle
      d'invalidation du curseur qui va avec, sévérités `info`/`warning`/`critical` avec leur
      correspondance depuis `up`/`warn`/`down`, vocabulaire de `kind`) ; `metrics` (4 séries,
      4 plages, pas d'échantillonnage par plage, trous explicites) ; règle semver ; obligations de
      génération et de régénération de l'epoch ; comportement attendu d'un serveur qui ne sert pas
      une feature ; ce qu'un client ne doit jamais supposer.
- [x] `Sources/HomePortKit/HomeportAPIContract.swift` -- créer la déclaration de la plage consommée
      et la décision de compatibilité -- le contrat doit être exécutable, pas seulement écrit ; la
      story 2.2 s'y branche sans re-trancher.
- [x] `Tests/HomePortKitTests/HomeportAPIContractTests.swift` -- couvrir les six lignes de la
      matrice -- une plage de versions non testée est une plage supposée.
- [x] `docs/build/deferred-work.md` -- consigner que l'implémentation serveur et le client sont hors
      de cette story -- pour qu'un lecteur ne prenne pas le contrat écrit pour une API livrée.

**Acceptance Criteria:**
- Given le contrat épinglé et la déclaration dans le code, when on compare la plage que chacun
  énonce, then c'est la même — et un test le vérifie plutôt qu'une relecture.
- Given un développeur du repo Homeport qui ne connaît que ce document, when il implémente
  `capabilities`, `events` et `metrics`, then il n'a besoin d'aucune information supplémentaire :
  chaque champ a un type, une unité quand elle s'applique, et un comportement défini quand la
  donnée manque.
- Given ce spec mené à son terme, when on lit `sprint-status.yaml`, then la clé
  `2-1-contrat-api-v1-et-flux-d-événements` porte `in-progress`, jamais `done` : le spec couvre le
  premier critère d'acceptation et s'achève, la story reste ouverte parce que ses critères 2 et 3
  sont invérifiables sans une API live. Ce sont deux états distincts — celui d'un document et celui
  d'une story.

## Spec Change Log

## Design Notes

**Pourquoi le contrat n'est pas dans ce fichier.** AD-4 fait de cette story le rédacteur unique de
la v1 ; il place aussi la source de vérité dans le repo Homeport et la copie épinglée sous
`docs/api/`. Le contrat est donc un document à part, que ce spec commande et contraint — l'inclure
ici en produirait une seconde copie, exactement ce qu'AD-4 cherche à éviter.

**Pourquoi un epoch et pas seulement un id.** Un `AUTOINCREMENT` SQLite repart à 1 quand la table
est recréée. Après un restore côté Pi, un curseur `id=500` sauterait silencieusement les 500
premiers événements de la nouvelle base. L'epoch rend cette rupture visible : le client voit un
epoch qu'il ne connaît pas et repart de son début, au lieu de perdre des événements sans le savoir.

**Ce que le contrat doit exiger de l'epoch, et pourquoi ça ne suffit pas.** L'epoch est une chaîne
opaque, stockée dans la base elle-même, créée en même temps qu'elle et régénérée par tout chemin
qui réinitialise ou restaure l'historique. Mais cette exigence est une **discipline serveur**, et
une discipline se contourne : restaurer `history.db` par une simple copie de fichier ramène
l'ancien epoch **avec** des identifiants plus bas, et le client, voyant un epoch qu'il connaît,
continuerait à demander « après 500 » dans une base qui n'en a plus que 200 — silence total.

Le contrat ferme ce trou du côté qu'il contrôle vraiment, le client : la réponse `events` annonce
le `latest_id` de l'epoch courant, et le client tient son curseur pour invalide **soit** si l'epoch
a changé, **soit** si `latest_id` est inférieur à son curseur. Une régression d'identifiant devient
alors aussi visible qu'un changement d'epoch, quelle que soit la façon dont la base a été remise en
place. C'est la raison d'être de `latest_id` : sans lui, la correction dépendrait entièrement du
soin apporté à chaque procédure de restauration.

**Pourquoi une sévérité inconnue vaut `warning`.** Une v1.1 pourrait introduire une sévérité que ce
client ne connaît pas. La traiter comme `info` la rendrait invisible ; comme `critical` elle
notifierait à tort. `warning` la rend visible sans réveiller personne — et la règle « seuls les
`critical` notifient » (story 2.2) reste vraie sans exception.

## Verification

**Commands:**
- `swift build` -- expected: compile sans avertissement.
- `swift test --filter HomeportAPIContractTests` -- expected: les six scénarios de la matrice
  passent.
- `swift test` -- expected: aucune régression sur la suite existante.
- `bash Scripts/verify-app-build.sh` -- expected: rc 0.

**Manual checks (if no CLI):**
- Relire `docs/api/homeport-api-v1.md` en se mettant à la place de l'implémenteur serveur : chaque
  endpoint a-t-il un exemple de réponse complet, et chaque champ un comportement défini quand la
  donnée est absente ?
- Vérifier que la plage semver du document et celle de `HomeportAPIContract.swift` coïncident.
