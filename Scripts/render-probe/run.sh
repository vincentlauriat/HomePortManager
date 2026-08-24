#!/bin/bash
# Rend un composant de App/Sources dans une vraie fenêtre, la capture, et sort.
#
# Pourquoi cet outil existe : `swift test` ne compile pas App/Sources, le gate le compile
# sans le regarder, et sept correctifs de l'epic 1 sont sortis du simple fait de lancer
# l'application — sur du code que 225 tests verts et un BUILD SUCCEEDED déclaraient sain
# (élément d'action 6 de la rétrospective). Lancer l'app entière demande un geste humain :
# c'est un LSUIElement dont la fenêtre s'ouvre depuis la barre de menus, et le clic
# programmatique sur un MenuBarExtra n'est pas fiable. Cette sonde monte le composant seul.
#
#   ./Scripts/render-probe/run.sh 1040 /tmp/large.png
#   ./Scripts/render-probe/run.sh 900  /tmp/etroit.png    # la largeur minimale de la spec
#
# main.swift est un exemple — il monte OverflowRow aux deux largeurs qui comptent. Pour
# regarder autre chose, remplacez la vue `Probe` : le reste du fichier est de la plomberie.
set -uo pipefail
cd "$(dirname "$0")/../.."

WIDTH="${1:-1040}"
OUT="${2:-/tmp/render-probe.png}"
BIN="$(mktemp -d)/probe"

# HomePortKit et Yams viennent du build SwiftPM ; CYaml a besoin de sa module map.
swift build >/dev/null 2>&1 || { echo "swift build a échoué"; exit 1; }
D=.build/out/Products/Debug

swiftc -o "$BIN" \
  App/Sources/Theme.swift App/Sources/DesignComponents.swift Scripts/render-probe/main.swift \
  -I "$D" \
  -Xcc -fmodule-map-file=.build/checkouts/Yams/Sources/CYaml/include/module.modulemap \
  -Xcc -I.build/checkouts/Yams/Sources/CYaml/include \
  -L "$D" -lHomePortKit "$D/Yams.o" || exit 1

"$BIN" "$WIDTH" "$OUT"
