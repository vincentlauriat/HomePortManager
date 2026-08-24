# Contrat API Homeport — v1

**Version de contrat : `1.0.0`** · Rédigé le 2026-08-24 (story 2.1, epic 2)

## Statut de ce document

Ce fichier est la **copie épinglée** du contrat, conservée dans HomePortManager pour que le client
et ses tests puissent s'y référer sans dépendre d'un autre dépôt. La **source de vérité** vit dans
le dépôt Homeport, qui sert l'API ; les deux copies doivent porter la même version et le même
contenu. En cas de divergence constatée, la copie Homeport fait foi et celle-ci est corrigée.

Le contrat est rédigé une seule fois, par la story 2.1. Les stories qui le consomment ne l'étendent
pas : un besoin nouveau passe par une révision de ce document, jamais par un champ ajouté à la
volée d'un côté ou de l'autre.

**Au moment de la rédaction, aucune des routes décrites ici n'existe.** Homeport 0.7.2 sert des
routes non versionnées à son propre front web. Ce document décrit ce qui est **à construire**, en
s'appuyant sur ce qui est déjà là quand c'est possible — l'identifiant monotone des événements, par
exemple, existe en base et n'a qu'à être exposé — et en signalant ce qui est entièrement neuf :
l'epoch, les quatre échelles de métriques, la série disque.

## 1. Versionnement

Le champ `contract` suit le versionnement sémantique et décrit **le contrat, pas le serveur**.

| Incrément | Signification | Exemple |
|---|---|---|
| Majeur | Rupture : un champ disparaît, change de type, d'unité ou de sens | `1.4.0` → `2.0.0` |
| Mineur | Ajout rétro-compatible : nouveau champ optionnel, nouvel endpoint, nouvelle valeur d'énumération | `1.0.0` → `1.1.0` |
| Correctif | Clarification rédactionnelle sans effet sur les données servies | `1.0.0` → `1.0.1` |

**Plage consommée par hpm : `>= 1.0.0` et `< 2.0.0`.** Cette plage est déclarée dans le code à
`Sources/HomePortKit/HomeportAPIContract.swift` ; les deux doivent dire la même chose.

Une version portant un suffixe de pré-version (`1.1.0-rc1`) **n'engage pas** le contrat : un client
la traite comme incompatible. Une pré-version sert à essayer, pas à s'appuyer dessus.

Ajouter une valeur à une énumération est un incrément **mineur**, et c'est pour cela que ce contrat
impose partout une conduite à tenir face à une valeur inconnue : un client de la v1.0 doit survivre
à un serveur v1.4.

## 2. Transport

HTTP en clair, sur le tailnet, sur le même port que l'interface web de Homeport. Pas
d'authentification en v1 : l'API est en lecture seule et l'accès au tailnet fait office de
périmètre. Tout ajout d'authentification ou de chiffrement est une décision d'architecture, pas un
détail d'implémentation.

Toutes les réponses sont en `application/json; charset=utf-8`.

## 3. Coexistence avec l'existant

Les routes `/api/v1/…` **s'ajoutent**. Les routes non versionnées actuelles (`/api/status`,
`/api/history`, `/api/devices`, `/api/actions`, `/api/events`, `/api/logs/{name}`…) alimentent le
front web de Homeport : aucune n'est modifiée, renommée ni supprimée par cette v1.

**`/healthz` reste indépendant de `capabilities`, et ce n'est pas un oubli.** `/healthz` est le
point de diagnostic interrogé par SSH depuis le Mac, sur lequel repose déjà la surveillance de
flotte ; `capabilities` est la poignée de main du contrat HTTP. Les deux annoncent une version de
serveur, et cette redondance est assumée : fusionner les deux points d'entrée casserait le chemin
de diagnostic. Ne pas « simplifier » dans ce sens.

## 4. `GET /api/v1/capabilities`

Le premier appel de tout client. Il répond à trois questions : quelle version du contrat, quelles
surfaces réellement servies, et quelle génération d'historique.

