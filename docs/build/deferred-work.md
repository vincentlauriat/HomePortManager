- source_spec: `docs/build/spec-1-1-fenêtre-centre-de-contrôle-et-tableau-de-bord-global.md`
  summary: App/Sources n'est pas dans le graphe SwiftPM, donc swift test ne compile jamais le code de l'app.
  evidence: Package.swift ne déclare que HomePortKit, hpm et HomePortKitTests. MachineBlockStore (persistance UserDefaults), FleetModel (écriture des caches lastReachableStatus/lastSeenAt) et Color(hex:) n'ont aucun test possible ; seul xcodebuild les compile. Les 107 tests verts ne disent rien de ce code.

- source_spec: `docs/build/spec-1-1-fenêtre-centre-de-contrôle-et-tableau-de-bord-global.md`
  summary: reloadFleet() avale les erreurs de parsing YAML, rendant un fleet.yaml malformé indistinguable d'un fichier vide.
  evidence: `machines = (try? FleetStore().load().machines) ?? []` dans App/Sources/FleetModel.swift. L'état vide invite alors à déclarer une première machine à un utilisateur dont le fichier en contient déjà mais ne parse pas, et le bouton de rechargement ne rend ni succès ni échec.

- source_spec: `docs/build/spec-1-1-fenêtre-centre-de-contrôle-et-tableau-de-bord-global.md`
  summary: Aucune typographie dynamique — l'interface ne peut pas honorer un réglage de taille de texte agrandi.
  evidence: Theme.sans/mono construisent leurs Font en .custom(_, fixedSize:) ou .system(size:), et Metrics.tableRowHeight = 26, les largeurs de colonnes 55-100 px, frame(width: 170) des libellés de résumé et les lineLimit(1) généralisés figent la mise en page.
