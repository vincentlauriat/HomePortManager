# Brownfield — existant sur lequel ce spec s'appuie

Faits vérifiés (v1.0.0, 2026-08-23) qui plient les décisions downstream.

## Composants livrés

- `HomePortKit` (lib Swift, produit déclaré dans Package.swift) + CLI `hpm` (swift-argument-parser) + app menubar SwiftUI (`App/`, xcodegen, MenuBarExtra style window, LSUIElement, sans sandbox). 80 tests verts.
- App menubar : FleetModel `@MainActor`, refresh 5 min en TaskGroup parallèle, notifications sur transitions d'état uniquement, fenêtre de logs par machine, actions sûres avec confirmation NSAlert.
- Pipeline release : `Scripts/release.sh` — DMG signé, notarisé (profil `AppliMacVincentGithub`), staplé.

## Modèle opérationnel

- SSH pur sans agent depuis le Mac ; le Mac télécharge les releases GitHub (cache `~/.cache/hpm/`) et pousse en scp — les Pi n'ont pas besoin d'accès GitHub.
- Inventaire : `~/.config/hpm/fleet.yaml`, sans secrets.
- healthz vérifié via SSH (`curl localhost`), jamais depuis le Mac.
- Data dir effectif résolu via `systemctl show homeport -p Environment` (drop-ins ; le dernier override gagne).
- `install.sh` (`systemctl enable --now`) ne redémarre pas un service déjà actif → hpm enchaîne `systemctl restart homeport` après install.
- Backups actuels (à la demande) : `/var/backups/homeport/` sur la machine (rotation 3) + `~/HomePortBackups/<machine>/` sur le Mac (rotation 10) ; `history.db` sauvegardée via `sqlite3 .backup` ; `/etc/homeport/mqtt.env` root-only → staging sudo dans `/tmp/hpm-cfg-pull`.

## Flotte réelle

- `raspcorse` — Pi 5 (Corse), Homeport v0.5.0, sudo NOPASSWD.
- `raspyellow` — HA Yellow CM4 (Orsay), subnet router Tailscale ; SSH obligatoirement `vincent@raspyellow` (policy Tailscale SSH).

## Repo frère

- `../Homeport` : le dashboard home-server géré par hpm ; cible de la future API événements/métriques que ce spec consomme (CAP-5, CAP-8).