```
GET /api/v1/capabilities
```

```json
{
  "contract": "1.0.0",
  "server": "0.8.0",
  "epoch": "0f8a4c2e-9d51-4b77-b3a0-6c1d2e5f8a90",
  "features": ["events", "metrics"]
}
```

| Champ | Type | Sens |
|---|---|---|
| `contract` | chaîne | Version de ce contrat, en semver strict, sans préfixe `v` |
| `server` | chaîne | Version de Homeport, à titre informatif — jamais utilisée pour décider d'une compatibilité |
| `epoch` | chaîne | Identité de la génération courante de l'historique (§5) |
| `features` | tableau de chaînes | Surfaces réellement servies par cette instance |

`features` est **la** source de vérité sur ce qui est disponible. Un client ne sonde pas un endpoint
pour découvrir s'il existe : il lit `features`, et s'abstient si la surface n'y figure pas. Les
valeurs de la v1 sont `"events"` et `"metrics"` ; une valeur inconnue est ignorée sans erreur.

Une réponse à laquelle il manque `contract`, `epoch` ou `features`, ou dont l'un de ces champs
n'a pas le type annoncé, est traitée **exactement comme un 404** : la poignée de main n'a pas eu
lieu. Un client ne devine pas un champ manquant et n'essaie pas de continuer sans lui.

Un serveur qui ne connaît pas du tout l'API répond **404** à cette route. C'est un état normal et
attendu, pas une panne : il signifie « cette version ne sait pas encore faire », et se présente à
l'utilisateur comme tel.

## 5. L'epoch et le curseur

Le curseur d'un client est le couple **`(epoch, id)`**.

L'`epoch` est une **chaîne opaque** — un client ne l'interprète jamais, ne la compare que par
égalité, et ne suppose ni format ni ordre. Elle identifie une génération de l'historique.

**Obligations du serveur.** L'epoch est stocké dans la base d'historique elle-même et créé avec
elle. Le serveur doit le **régénérer dès qu'il constate** que la base sous ses pieds n'est plus
celle qui portait l'epoch précédent — base recréée à vide, base d'une autre génération déposée à
la place. Deux générations distinctes ne partagent jamais un epoch *que le serveur ait pu
distinguer*.

**Pourquoi le client ne s'en contente pas.** Cette obligation s'arrête là où s'arrête ce que le
serveur peut constater, et une restauration n'est pas un geste qu'il voit passer : elle vient de
l'extérieur, arrête le service, remplace ses fichiers, le relance. Si elle remplace *tout* l'état
du serveur — la base et le marqueur qui atteste de son identité — celui-ci redémarre en trouvant
deux copies concordantes d'un epoch qui n'est plus le sien. Il continue de servir l'ancien
identifiant sur une base plus courte, et un client qui se fierait au seul epoch demanderait
« après 1481 » dans une base qui n'en compte plus que 200, sans jamais l'apprendre.

C'est la raison d'être de `latest_id`, que la réponse `events` annonce à chaque appel. **Un client
tient son curseur pour invalide dès que l'une de ces deux conditions est vraie :**

1. l'`epoch` reçu diffère de celui de son curseur ;
2. le `latest_id` reçu est **inférieur** à l'`id` de son curseur.

Dans les deux cas il repart du début de l'epoch courant. La seconde condition rend une régression
d'identifiant aussi visible qu'un changement d'epoch, quelle que soit la manière dont la base a été
remise en place.

**Ce que cette garantie ne couvre pas.** Un restore qui ramène l'ancien epoch laisse une fenêtre
ouverte : entre le moment où il remet la base en place et le sondage suivant du client, si
l'historique regrossit au-delà du curseur, ni l'epoch ni `latest_id` ne diffèrent et la
substitution passe inaperçue.

