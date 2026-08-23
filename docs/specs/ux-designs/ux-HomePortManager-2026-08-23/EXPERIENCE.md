---
status: final
created: 2026-08-23
updated: 2026-08-23
sources:
  - ../../spec-proxmox-inspired-fleet/SPEC.md
  - ../../architecture/architecture-HomePortManager-2026-08-23/ARCHITECTURE-SPINE.md
design: DESIGN.md
---

# EXPERIENCE — Centre de contrôle HomePortManager

## Foundation

- **Form-factor** : app desktop macOS 13+ (SwiftUI natif), une fenêtre « Centre de contrôle » ouverte depuis l'app menubar existante — même process, même `FleetModel` (AD-15). Fenêtre min 900×600. `[ASSUMPTION]` taille min.
- **UI system** : SwiftUI natif ; l'identité visuelle est {DESIGN.md} — ses tokens priment sur les défauts système là où ils sont définis, les comportements natifs macOS (menus, raccourcis, sheets) restent natifs.
- La menubar existante n'est pas redessinée dans ce chantier ; elle gagne l'entrée « Ouvrir le centre de contrôle » (⌘O depuis le menu). `[ASSUMPTION]` raccourci.

## Information Architecture

```
Fenêtre
├── Sidebar (220px)
│   ├── Flotte (vue d'accueil — tableau de bord global, CAP-1)
│   └── Machines (une entrée par machine : pastille block + nom + pill d'état)
└── Détail machine — onglets pills (AD-15)
    Résumé · Dashboard · Logs · Événements · Métriques · Backups · Shell · Updates
```

- **Flotte** (accueil) : table `{components.data-table}` — une ligne par machine : pastille, nom, état (pill), version, disque, âge du dernier backup, dernier événement. Clic → fiche machine.
- **Résumé** : bandeau `{components.machine-banner}` + cartes (santé, version vs dernière release, disque, uptime, latence SSH) + actions (Backup, Restart, Update…, Doctor) en pills.
- **Dashboard** (CAP-3) : WebView vers le dashboard Homeport de la machine ; empty-state « injoignable » avec action Réessayer plutôt qu'une page d'erreur WebKit.
- **Logs** (CAP-4) : `{components.log-viewer}`, suivi continu commutable, filtre texte, sélection/copie.
- **Événements** (CAP-5) : liste antichronologique, sévérité en pill, filtre par sévérité.
- **Métriques** (CAP-8) : 4 `{components.metric-card}` (CPU, RAM, disque, température) + sélecteur de plage (24 h / 7 j / 30 j / 1 an).
- **Backups** (CAP-7) : définition des jobs (planning, rétention), derniers résultats, archives des deux côtés, bouton Sync.
- **Shell** (CAP-9) : `{components.terminal-panel}` — session à la demande, jamais ouverte automatiquement.
- **Updates** (CAP-10) : version installée vs releases taguées (notes), bouton Update.

Chaque besoin du SPEC a sa surface ; chaque surface est atteinte par la sidebar en ≤ 2 clics.

## Voice and Tone

- **Trilingue** : français, anglais, chinois simplifié — String Catalogs SwiftUI ; langue = système macOS parmi les trois, anglais par défaut sinon. `[ASSUMPTION]` défaut anglais.
- Ton sobre et factuel, voix active : un bouton dit ce qu'il fait (« Sauvegarder maintenant »), un toast confirme au passé (« Sauvegarde terminée — 626 Ko »).
- Les erreurs disent le fait puis le remède : « raspyellow est injoignable. Vérifier Tailscale ou réessayer. » Jamais d'excuses ni de jargon interne.
- Ce qui ne se traduit pas : noms de machines, chemins, versions, sorties de commandes — toujours en mono, tels quels.
- Horodatages affichés en heure locale au format de la locale ; les données API restent ISO 8601 en interne.

## Component Patterns

- **Actions machine** : pendant une mutation (verrou AD-12), tous les boutons d'action de la machine se désactivent et un indicateur discret « Update en cours… » s'affiche dans le bandeau ; les lectures (logs, métriques) restent actives. Le déclenchement est optimiste dans l'UI mais la vérité vient du journal.
- **Tables** : tri par colonne, aucune pagination (< 10 machines) ; lignes de journal et d'événements en chargement incrémental.
- **Logs** : le suivi continu s'arrête automatiquement quand l'utilisateur remonte ; bouton « Reprendre le suivi » apparaît.
- **Terminal** : un onglet Shell ouvert par machine au plus ; fermeture de fenêtre = fin de session (informatif au journal, AD-17).

