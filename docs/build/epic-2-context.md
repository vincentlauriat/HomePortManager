# Epic 2 Context: La flotte se raconte toute seule

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Les machines de la flotte cessent d'être muettes entre deux inspections. Ce qui se passe sur un Pi
— un service qui tombe, un backup qui échoue, une température qui grimpe, une IP qui change —
remonte de lui-même dans la console, sans que personne ait à s'y connecter ; les incidents graves
produisent en plus une notification macOS. Et les mesures de santé (CPU, RAM, disque, température)
deviennent consultables en courbes sur la durée, y compris pour les périodes où la console était
fermée — parce que l'historique vit sur le Pi, pas sur le Mac.

Le fil rouge de l'epic est un **contrat** : une API versionnée servie par Homeport et consommée par
HomePortManager. Tout le reste en découle, y compris la façon dont l'absence de cette API doit se
présenter à l'utilisateur.

## Stories

- Story 2.1 : Contrat API v1 (`done`)
- Story 2.2a : Flux d'événements et onglet Événements (`HomeportAPIClient`, curseur, `hpm events`)
- Story 2.2b : Notifications critiques et politique de repli (dépend de 2.2a)
- Story 2.3 : Métriques historisées

> **Amendement 28/08** : l'ex-story 2.2 (« Notifications critiques et dégradation sans API », qui
> portait aussi le client d'événements replié depuis 2.1) a été scindée en 2.2a/2.2b après un run
> `bmad-loop` sur le périmètre unifié : la session dev a heurté `session_timeout_min = 90` (90,02 min,
> 3 compactions) et `max_tokens_per_story = 2 000 000` (3 844 048 consommés) sans committer une seule
> ligne. Voir `docs/specs/epics.md` Epic 2 pour les ACs détaillées de 2.2a/2.2b.

## Requirements & Constraints

- **Les événements remontent sans intervention.** Un healthz KO ou un restart survenu sur un Pi
  apparaît dans la console sans geste manuel. Les événements portent une sévérité, affichée en pill
  et filtrable.
- **Les critiques notifient, les autres non.** Un événement critique produit une notification macOS
  localisée dont le clic ouvre la fiche de la machine concernée sur l'onglet Événements. Les
  événements non critiques ne produisent aucune notification. Une machine relève d'une seule
  politique de notification à la fois — jamais des événements *et* des transitions menubar.
- **Une version qui ne sait pas encore n'est pas une panne.** Une machine dont le Homeport ne sert
  pas l'API doit produire un empty-state explicatif orienté vers Updates, jamais un message
  d'erreur. Cet état « non disponible » est visuellement distinct de « injoignable » (erreur
  réseau), qui conserve les derniers événements connus et l'heure de dernière vue.
- **Aucune perte silencieuse.** Une réinitialisation de l'historique côté Pi ne doit ni provoquer
  d'erreur ni faire disparaître des événements sans trace : le client doit le détecter et repartir
  proprement.
- **Chaque surface graphique a sa jumelle CLI.** `hpm events` et `hpm metrics` doivent offrir le
  même contenu filtré que les onglets correspondants.
- **Les métriques couvrent le long terme.** Plages 24 h / 7 j / 30 j / 1 an, avec une granularité
  bornée pour que le stockage sur le Pi reste fini.

## Technical Decisions

- **Un contrat, un rédacteur.** L'API (capabilities + events + metrics) est un document versionné en
  semver. Sa source de vérité vit dans le repo Homeport ; HomePortManager en conserve une copie
  épinglée sous `docs/api/` et déclare la plage de versions qu'il consomme. La story 2.1 rédige
  seule la v1 complète ; les stories 2.2a, 2.2b et 2.3 la consomment **sans l'étendre**.
- **`capabilities` est le point d'entrée.** Il annonce la version du contrat, les features
  réellement servies par cette instance, et l'epoch de génération de l'historique. C'est ce qui
  permet de distinguer « cette version ne sait pas faire » de « c'est cassé ».
