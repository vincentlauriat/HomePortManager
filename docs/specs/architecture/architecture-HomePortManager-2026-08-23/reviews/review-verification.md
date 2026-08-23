# Revue de vérification — lentille « réalité / web »

- **Document revu :** `ARCHITECTURE-SPINE.md` (architecture-HomePortManager-2026-08-23)
- **Relecteur :** agent indépendant, vérification contre le web (recherches + fetch des repos upstream) et contre le code réel du repo (`Package.swift`, `Sources/`, `App/Sources/`, `App/project.yml`)
- **Date :** 2026-08-23
- **Verdict global :** le spine est globalement solide et cohérent avec le code existant ; aucune décision n'est fondée sur une bibliothèque morte ou un mécanisme irréaliste. Deux points n'ont toutefois **pas** été tranchés contre la réalité et doivent l'être avant les story-specs : l'App Transport Security face au HTTP clair sur tailnet (AD-3), et l'épinglage de version SwiftTerm en pleine transition 1.x → 2.0.

---

## Méthode

Chaque affirmation « vérifiable » du spine a été confrontée à une source externe (page releases GitHub, `Package.swift` upstream, doc Apple, doc SQLite) ou au code du repo. Les vérifications faites :

| Affirmation du spine | Source consultée | Résultat |
| --- | --- | --- |
| swift-argument-parser ≥ 1.3, maintenu | github.com/apple/swift-argument-parser (releases) | ✅ actif — v1.8.0 sortie ~22 août 2026 ; ⚠️ 1.8.0 exige Swift 6 (1.7.1 = dernière pour les toolchains < 6) |
| Yams ≥ 5.0, maintenu | github.com/jpsim/Yams (releases) | ✅ actif — v6.2.2 (mai 2026) ; majeure 6.x hors plage `from: "5.0.0"` |
| SwiftTerm « dernière release SPM — vérifié actif 2026-08 » | github.com/migueldeicaza/SwiftTerm (repo + releases + Package.swift main) | ✅ actif, mais **en transition 1.x → 2.0** : v1.19.0 (stable, août 2024), v1.20.0 pré-release « one last before 2.0 », branche main = API 2.0, `swift-tools-version: 6.2`, plateformes macOS 11+ |
| SwiftTerm intégrable en SwiftUI macOS via NSViewRepresentable | README/doc SwiftTerm | ✅ `TerminalView` est un `NSView` AppKit (+ `LocalProcessTerminalView` pty) — wrappable en `NSViewRepresentable` |
| Swift Charts natif macOS 13+ | developer.apple.com/documentation/charts + résultats croisés | ✅ confirmé — introduit avec macOS 13, cible minimale macOS 13.0 (SDK Xcode ≥ 14.1) |
| SQLite API C système, WAL, accès concurrents CLI + app | sqlite.org (forum/doc WAL) | ✅ multi-process sur fichier local OK ; ⚠️ un seul writer à la fois, `busy_timeout` indispensable ; WAL non fiable sur FS réseau (non concerné ici : `~/.local/state`) |
| Units systemd déployées via SSH | code du repo | ✅ pattern déjà en production dans v1 (voir F-8) |
| Pull HTTP à curseur | pratique standard | ✅ réaliste (voir F-9) |
| Non-contradiction avec l'existant | `Package.swift`, `Sources/`, `App/` | ✅ conforme (voir F-10) |

---

## Findings

### HIGH

#### F-1 [HIGH] — ATS non tranché : le HTTP clair sur tailnet (AD-3, CAP-3, CAP-5, CAP-8) sera bloqué par défaut dans l'app