Cette fenêtre n'est pas une bizarrerie de coin : c'est le comportement du chemin de restauration
normal. `hpm restore` remplace l'intégralité du répertoire de données de la machine, marqueur
d'identité compris, ce qui prive le serveur de tout moyen de constater la substitution. Un client
doit donc traiter `latest_id` comme sa protection réelle, et non comme un filet de secours derrière
un epoch supposé fiable.

Fermer complètement ce cas demanderait soit au client de revérifier à chaque appel que l'événement
portant l'identifiant de son curseur existe toujours et n'a pas changé — un coût permanent pour une
fenêtre étroite — soit au chemin de restauration lui-même d'invalider l'epoch après avoir reposé la
base, ce qui déplace l'obligation vers l'outil qui restaure. La v1 accepte sciemment la fenêtre ;
la seconde parade reste ouverte pour une version ultérieure.

Un client ne signale pas un changement d'epoch comme une erreur : c'est un événement normal du cycle
de vie d'une machine.

## 6. `GET /api/v1/events`

Servi seulement si `"events"` figure dans `features`.

```
GET /api/v1/events?since_id=1481&limit=200
```

| Paramètre | Type | Défaut | Sens |
|---|---|---|---|
| `since_id` | entier ≥ 0 | `0` | Ne renvoyer que les événements dont l'`id` est **strictement supérieur** |
| `since_epoch` | chaîne | absent | Epoch du curseur du client, à titre indicatif |
| `limit` | entier 1–1000 | `200` | Nombre maximal d'événements renvoyés |
| `severity` | chaîne | absent | Filtre, valeurs séparées par des virgules (`warning,critical`) |

Une valeur hors bornes est **ramenée dans les bornes**, jamais rejetée : `limit=5000` sert 1000.
Une valeur numérique illisible (`limit=abc`) retombe sur le défaut documenté, sans erreur. Une
valeur de `severity` hors des trois connues est **ignorée** — le filtre porte alors sur les seules
valeurs reconnues, en écho à la conduite du client face à une sévérité inconnue.

`since_epoch` est facultatif, et un client qui détient un epoch a tout intérêt à l'envoyer. En son
absence le serveur **ne peut pas** détecter que le curseur appartient à une autre génération : il
applique `since_id` tel quel. La détection repose alors entièrement sur le client, qui compare
l'`epoch` et le `latest_id` reçus à son curseur (§5). Envoyer `since_epoch` ajoute une seconde
chance de détection, côté serveur, plus tôt.

Si `since_epoch` est fourni et ne correspond pas à l'epoch courant, le serveur **ne renvoie pas
d'erreur** : il sert depuis le début de l'epoch courant en ignorant `since_id`, et annonce son epoch
dans la réponse. C'est au client de constater le changement.

```json
{
  "epoch": "0f8a4c2e-9d51-4b77-b3a0-6c1d2e5f8a90",
  "latest_id": 1483,
  "events": [
    {
      "id": 1482,
      "ts": 1756041600,
      "kind": "service.down",
      "severity": "critical",
      "subject": "homeassistant",
      "detail": null
    },
    {
      "id": 1483,
      "ts": 1756041615,
      "kind": "backup.ok",
      "severity": "info",
      "subject": "homeassistant",
      "detail": "homeassistant-2026-08-24.tar.gz"
    }
  ],
  "has_more": false
}
```

| Champ | Type | Sens |
|---|---|---|
| `epoch` | chaîne | Epoch courant, toujours présent |
| `latest_id` | entier | Plus grand `id` existant dans cet epoch, indépendamment du filtre et de `limit` ; `0` si l'historique est vide |
| `events` | tableau | Les événements, **du plus ancien au plus récent** |
| `has_more` | booléen | Vrai s'il reste des événements après le dernier renvoyé |

L'ordre croissant est délibéré et diffère de la route non versionnée existante, qui sert du plus
récent au plus ancien. Un curseur se déplace vers l'avant : le client avance son curseur jusqu'à
l'`id` du dernier élément reçu, puis rappelle tant que `has_more` est vrai.