- **Événements en pull, curseur `(epoch, id)`.** Pas de stream en v1. Le centre interroge
  périodiquement (30–60 s) les événements postérieurs à son curseur. L'`id` est monotone à
  l'intérieur d'un epoch ; un reset ou un restore côté Pi incrémente l'epoch, ce que le client
  détecte pour repartir du début du nouvel epoch.
- **Lecture et notification sont deux marqueurs distincts** côté Mac, tous deux dans `hpm.db`, et la
  décision de notifier vit dans HomePortKit — jamais dans un frontend. C'est ce qui permet à
  `hpm events` d'avancer la lecture sans jamais escamoter une notification.
- **Un propriétaire unique par donnée.** L'historique des événements et celui des métriques
  appartiennent au Pi ; le Mac n'en persiste que des curseurs et des marqueurs. Aucune copie
  durable côté Mac.
- **Métriques agrégées côté Pi en 4 échelles** — 24 h @ 1 min, 7 j @ 5 min, 30 j @ 1 h, 1 an @ 1 j —
  pour un stockage borné. L'API sert l'échelle adaptée à la plage demandée ; le client ne
  ré-échantillonne pas.
- **Transport.** HTTP clair sur le tailnet, via l'unique exception App Transport Security déjà
  déclarée par l'app et partagée avec la WebView. Aucune story n'introduit son propre
  contournement. Le healthz de diagnostic reste, lui, vérifié par SSH sur la machine.
- **Les jobs du Pi se racontent en événements.** Le journal des tâches `hpm.db` ne consigne que les
  actions initiées par le Mac ; les exécutions déclenchées par un timer sur le Pi remontent comme
  événements et ne créent jamais d'entrée de journal.

## UX & Interaction Patterns

- Les onglets Événements et Métriques sont deux des onglets pills de la fiche machine, déjà en
  place avec leur empty-state depuis l'epic 1 — cet epic les remplit.
- La sévérité se lit en pill et porte **couleur et libellé** (jamais la couleur seule). La palette
  sémantique existante s'applique : le registre « warning » couvre le dégradé, l'API non
  disponible et le disque qui se remplit.
- Les valeurs numériques et les tables utilisent le style data en chiffres tabulaires.
- L'empty-state est la seule surface où la voix peut être chaleureuse ; il porte une action pill —
  ici, vers Updates.

## Cross-Story Dependencies

- 🚧 **Jalon bloquant, chantier miroir.** L'implémentation serveur de l'API vit dans le repo
  **Homeport**, hors de ce backlog. Aucune story de cet epic ne peut être clôturée tant que l'API
  n'est pas live sur au moins une machine de test. Le contrat, lui, est rédigeable immédiatement :
  c'est le chemin critique du planning, et ouvrir le chantier Homeport en parallèle est ce qui
  débloque tout le reste.
- **État de départ constaté côté Homeport (v0.7.2, août 2026)** : aucune route `/api/v1/` n'existe.
  Le serveur expose des routes non versionnées destinées à son propre front web (statut, historique,
  événements, actions, journaux). Un historique d'événements existe déjà avec un identifiant
  monotone exploitable, mais il n'est pas exposé et il n'y a ni notion d'epoch ni sévérités
  normalisées. Un historique de métriques existe à une seule échelle et ne couvre pas le disque.
  Les quatre échelles et la notion d'epoch sont donc à construire.
- **2.1 précède 2.2a, qui précède 2.2b, qui précède 2.3** : 2.1 pose le contrat seul. 2.2a construit
  le client d'événements, le curseur et l'onglet — la fondation exécutable. 2.2b s'y branche pour la
  décision de notifier et la dégradation (repli menubar single-policy) ; elle ne peut pas être menée
  avant que 2.2a existe. 2.3 consomme le volet métriques du contrat sans le modifier, indépendante de
  2.2a/2.2b.
- **Dépend de l'epic 1** pour le socle `hpm.db` (où vivent curseurs et marqueurs), la fiche machine
  et ses onglets, et la bibliothèque de composants.
