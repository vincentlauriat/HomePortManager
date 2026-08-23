---
id: SPEC-proxmox-inspired-fleet
companions: [brownfield.md, ../architecture/architecture-HomePortManager-2026-08-23/ARCHITECTURE-SPINE.md]
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# Centre de contrôle unifié de la flotte Homeport

## Why

Vision : faire de HomePortManager un véritable centre de contrôle unifié pour la flotte Homeport de Vincent. Aujourd'hui (v1.0.0), l'administration passe par des commandes CLI unitaires et une app menubar de statut : pas de vue d'ensemble riche, pas d'historique, pas de logs ni d'événements centralisés, et il faut visiter chaque Homeport individuellement. L'objectif est d'administrer toute la flotte — état, logs, événements, actions — depuis une seule fenêtre, en passant d'une machine à l'autre sans changer d'outil.

## Capabilities

- **CAP-1 — Tableau de bord global**
  - **intent:** Vincent voit l'état de toute la flotte (santé, version, disque, âge du dernier backup) en un écran, sans se connecter à chaque machine.
  - **success:** Un écran unique affiche ces informations pour chaque machine de `fleet.yaml` ; démontré avec les 2 machines réelles.

- **CAP-2 — Administration par machine**
  - **intent:** Vincent sélectionne un Homeport et pilote les actions hpm (update, restart, backup, restore, config, doctor) depuis la console.
  - **success:** Chaque action est déclenchable sur la machine sélectionnée et son résultat s'affiche ; les actions destructives exigent une confirmation.

- **CAP-3 — Dashboard Homeport intégré**
  - **intent:** Vincent ouvre le dashboard web propre de chaque Homeport directement depuis la console, sans changer d'application.
  - **success:** Depuis la fiche machine, le dashboard du Homeport s'affiche intégré et est utilisable.

- **CAP-4 — Logs centralisés**
  - **intent:** Vincent consulte et suit les logs de n'importe quelle machine depuis la console, sans SSH manuel.
  - **success:** Logs d'une machine consultables et suivis en continu, filtrables (machine, texte), sans ouvrir de terminal.

- **CAP-5 — Événements Homeport**
  - **intent:** Les événements côté machine (healthz KO, service redémarré, disque qui se remplit) remontent dans la console sans intervention ; les événements critiques (healthz KO, disque presque plein) déclenchent en plus une notification macOS.
  - **success:** Un healthz KO ou un restart provoqué sur un Pi apparaît dans la console sans action manuelle ; l'événement critique produit aussi une notification macOS, les non-critiques n'en produisent pas.

- **CAP-6 — Journal des tâches**
  - **intent:** Chaque action menée sur la flotte est historisée centralement (horodatage, machine, action, statut, sortie) dans un journal des tâches consultable.
  - **success:** Toute action lancée via le centre est enregistrée et consultable après coup avec son statut et sa sortie.

- **CAP-7 — Sauvegardes planifiées**
  - **intent:** Des jobs de backup programmés s'exécutent avec rétention, avec une vue centrale des jobs et de leurs derniers résultats.
  - **success:** Un job planifié s'exécute sur le Pi à l'heure dite, Mac éteint ; résultat et archive apparaissent consolidés côté Mac ensuite ; la rétention est appliquée.

- **CAP-8 — Métriques historisées**
  - **intent:** Vincent visualise des graphes CPU / RAM / disque / température par machine, avec historique.
  - **success:** Courbes consultables sur une période passée, y compris pour des plages où la console était fermée (données servies par Homeport).

- **CAP-9 — Shell intégré**
  - **intent:** Vincent ouvre un terminal vers n'importe quelle machine depuis la console.
  - **success:** Un shell interactif vers la machine choisie s'ouvre en un geste depuis la console.

- **CAP-10 — Gestion des mises à jour**
  - **intent:** Vincent voit les releases Homeport disponibles vs les versions installées et déclenche l'update depuis la console.
  - **success:** La console montre version installée vs dernière release taguée par machine ; un update complet est démontré depuis la console.

## Constraints

- App macOS native d'abord (SwiftUI, extension de l'existant) ; la console web est une étape ultérieure explicite, hors de cet incrément.
- Un seul livrable : l'app menubar existante ouvre la fenêtre « centre de contrôle » — un seul DMG, une seule identité, pas de seconde app.
- Métriques et événements sont collectés via Homeport lui-même : le repo frère expose une API événements/métriques que le centre consomme — pas d'agent dédié sur les Pi.
- La console doit dégrader proprement face à un Homeport qui n'a pas encore l'API événements/métriques (dépendance de version hpm↔Homeport).
- Backups planifiés côté Pi (systemd timer), indépendants du Mac ; le centre configure, consolide les résultats et rapatrie.
- Socle HomePortKit réutilisé ; SSH depuis le Mac pour les actions.
- Pas de secrets dans `fleet.yaml` ; healthz toujours vérifié via SSH sur la machine elle-même ; seules les versions taguées de Homeport sont déployables.
- Livrable app macOS signé/notarisé (pipeline DMG existant).

## Non-goals

- Console web (reportée à une étape ultérieure explicite).
- Agent dédié sur les Pi.
- HA / failover, migration de services entre machines.
- Multi-utilisateurs / RBAC, firewall, gestion du stockage.
- Virtualisation (VM/LXC) — hpm gère des services Homeport, pas des machines virtuelles.
- Supervision de services tiers : rien d'autre que Homeport.

## Success signal

- Depuis la seule fenêtre du centre de contrôle, Vincent administre sa flotte une journée entière : état global des deux machines, dashboard d'un Homeport ouvert intégré, logs de raspyellow consultés, un événement « healthz KO » remonté tout seul, un update lancé sur raspcorse — sans ouvrir un terminal SSH ni visiter un dashboard à la main. Pendant ce temps, les backups planifiés ont tourné sur les Pi (Mac éteint) et apparaissent consolidés dans la console au réveil.

## Assumptions

- La flotte reste petite (moins de ~10 machines) ; aucune exigence de scalabilité au-delà.
- Rétention des backups planifiés : reconduction des rotations existantes (3 sur machine, 10 sur Mac) sauf décision contraire.
- L'API événements/métriques sera spécifiée et livrée dans le repo Homeport ; ce contrat la consomme seulement.

## Open Questions

- CAP-8 : granularité et durée de rétention de l'historique des métriques — délibérément délégué à l'architecture, qui tranchera entre multi-échelles type RRD et schéma simple selon le coût côté Pi.