### Champs d'un événement

| Champ | Type | Sens |
|---|---|---|
| `id` | entier | Strictement croissant à l'intérieur d'un epoch. **Non contigu** : une purge laisse des trous |
| `ts` | entier | Instant de l'événement, secondes Unix UTC |
| `kind` | chaîne | Nature de l'événement (voir plus bas) |
| `severity` | chaîne | `info`, `warning` ou `critical` |
| `subject` | chaîne | Ce que l'événement concerne : nom de service, `internet`, `cpu`, `system`… |
| `detail` | chaîne ou `null` | Précision libre, destinée à l'affichage. Jamais analysée par un client |

`ts` n'est **pas** garanti croissant avec `id` : un ajustement d'horloge sur le Pi peut produire un
événement plus récent portant un horodatage antérieur. L'ordre de lecture, lui, est celui des `id`.

### Sévérités

Trois valeurs en v1, dérivées de ce que Homeport consigne déjà :

| `severity` v1 | Valeur consignée en interne | Produit une notification macOS |
|---|---|---|
| `info` | `up` | non |
| `warning` | `warn` | non |
| `critical` | `down` | oui |

**Une valeur inconnue est traitée comme `warning`.** Une version mineure ultérieure pourrait en
introduire une : la rabattre sur `info` la rendrait invisible, sur `critical` elle réveillerait pour
rien. `warning` la rend visible sans notifier — et la règle « seuls les `critical` notifient » reste
vraie sans exception.

### Vocabulaire de `kind`

Un `kind` se lit `famille.détail`, ou tient en un seul mot. Familles émises aujourd'hui :

| Famille | Exemples | Ce que ça couvre |
|---|---|---|
| `service.` | `service.up`, `service.degraded`, `service.down` | Cycle de vie d'un service supervisé |
| `internet.` | `internet.up`, `internet.down` | Connectivité sortante |
| `livebox.` | `livebox.up`, `livebox.down` | Joignabilité de la box |
| `ip.` | `ip.changed` | Adresse publique modifiée |
| `backup.` | `backup.ok`, `backup.stale`, `backup.failed` | Résultat d'une sauvegarde, y compris déclenchée par un timer du Pi |
| `power.` | `power.undervoltage` | Alimentation insuffisante |
| `temp.` | `temp.high` | Seuil de température franchi |
| *(sans famille)* | `boot` | Démarrage de la machine |

**Cette liste est ouverte.** Un client ne doit ni la considérer comme fermée, ni faire dépendre son
affichage de la reconnaissance d'un `kind` : un `kind` inconnu s'affiche tel quel, avec sa sévérité.
La famille — ce qui précède le premier point — est le seul découpage sur lequel un client peut
s'appuyer, et seulement pour regrouper.

**Les actions administratives ne figurent pas dans ce flux.** La route non versionnée
`/api/events` les fusionne à la lecture, parce qu'elle sert un livre de bord trié par date. Ici
c'est impossible : elles vivent dans une autre table, avec leur propre séquence d'identifiants, et
les entrelacer briserait la monotonie sur laquelle repose tout le curseur. Un client v1 voit donc
le journal d'événements de la machine, pas l'historique des gestes d'administration menés depuis
l'interface web de Homeport.

Un `detail` absent ne veut jamais dire que l'information n'existe pas : il peut n'avoir jamais été
consigné, ou être masqué selon l'appelant.

## 7. `GET /api/v1/metrics`

Servi seulement si `"metrics"` figure dans `features`.

```
GET /api/v1/metrics?range=24h
```

| Paramètre | Valeurs | Défaut |
|---|---|---|
| `range` | `24h`, `7d`, `30d`, `1y` | `24h` |

Une valeur de `range` non reconnue est une **erreur 400** — contrairement aux bornes numériques
d'`events`, il n'existe pas de valeur voisine raisonnable vers laquelle se rabattre.

