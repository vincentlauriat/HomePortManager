#!/bin/bash
# Gate de vérification : compile App/Sources, que `swift test` ne voit jamais.
#
# App/Sources n'est pas dans le graphe SwiftPM (Package.swift ne déclare que
# HomePortKit, hpm et HomePortKitTests). Sans ce script, une erreur de compilation
# du code de l'app traverse le gate de bmad-loop sous 225 tests verts — constaté
# pendant l'epic 1 (`.styled` appelé sur un Label).
#
# La sortie est filtrée à dessein : bmad-loop ne transmet que les 2000 derniers
# caractères à la session de réparation, et `xcodebuild -quiet` termine sur une
# ligne de commande swift-frontend de plusieurs kilooctets qui noierait le
# diagnostic. Ne garder que les lignes utiles rend l'échec actionnable.
set -uo pipefail

# xcodegen vit dans /opt/homebrew/bin, absent du PATH d'un shell non interactif.
# Une commande introuvable escalade le run bmad-loop en env_fault au lieu de le
# faire échouer proprement.
export PATH="/opt/homebrew/bin:$PATH"

cd "$(dirname "$0")/../App" || exit 1
xcodegen generate || exit 1

log=$(mktemp)
trap 'rm -f "$log"' EXIT

xcodebuild -project HomePortMenu.xcodeproj \
           -scheme HomePortMenu \
           -configuration Debug \
           build CODE_SIGNING_ALLOWED=NO -quiet >"$log" 2>&1
rc=$?

if [ "$rc" -ne 0 ]; then
    grep -E "error:|fatal error|BUILD FAILED|The following build commands failed" "$log" \
        | cut -c1-300 | head -40
fi
exit "$rc"