## State Patterns

- **Trois états API par machine** (NFR2), affichés dans le bandeau et sur les onglets concernés :
  - *Disponible* — rien à dire, les données parlent.
  - *Non disponible* (Homeport sans API) : Événements et Métriques affichent un `{components.empty-state}` : « Cette version de Homeport ne fournit pas encore les événements. Mettre à jour vers vX.Y+ » — pill Update. Jamais une erreur.
  - *Injoignable* : pill critical dans la sidebar et le bandeau ; les onglets gardent leurs dernières données connues avec la mention « Vu pour la dernière fois à HH:MM ».
- **États vides premiers** : chaque onglet a son empty-state écrit (aucun événement, aucun job défini, première ouverture du shell), **et le produit entier aussi** — `fleet.yaml` absent ou vide affiche un accueil expliquant ce qu'est le centre de contrôle et comment déclarer une première machine.
- **Chargement** : squelettes discrets sur les cartes ; jamais de spinner plein écran.
- **Notifications macOS** : événements critical uniquement (AD-5) ; clic → fiche machine, onglet Événements.

## Interaction Primitives

- **Confirmations destructives** (restore, remove, update) : sheet modale — titre au verbe (« Restaurer raspcorse ? »), conséquence en une phrase, bouton destructif à fond `{colors.semantic-critical}` uniquement ici. Le nom de la machine est toujours répété dans la sheet.
- **Clavier** : ⌘1..⌘8 onglets ; ⌘F filtre (logs, événements) ; ↑↓ navigation sidebar ; ⌘R refresh manuel. `[ASSUMPTION]` mappings.
- **Une mutation à la fois par machine** — l'UI reflète le verrou, elle ne le contourne jamais.
- Menus contextuels sidebar : les mêmes actions que la fiche, mêmes confirmations.

## Accessibility Floor

- Cible : usage personnel — plancher raisonnable, pas de certification. Contraste AA pour le texte sur canvas et sur blocks pastel (garanti par les tokens {DESIGN.md}) ; la couleur n'est jamais seule porteuse d'un état (pill = couleur + libellé).
- Navigation clavier complète ; focus visible ; labels VoiceOver sur les actions et les pills d'état.
- `prefers-reduced-motion` respecté (aucune animation porteuse de sens de toute façon).

## Internationalization

- String Catalogs (`.xcstrings`) dès la story 1 ; aucune chaîne en dur dans les vues.
- Le chinois rend via le fallback PingFang SC ({DESIGN.md} Typography) ; vérifier les hauteurs de ligne des pills et tables en zh-Hans (glyphes plus hauts).
- Formats de dates, tailles et durées localisés via `FormatStyle` ; unités de disque en Go/GB selon la locale.
- Les notifications macOS sont localisées ; le contenu produit par les machines (logs, sorties) ne l'est pas.

## Key Flows

### Un mardi matin (climax : panne rattrapée sans terminal)

1. 7 h 40 — Vincent ouvre son Mac ; notification macOS : « raspyellow : healthz KO (23 h 12) ».
2. Clic sur la notification → la fenêtre s'ouvre sur raspyellow, onglet Événements : la nuit est là, rattrapée par le pull (epoch, id) — healthz KO à 23 h 12, service redémarré à 23 h 14, re-KO à 23 h 51.
3. Onglet Logs : le suivi continu montre l'erreur qui boucle. Filtre « mqtt » : le broker ne répond plus.
4. **Climax** — Onglet Résumé : bouton « Restart », sheet de confirmation (« Redémarrer raspyellow ? Le service sera interrompu quelques secondes »), confirmation. Le bandeau passe en « Restart en cours… », les boutons se verrouillent, puis la pill revient à OK vert. Toast : « Redémarré — healthz OK ».
5. Retour à la vue Flotte : deux lignes vertes. Le journal des tâches garde la trace ; le backup planifié de la nuit apparaît consolidé, 631 Ko. Vincent n'a pas ouvert un seul terminal.

### Premier contact avec une machine sans API

1. Vincent met à jour hpm mais pas encore Homeport sur raspcorse ; il ouvre Métriques.
2. Empty-state posé : « Cette version de Homeport ne fournit pas encore les métriques. Mettre à jour vers v0.6+ » — pill « Voir Updates ».
3. Il passe par Updates, lance l'update (confirmation), suit la tâche, revient : les graphes se remplissent. La dégradation a guidé au lieu de bloquer.