Chaque plage a **un seul** pas d'échantillonnage, choisi pour que le stockage sur le Pi reste borné.
Le serveur sert l'échelle qui correspond ; le client ne ré-échantillonne pas.

| `range` | `step_s` | Points |
|---|---|---|
| `24h` | `60` | 1 440 |
| `7d` | `300` | 2 016 |
| `30d` | `3600` | 720 |
| `1y` | `86400` | 365 |

```json
{
  "epoch": "0f8a4c2e-9d51-4b77-b3a0-6c1d2e5f8a90",
  "range": "24h",
  "step_s": 60,
  "from": 1755955200,
  "to": 1756041600,
  "series": {
    "cpu_pct":  [12.4, 13.0, null, 11.8],
    "mem_pct":  [41.2, 41.3, null, 41.1],
    "disk_pct": [67.0, 67.0, null, 67.0],
    "temp_c":   [48.5, 49.0, null, 47.9]
  }
}
```

Les séries sont abrégées ici à quatre points pour tenir dans l'exemple : à `range=24h` chacune en
compte 1 440. Un tableau ne contient que des nombres et des `null` — jamais une chaîne.

Le serveur **aligne `from` et `to` sur des multiples de `step_s`** avant de composer la fenêtre, de
sorte que `(to - from)` en soit toujours un multiple exact et que la longueur des séries ne soit
jamais ambiguë. Un client peut donc calculer cette longueur lui-même et s'attendre à la retrouver.

L'`epoch` de cette réponse obéit à la même règle qu'ailleurs : s'il diffère de celui du curseur du
client, l'historique a changé de génération et les courbes déjà affichées ne s'y raccordent pas.

| Champ | Type | Sens |
|---|---|---|
| `epoch` | chaîne | Même epoch que celui d'`events` : l'historique est un tout |
| `range`, `step_s` | chaîne, entier | La plage servie et son pas, en secondes |
| `from`, `to` | entiers | Bornes de la fenêtre, secondes Unix UTC. `from` est inclus, `to` exclu |
| `series` | objet | Une entrée par série, chacune un tableau de nombres ou de `null` |

**Les séries sont posées sur une grille régulière, pas sur des paires horodatées.** L'instant du
point d'indice `i` vaut `from + i * step_s`. Les quatre tableaux ont donc exactement la même
longueur, égale à `(to - from) / step_s`, et un client peut les superposer sans les aligner.

Un point **`null` signifie « pas de mesure »** — machine éteinte, capteur absent, service arrêté. Un
`null` n'est jamais un zéro et ne s'interpole pas : une courbe s'interrompt là.

| Série | Unité | Plage | Absente quand |
|---|---|---|---|
| `cpu_pct` | pourcentage | 0–100 | — |
| `mem_pct` | pourcentage | 0–100 | — |
| `disk_pct` | pourcentage | 0–100 | Occupation du système de fichiers racine |
| `temp_c` | degrés Celsius | — | La machine n'expose pas de capteur thermique |

Une série qu'une machine ne peut pas produire est présente avec **tous ses points à `null`**, jamais
absente de `series` : le client affiche alors une carte vide plutôt que de perdre une des quatre.

Une version mineure ultérieure peut ajouter une série. Un client de la v1.0 ignore les clés de
`series` qu'il ne connaît pas.

## 8. Ce qu'un client conclut d'un échec

Aucune de ces situations n'est présentée à l'utilisateur comme une erreur.