AD-3 engage « API Homeport en HTTP direct via Tailscale » et CAP-3 une WebView vers le dashboard. Or **App Transport Security bloque par défaut tout chargement HTTP en clair** dans une app macOS — pour `URLSession` (le futur `HomeportAPIClient` dans le process de l'app) comme pour la WebView. Les noms tailnet (MagicDNS `*.ts.net` ou IP 100.x) ne bénéficient d'aucune exception automatique : `NSAllowsLocalNetworking` ne couvre que les domaines non qualifiés / `.local`, et les IP exigent carrément `NSAllowsArbitraryLoads`. Vérifié contre la doc Apple (`NSAppTransportSecurity`, `NSAllowsArbitraryLoadsInWebContent`).

Le spine ne mentionne le sujet nulle part. Trois issues possibles, aucune choisie :

1. exceptions ATS ciblées dans `Info.plist` de l'app (`NSExceptionDomains` par machine — fragile car la flotte est dynamique) ;
2. `NSAllowsArbitraryLoadsInWebContent` + exception large pour URLSession (affaiblit la posture, à justifier lors de la notarisation) ;
3. HTTPS réel via `tailscale cert` (certificats Let's Encrypt pour les noms `ts.net`) — la plus propre, mais impose une étape de provisionnement côté Pi et l'usage des noms MagicDNS complets.

Noter que le healthz actuel ne déclenche pas le problème (il passe par SSH + `curl localhost` sur le Pi) : c'est bien le **nouveau** transport HTTP d'AD-3 qui l'introduit. La CLI `hpm` (binaire sans bundle) est moins exposée qu'une app bundlée, mais l'app menubar/fenêtre l'est pleinement.

**Recommandation :** ajouter la décision au spine (probablement dans AD-3 ou AD-14) avant les stories 5-8 ; l'option `tailscale cert` s'aligne le mieux avec AD-14 (« le tailnet est l'authentification »).

#### F-2 [HIGH] — SwiftTerm : « dernière release SPM » est une non-décision au pire moment (transition 1.x → 2.0)

L'entrée Stack dit « dernière release SPM — vérifié actif 2026-08 ». La partie « actif » est confirmée (projet vivant, 1,7 k étoiles, commits récents). Mais la partie « dernière release » n'épingle rien alors que la bibliothèque est **en plein changement d'API majeur** :

- dernière stable taguée : **v1.19.0** (août 2024) ;
- **v1.20.0** publiée en pré-release, annoncée « one last before 2.0 » ;
- branche `main` : API **SwiftTerm 2.0** (guide de migration 1.x → 2.0 dans le README), `swift-tools-version: 6.2`, plateformes macOS 11+.

Conséquences concrètes : `from: "1.x"` et « main / 2.0 » donnent deux APIs différentes, et SwiftTerm 2.0 exige une toolchain Swift 6.2 alors que le manifeste du projet est `swift-tools-version:5.9` (voir F-4 — compatible seulement si la machine de build a une toolchain récente). Une story CAP-9 écrite sans épinglage peut être invalidée par une release 2.0 entre-temps.

**Recommandation :** épingler explicitement dans le spine : `SwiftTerm from: "1.19.0"` (upToNextMajor, API stable documentée) **ou** décision assumée d'attendre/adopter 2.0 — mais pas « dernière release ».

### MEDIUM

#### F-3 [MEDIUM] — AD-7 (SQLite WAL, CLI + app concurrents) : réaliste mais incomplet sans `busy_timeout`

Vérifié contre la doc/forum sqlite.org : le mode WAL autorise bien plusieurs process (readers en parallèle d'un writer), donc le scénario CLI + app sur `hpm.db` est **fondé**. Deux réserves confirmées par les sources :

- **un seul writer à la fois** — un `hpm backup sync` CLI et un refresh app qui journalisent en même temps donneront `SQLITE_BUSY` si `HistoryStore` ne configure pas `PRAGMA busy_timeout` (ou une boucle de retry). Le spine impose l'owner unique par *code* (`HistoryStore`) mais deux **process** restent deux connexions ;
- WAL repose sur la shm mappée : fiable uniquement sur FS local — OK ici (`~/.local/state/hpm/`), mais à ne jamais déplacer sur un volume réseau/synchronisé (iCloud Drive, etc.).

**Recommandation :** une ligne dans AD-7 : « connexions ouvertes avec `busy_timeout` ≥ N ms ; hpm.db toujours sur FS local ». Le reste peut descendre au story-spec 6.

#### F-4 [MEDIUM] — swift-argument-parser : la plage `≥ 1.3` résoudra vers 1.8.0 qui exige Swift 6

Vérifié sur les releases GitHub : **v1.8.0 est sortie ~le 22 août 2026** et relève le minimum à Swift 6 (v1.7.1 reste la dernière pour les toolchains antérieures). Avec `from: "1.3.0"` dans `Package.swift`, SPM résoudra la plus récente compatible avec la toolchain installée. Ce n'est pas un blocage (une toolchain 2026 compile un manifeste tools 5.9 sans souci), mais le spine affiche « tools 5.9 » et « ≥ 1.3 » sans acter que la résolution réelle dépendra de la toolchain de build — source possible de builds non reproductibles entre machines/CI.

**Recommandation :** soit épingler (`.upToNextMinor(from: "1.7.1")` tant que la contrainte tools 5.9 est voulue), soit assumer la montée de toolchain et le noter dans Stack.

#### F-5 [MEDIUM] — CAP-9 : SwiftTerm n'implémente pas SSH — le mécanisme réel doit être nommé

SwiftTerm est un émulateur de terminal (VT100/xterm) ; il ne parle pas le protocole SSH. Le chemin réaliste — cohérent avec la philosophie « agentless » de `SSHClient` (ssh/scp système, BatchMode, config utilisateur et Tailscale inchangés) — est `LocalProcessTerminalView` lançant `/usr/bin/ssh <host>` dans un pty local. C'est très probablement l'intention (« équiv. `ssh` documenté » dans la map CAP-9), mais le spine ne le dit pas, et l'alternative (lib SSH native type swift-nio-ssh) contredirait AD-2/l'existant.

**Recommandation :** expliciter dans la map ou le seed : « TerminalTab = LocalProcessTerminalView exécutant `/usr/bin/ssh` — aucun stack SSH natif ».

### LOW

#### F-6 [LOW] — Yams : à jour côté spine, mais la majeure courante est 6.x

Vérifié : Yams est maintenu (v6.2.2, mai 2026). Le spine dit « ≥ 5.0 », fidèle au `Package.swift` actuel (`from: "5.0.0"`), qui ne captera jamais la 6.x (breaking change mineur en 6.0.0 : types Sendable dans `YamlError.duplicatedKeysInMapping`). Aucun blocage — simple opportunité de mise à niveau à noter au backlog.

#### F-7 [LOW] — Swift Charts macOS 13+ : confirmé, rien à signaler

Vérifié contre la doc Apple : Swift Charts est bien natif à partir de macOS 13.0, et `App/project.yml` cible `macOS: "13.0"`. La décision est correcte telle quelle.

#### F-8 [LOW] — Units systemd via SSH (AD-9) : mécanisme confirmé par le code v1, une hypothèse implicite à garder en tête

Le pattern est déjà en production dans le repo : `Manager+Remove.swift` et `Manager+Restore.swift` manipulent `/etc/systemd/system/homeport.service` + `systemctl` via `SSHClient.run(sudo: true)` (`sudo bash -s` sur stdin — quoting sûr pour scripts multi-lignes). Déployer `homeport-backup.service`/`.timer` est la même mécanique : **réaliste et cohérent**. Hypothèse implicite héritée de v1 : `BatchMode=yes` + `sudo` non interactif supposent clé SSH et sudoers NOPASSWD côté Pi — déjà vrai pour la flotte actuelle, mais c'est un prérequis que `doctor` devrait continuer de vérifier pour les nouvelles units.

#### F-9 [LOW] — Pull HTTP à curseur (AD-5) : réaliste, dépendance inter-repo correctement gérée

Le pattern (id monotone par machine, `?since=<curseur>`, curseur persisté côté client, intervalle 30-60 s) est un standard éprouvé, sans piège caché à cette échelle (une poignée de Pis). Le vrai risque — que le serveur n'existe pas encore côté Homeport — est explicitement couvert par AD-4 (contrat versionné, capabilities, « API absente = non disponible, jamais une erreur ») et AD-8 (agrégation côté Pi). Rien d'irréaliste ; la charge de travail côté repo Homeport est le point à planifier, pas un défaut du spine.

#### F-10 [LOW] — Cohérence spine ↔ code existant : aucune contradiction relevée

Vérifié contre le repo :

- `Package.swift` : tools 5.9, macOS 13, produits `HomePortKit` + `hpm`, dépendances argument-parser/Yams — conforme au Stack (aux nuances F-4/F-6 près) ;
- les owners d'effets d'AD-2 existent tous déjà (`SSHClient`, `ProcessRunner`, `FleetStore`, `ReleaseService`, `HPMError`) et les nouveaux (`HomeportAPIClient`, `HistoryStore`, `MachineQueue`) sont bien marqués nouveaux ;
- la convention `Manager+<Domaine>` est celle du code (9 extensions existantes) ; le seed s'y insère sans renommage ;
- `App/Sources/` contient bien `FleetModel.swift` (AD-15), `Notifier.swift` (CAP-5), menubar — la fenêtre « Centre de contrôle » est une addition, pas une refonte ;
- le healthz « via SSH `curl localhost` » décrit par AD-3 correspond au comportement actuel (`healthzOK` dans `Manager+Status.swift`).

Un seul écart mineur de nommage : le seed place `Notifier` implicitement (map CAP-5 « HomeportAPIClient + Notifier ») alors qu'il vit aujourd'hui côté App, pas dans le Kit — à clarifier au story-spec 5 (les notifications macOS `UserNotifications` peuvent s'émettre depuis l'app uniquement ; la CLI n'en a pas besoin).

---

## Synthèse des points « affirmés mais non vérifiés » dans le spine

| Point | Statut après vérification |
| --- | --- |
| « SwiftTerm … vérifié actif 2026-08 » | Actif : confirmé. Mais version non épinglée en pleine transition 2.0 (F-2) |
| HTTP clair sur tailnet consommable par l'app | **Non vérifié dans le spine, et faux par défaut** à cause d'ATS (F-1) |
| WAL suffisant pour CLI+app concurrents | Vrai sur le principe, incomplet sans busy_timeout (F-3) |
| Versions argument-parser / Yams | Exactes mais figées à l'état v1 ; upstream a bougé (F-4, F-6) |
| Swift Charts macOS 13, systemd via SSH, pull à curseur | Confirmés sans réserve (F-7, F-8, F-9) |

Sources principales : github.com/apple/swift-argument-parser (releases), github.com/jpsim/Yams (releases), github.com/migueldeicaza/SwiftTerm (repo, releases, Package.swift@main), developer.apple.com/documentation/charts, developer.apple.com — NSAppTransportSecurity / NSAllowsArbitraryLoadsInWebContent, sqlite.org (doc & forum WAL), code du repo HomePortManager (commit courant, branche main).