| Situation | Ce que ça veut dire | Ce que le client fait |
|---|---|---|
| **404** sur `capabilities` | Version de Homeport antérieure à l'API | État « non disponible », orienté vers une mise à jour |
| `contract` hors de la plage consommée | Serveur trop ancien ou trop récent pour ce client | Idem, en nommant la version rencontrée |
| Surface absente de `features` | Cette instance ne sert pas cette surface | État « non disponible » sur l'onglet concerné seulement |
| Erreur réseau, délai dépassé | Machine injoignable | État « injoignable », **distinct** de « non disponible » : les dernières données connues restent affichées avec l'heure de dernière vue |
| Surface annoncée dans `features` mais répondant **404** | L'annonce et le service ne concordent pas | Traité exactement comme une surface absente de `features` — jamais comme une panne |
| **400** sur `metrics` | `range` inconnu : une erreur du client, pas du serveur | Corriger l'appel. Ne pas réessayer à l'identique, ne rien invalider |
| **5xx** | Défaillance côté serveur | Traité comme « injoignable » : réessayer plus tard, ne rien invalider |

La distinction entre « ne sait pas encore faire » et « ne répond pas » est structurante : la
première se résout par une mise à jour, la seconde par une intervention sur la machine. Les
confondre enverrait l'utilisateur au mauvais endroit.

## 9. Ce qu'un client ne doit jamais supposer

- Que les `id` sont **contigus** — une purge de rétention laisse des trous.
- Que `ts` **croît avec `id`** — l'horloge d'un Pi peut reculer.
- Que la liste des `kind` est **fermée**.
- Que `detail` est **présent** — il peut être masqué, ou n'avoir jamais existé.
- Que deux appels successifs voient le **même epoch**.
- Qu'une série de métriques **contient au moins une mesure**.
- Que `server` dit quoi que ce soit sur la **compatibilité** — seul `contract` en décide.

## 10. Obligations du serveur

Récapitulatif à l'usage de l'implémentation dans le dépôt Homeport.

1. Servir `/api/v1/capabilities` en annonçant `contract`, `server`, `epoch` et `features`, et n'y
   déclarer que les surfaces réellement servies.
2. Stocker un epoch dans la base d'historique, créé avec elle, et le **régénérer dès qu'il constate
   une substitution** — base recréée, base d'une autre génération déposée à sa place. Le serveur
   n'est pas tenu de détecter une restauration qui remplace aussi son marqueur d'identité (§5) ;
   c'est `latest_id` qui protège le client dans ce cas.
3. Exposer l'identifiant d'événement déjà présent en base, servir en ordre **croissant**, et
   accompagner chaque réponse de `latest_id` — indépendant du filtre et de `limit`.
4. Normaliser les sévérités internes vers `info` / `warning` / `critical`, et rabattre sur
   `warning` toute valeur interne qui n'a pas de correspondance — jamais l'omettre, jamais servir
   la valeur brute. C'est la règle du client, appliquée symétriquement.
5. Ramener les paramètres numériques hors bornes dans les bornes plutôt que de les rejeter ; ne
   rejeter en 400 qu'un `range` inconnu.
6. Ne jamais répondre en erreur à un `since_epoch` périmé : servir depuis le début et annoncer
   l'epoch courant.
7. Agréger les métriques en quatre échelles bornées et servir des séries de longueur égale, alignées
   sur `from + i * step_s`, trous à `null`.
8. Ajouter la série `disk_pct`, absente de la collecte historisée actuelle.
9. Laisser intactes les routes non versionnées et `/healthz`.

## 11. Journal des versions

| Version | Date | Changement |
|---|---|---|
| `1.0.0` | 2026-08-24 | Contrat initial : `capabilities`, `events`, `metrics` |

Amendé le 2026-08-24, avant toute publication, à la lumière de l'implémentation serveur :

- la famille `action.` a été retirée du flux v1 — les actions administratives sont stockées à part
  et les entrelacer casserait la monotonie du curseur ;
- l'obligation « régénérer l'epoch à toute restauration » (§5, §8) a été ramenée à ce que le
  serveur peut réellement tenir. La vérification de `hpm restore` a montré qu'il remplace tout le
  répertoire de données, marqueur d'identité compris : le serveur ne voit rien passer. Le texte
  présentait ce cas comme résiduel alors qu'il est le chemin de restauration normal.

La version reste `1.0.0`, le contrat n'ayant jamais été servi ni consommé jusque-là.
