# HomePortManager — Client de maintenance HomePortExploit — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Déclencher les actions de maintenance d'un Pi depuis hpm — CLI et console — en consommant l'API HTTP de HomePortExploit sur le tailnet.

**Architecture:** Un second client HTTP dans HomePortKit, calqué sur `HomeportAPIClient` mais avec une couture d'injection qui porte la **requête** et non l'URL (le client fait des `POST`). Toute opération passe par `journaled(_:on:locking:)` — dans une nouvelle surcharge `async` — pour que `hpm.db` et le verrou AD-12 couvrent aussi les actions déléguées.

**Tech Stack:** Swift 6, SwiftPM (HomePortKit + hpm), SwiftUI (App), XCTest, Yams, swift-argument-parser.

**Spec:** `../HomePortExploit/docs/superpowers/specs/2026-09-02-hpm-exploit-integration-design.md`
**Contrat:** `docs/api/homeportexploit-api-v1.md` (copie épinglée, posée par le plan jumeau)

**Prérequis bloquant :** le plan jumeau (`../HomePortExploit/docs/superpowers/plans/2026-09-02-exploit-api-for-hpm.md`) doit être **terminé et déployé sur raspcorse**. Sans `GET /capabilities` en production, la tâche 7 ne peut pas s'exécuter. Les tâches 1 à 6 sont écrites contre des fixtures et n'ont besoin d'aucun réseau.

## Global Constraints

- **Aucun échec du contrat n'est une erreur** (AD-3, §8 du contrat Homeport) : un serveur absent, trop ancien ou muet est une **valeur** que l'interface rend, jamais une exception que l'appelant attrape.
- **Le client n'étend jamais le contrat** (AD-4) : un champ inconnu est transporté, jamais interprété ; aucun champ n'est inventé côté client.
- **Aucune chaîne en dur dans l'app** (UX-DR4) : tout passe par `App/Sources/Localizable.xcstrings`, fr / en / zh-Hans.
- **Aucune requête réseau dans un test.** L'injection se fait par la couture `fetch`, comme `HomeportAPIClientTests` le fait déjà.
- **Aucun état porté par la couleur seule** (UX-DR7) ; toute action et toute pastille porte un label VoiceOver.
- Vérification : `swift test` (404 tests au départ) et `Scripts/verify-app-build.sh` rc 0.
- Pas de `Co-Authored-By: Claude` dans les messages de commit (règle du dépôt).

---

## Structure des fichiers

| Fichier | Responsabilité | Tâche |
|---|---|---|
| `Sources/HomePortKit/FleetStore.swift` | `exploitPort` sur `Machine` | 1 (modifié) |
| `Sources/HomePortKit/Dashboard.swift` | `apiHost(for:)` extrait de `dashboardURL(for:)` | 1 (modifié) |
| `Sources/HomePortKit/ExploitAPIContract.swift` | Plage de versions, capacités, les cinq états | 2 (créé) |
| `Sources/HomePortKit/ExploitAPIClient.swift` | Handshake, dry-run, execute, audit, services Docker | 3 (créé) |
| `Sources/HomePortKit/Manager+Maintenance.swift` | Journalisation + verrou autour des appels client | 4 (créé) |
| `Sources/HomePortKit/Manager+Journal.swift` | Surcharge `async` de `journaled` | 4 (modifié) |
| `Sources/hpm/Commands.swift` | `MaintenanceCmd` et ses quatre sous-commandes | 5 (modifié) |
| `Sources/hpm/HPM.swift` | Enregistrement de `MaintenanceCmd` | 5 (modifié) |
| `App/Sources/MachineDetailView.swift` | Neuvième onglet (⌘9) | 6 (modifié) |
| `App/Sources/MaintenanceTabView.swift` | L'onglet | 6 (créé) |
| `App/Sources/Localizable.xcstrings` | fr / en / zh-Hans | 6 (modifié) |

---

### Task 1: `exploitPort` et dérivation d'hôte partagée

**Files:**
- Modify: `Sources/HomePortKit/FleetStore.swift:4-15` (`Machine`)
- Modify: `Sources/HomePortKit/Dashboard.swift:16-35` (`dashboardURL`)
- Test: `Tests/HomePortKitTests/FleetStoreTests.swift`, `Tests/HomePortKitTests/DashboardURLTests.swift`

**Interfaces:**
- Produces: `Machine.exploitPort: Int?` ; `public func apiHost(for machine: Machine) -> String?` — l'hôte nu, `user@` retiré et allowlist appliquée, ou `nil`. Les tâches 2 et 3 en dépendent.

- [ ] **Step 1: Écrire les tests qui échouent**

Dans `FleetStoreTests.swift` :

```swift
func testMachineWithoutExploitPortRoundTripsWithoutNullKey() throws {
    let path = NSTemporaryDirectory() + "fleet-\(UUID().uuidString).yaml"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = FleetStore(path: path)
    try store.save(Fleet(machines: [Machine(name: "raspyellow", ssh: "vincent@raspyellow", port: 80)]))

    let written = try String(contentsOfFile: path, encoding: .utf8)
    // Un optionnel absent ne doit pas gagner de clé : le fichier de Vincent est écrit à la main.
    XCTAssertFalse(written.contains("exploitPort"))
    XCTAssertNil(try store.load().machines[0].exploitPort)
}

func testExploitPortSurvivesRoundTrip() throws {
    let path = NSTemporaryDirectory() + "fleet-\(UUID().uuidString).yaml"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = FleetStore(path: path)
    try store.save(Fleet(machines: [Machine(name: "raspcorse", ssh: "raspcorse", port: 80, exploitPort: 8081)]))
    XCTAssertEqual(try store.load().machines[0].exploitPort, 8081)
}
```

Dans `DashboardURLTests.swift` :

```swift
func testAPIHostStripsUserPrefix() {
    XCTAssertEqual(apiHost(for: Machine(name: "y", ssh: "vincent@raspyellow", port: 80)), "raspyellow")
}

func testAPIHostRejectsShellMetacharacters() {
    XCTAssertNil(apiHost(for: Machine(name: "x", ssh: "host;rm -rf /", port: 80)))
}
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter "FleetStoreTests|DashboardURLTests"`
Expected: FAIL — `exploitPort` et `apiHost` n'existent pas (erreurs de compilation).

- [ ] **Step 3: Écrire l'implémentation minimale**

Dans `FleetStore.swift`, `Machine` devient :

```swift
public struct Machine: Codable, Equatable {
    public var name: String
    public var ssh: String
    public var port: Int
    public var notes: String?
    /// Le port de HomePortExploit sur cette machine. `nil` — la clé absente du YAML —
    /// signifie que le service n'y est pas déployé : un état neutre, jamais une panne.
    public var exploitPort: Int?

    public init(name: String, ssh: String, port: Int = 80, notes: String? = nil, exploitPort: Int? = nil) {
        self.name = name
        self.ssh = ssh
        self.port = port
        self.notes = notes
        self.exploitPort = exploitPort
    }
}
```

Dans `Dashboard.swift`, extraire la dérivation et faire reposer `dashboardURL` dessus :

```swift
/// L'hôte joignable d'une machine, dérivé de sa cible SSH : le préfixe `user@` retiré
/// (`vincent@raspyellow` → `raspyellow`), puis validé contre une allowlist de caractères.
/// Partagé par les deux clients HTTP du dépôt : une seule dérivation, une seule allowlist.
public func apiHost(for machine: Machine) -> String? {
    let target = machine.ssh
    let host: String
    if let at = target.lastIndex(of: "@") {
        host = String(target[target.index(after: at)...])
    } else {
        host = target
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz"
                               + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
    guard !host.isEmpty, host.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
    return host
}

public func dashboardURL(for machine: Machine) -> URL? {
    guard (1...65535).contains(machine.port), let host = apiHost(for: machine) else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = machine.port
    components.path = "/"
    return components.url
}
```

- [ ] **Step 4: Lancer la suite entière**

Run: `swift test`
Expected: PASS — 404 tests + 4. Les tests existants de `dashboardURL` doivent passer **sans modification** : c'est ce qui prouve que l'extraction n'a rien changé au comportement.

- [ ] **Step 5: Commit**

```bash
git add Sources/HomePortKit/FleetStore.swift Sources/HomePortKit/Dashboard.swift \
        Tests/HomePortKitTests/FleetStoreTests.swift Tests/HomePortKitTests/DashboardURLTests.swift
git commit -m "feat: add optional exploitPort to Machine and share host derivation"
```

---

### Task 2: Le contrat exécutable — versions et cinq états

**Files:**
- Create: `Sources/HomePortKit/ExploitAPIContract.swift`
- Test: `Tests/HomePortKitTests/ExploitAPIContractTests.swift`

**Interfaces:**
- Consumes: `SemanticVersion` (déjà public dans `HomeportAPIContract.swift`), `Machine.exploitPort` (tâche 1).
- Produces: `ExploitCapabilities`, `ExploitAvailability`, `ExploitContract.consumedRange`. La tâche 3 les renvoie, les tâches 5 et 6 les affichent.

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
import XCTest
@testable import HomePortKit

final class ExploitAPIContractTests: XCTestCase {
    func testConsumedRangeAcceptsOnePointZero() {
        XCTAssertTrue(ExploitContract.consumes(SemanticVersion(1, 0, 0)))
    }

    func testAMinorAheadIsStillConsumed() {
        // Un mineur ajoute des champs ; le client les ignore (AD-4). Il ne casse rien.
        XCTAssertTrue(ExploitContract.consumes(SemanticVersion(1, 9, 0)))
    }

    func testANewMajorIsOutOfRange() {
        XCTAssertFalse(ExploitContract.consumes(SemanticVersion(2, 0, 0)))
    }

    func testCapabilitiesReportWhichActionsAreServed() {
        let caps = ExploitCapabilities(contract: SemanticVersion(1, 0, 0), server: "0.2.0",
                                       actions: ["apt-update", "reboot"])
        XCTAssertTrue(caps.serves("reboot"))
        XCTAssertFalse(caps.serves("docker-update"))
    }
}
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter ExploitAPIContractTests`
Expected: FAIL — les types n'existent pas.

- [ ] **Step 3: Écrire l'implémentation minimale**

```swift
import Foundation

/// La moitié exécutable de `docs/api/homeportexploit-api-v1.md`. Le document et ce fichier
/// doivent énoncer la même plage : si l'un bouge sans l'autre, c'est le document qui fait foi.
public enum ExploitContract {
    /// Inclusif en bas, exclusif en haut. Un mineur en avance ajoute des champs qu'un client
    /// conforme ignore ; un majeur change la forme, et n'est pas consommé.
    public static let minimum = SemanticVersion(1, 0, 0)
    public static let belowMaximum = SemanticVersion(2, 0, 0)

    public static func consumes(_ version: SemanticVersion) -> Bool {
        version >= minimum && version < belowMaximum
    }
}

/// Le handshake de `GET /capabilities`, déjà validé : une valeur de ce type signifie que
/// l'échange a eu lieu *et* que le contrat annoncé est dans la plage consommée.
public struct ExploitCapabilities: Equatable, Sendable {
    public let contract: SemanticVersion
    /// La version de HomePortExploit. Informative : elle ne décide de rien.
    public let server: String
    /// Ce que *cette machine* sert. Source de vérité sur la disponibilité — on la lit,
    /// on ne sonde pas les routes une par une.
    public let actions: [String]

    public init(contract: SemanticVersion, server: String, actions: [String]) {
        self.contract = contract
        self.server = server
        self.actions = actions
    }

    public func serves(_ action: String) -> Bool { actions.contains(action) }
}

public enum ExploitUnavailableReason: Equatable, Sendable {
    /// 404 : le service tourne, mais il est antérieur à la route `/capabilities`.
    case notServed
    /// Le contrat annoncé sort de la plage consommée. Porte la version vue, pour le message.
    case outOfRange(String)
}

/// L'état d'une machine vis-à-vis de HomePortExploit. Cinq valeurs, pas deux : chacune se
/// résout par un geste différent, et les confondre envoie l'utilisateur au mauvais endroit.
public enum ExploitAvailability: Equatable, Sendable {
    case available(ExploitCapabilities)
    /// `exploitPort` absent de fleet.yaml. État neutre : il n'y a rien à réparer.
    case notDeployed
    /// Connexion refusée, timeout, 5xx. Porte la cause pour la ligne de détail.
    case unreachable(String)
    case unavailable(ExploitUnavailableReason)
    /// 403 : le service répond, mais l'identité tailnet de ce Mac n'est pas l'`admin`
    /// déclaré sur ce Pi. Absent du contrat Homeport, et nécessaire : sans lui, une erreur
    /// de `config.yaml` se présenterait comme une panne réseau et serait cherchée là.
    case forbidden
    /// La tâche appelante a disparu (changement d'onglet en cours de requête). Jamais un
    /// signal sur la machine.
    case cancelled
}
```

- [ ] **Step 4: Lancer les tests**

Run: `swift test --filter ExploitAPIContractTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/HomePortKit/ExploitAPIContract.swift Tests/HomePortKitTests/ExploitAPIContractTests.swift
git commit -m "feat: add executable HomePortExploit contract with five machine states"
```

---

### Task 3: `ExploitAPIClient`

**Files:**
- Create: `Sources/HomePortKit/ExploitAPIClient.swift`
- Test: `Tests/HomePortKitTests/ExploitAPIClientTests.swift`

**Interfaces:**
- Consumes: `apiHost(for:)` (tâche 1), tous les types de la tâche 2, `HTTPReply` (déjà public dans `HomeportAPIClient.swift`).
- Produces:
  - `public typealias ExploitHTTPFetch = @Sendable (URLRequest) async throws -> HTTPReply`
  - `ExploitAPIClient.init(fetch:)`
  - `func capabilities(of: Machine) async -> ExploitAvailability`
  - `func dryRun(_ action: ExploitAction, on: Machine) async -> ExploitOutcome`
  - `func execute(_ action: ExploitAction, planID: String, on: Machine) async -> ExploitOutcome`
  - `func audit(of: Machine, limit: Int) async -> Result<[ExploitAuditEntry], ExploitAvailability>`
  - `func dockerServices(of: Machine) async -> Result<[ExploitDockerService], ExploitAvailability>`
  - `func homeportConfig(of: Machine) async -> Result<String?, ExploitAvailability>` — `.success(nil)` signifie « configuration absente ou illisible », le 404 propre à cette route. Ce n'est **pas** `.unavailable(.notServed)` : ce 404-là ne dit rien sur l'âge du serveur.
  - `ExploitResult.detail: [String: JSONValue]` avec `var displayLines: [String]`
  - `ExploitAction.init(name:mode:service:) throws` — initialiseur faillible consommé par le CLI (tâche 5)

  La couture porte une `URLRequest`, **pas une `URL`** comme `HomeportHTTPFetch` : ce client fait des `POST` avec un corps, et un test qui ne voit que l'URL ne peut pas vérifier ce corps.

  **`homeport-config` n'est pas un cas de `ExploitAction`.** La spec §2.6 le listait dans l'enum ; c'est une erreur de la spec, corrigée ici : l'enum ne contient que ce qui se **déclenche** par le flux dry-run → execute. La config Homeport est lue par un simple `GET`, et son écriture reste `hpm config push` en SSH (décision actée). Un cas d'enum qu'on ne peut jamais exécuter serait un piège pour le prochain lecteur.

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
import XCTest
@testable import HomePortKit

final class ExploitAPIClientTests: XCTestCase {
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse", port: 80, exploitPort: 8081)
    private let bare = Machine(name: "raspyellow", ssh: "vincent@raspyellow", port: 80)

    private func client(_ reply: @escaping (URLRequest) throws -> HTTPReply) -> ExploitAPIClient {
        ExploitAPIClient(fetch: { request in try reply(request) })
    }

    private func ok(_ json: String) -> HTTPReply { HTTPReply(status: 200, body: Data(json.utf8)) }

    private let capabilitiesJSON = """
    {"contract": "1.0.0", "server": "0.2.0", "actions": ["apt-update", "docker-update", "homeport-config", "reboot"]}
    """

    func testMachineWithoutExploitPortIsNotDeployed() async {
        let api = client { _ in XCTFail("aucune requête ne doit partir"); return self.ok("{}") }
        let state = await api.capabilities(of: bare)
        XCTAssertEqual(state, .notDeployed)
    }

    func testHandshakeYieldsCapabilities() async {
        let api = client { request in
            XCTAssertEqual(request.url?.absoluteString, "http://raspcorse:8081/capabilities")
            return self.ok(self.capabilitiesJSON)
        }
        guard case .available(let caps) = await api.capabilities(of: machine) else {
            return XCTFail("handshake attendu")
        }
        XCTAssertEqual(caps.server, "0.2.0")
        XCTAssertTrue(caps.serves("apt-update"))
    }

    func testForbiddenIsItsOwnState() async {
        let api = client { _ in HTTPReply(status: 403, body: Data()) }
        XCTAssertEqual(await api.capabilities(of: machine), .forbidden)
    }

    func testNotFoundMeansTooOldToServeTheHandshake() async {
        let api = client { _ in HTTPReply(status: 404, body: Data()) }
        XCTAssertEqual(await api.capabilities(of: machine), .unavailable(.notServed))
    }

    func testNewMajorIsOutOfRange() async {
        let api = client { _ in self.ok(#"{"contract": "2.0.0", "server": "9.9.9", "actions": []}"#) }
        XCTAssertEqual(await api.capabilities(of: machine), .unavailable(.outOfRange("2.0.0")))
    }

    func testMalformedHandshakeIsTreatedExactlyLikeA404() async {
        let api = client { _ in self.ok(#"{"contract": "pas-une-version"}"#) }
        XCTAssertEqual(await api.capabilities(of: machine), .unavailable(.notServed))
    }

    func testFailedDryRunIsNotASuccessDespiteHTTP200() async {
        // Le piège du contrat : `ok` et le code HTTP sont deux axes indépendants.
        let api = client { _ in self.ok(#"{"ok": false, "message": "échec du rafraîchissement apt", "detail": {}, "plan_id": null}"#) }
        guard case .completed(let result) = await api.dryRun(.aptUpdate, on: machine) else {
            return XCTFail("réponse décodée attendue")
        }
        XCTAssertFalse(result.ok)
        XCTAssertNil(result.planID)
    }

    func testExecuteSendsPlanIDFlatAlongsideParameters() async throws {
        // Le serveur fait `payload.pop("plan_id")` AVANT la validation Pydantic : imbriquer
        // le jeton produit un 422. C'est le piège qu'un refactor futur reproduirait.
        var captured: [String: Any] = [:]
        let api = client { request in
            let body = request.httpBody ?? Data()
            captured = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            return self.ok(#"{"ok": true, "message": "commande envoyée", "detail": {}}"#)
        }
        _ = await api.execute(.reboot(mode: .poweroff), planID: "abc123", on: machine)
        XCTAssertEqual(captured["plan_id"] as? String, "abc123")
        XCTAssertEqual(captured["mode"] as? String, "poweroff")
        XCTAssertNil(captured["params"], "le jeton et les paramètres sont à plat, pas imbriqués")
    }

    func testExpiredTokenIsReportedAsSuch() async {
        let api = client { _ in HTTPReply(status: 409, body: Data()) }
        guard case .staleToken = await api.execute(.aptUpdate, planID: "vieux", on: machine) else {
            return XCTFail("409 doit devenir staleToken, pas une erreur brute")
        }
    }

    func testUnknownActionOn404IsDistinctFromNotServed() async {
        // Le handshake a forcément réussi avant cet appel : ce 404 dit « action inconnue de ce
        // catalogue », pas « serveur antérieur au contrat v1 ». Les deux se réparent
        // différemment et ne doivent pas se confondre (fix round 2).
        let api = client { _ in HTTPReply(status: 404, body: Data()) }
        guard case .unknownAction = await api.dryRun(.aptUpdate, on: machine) else {
            return XCTFail("404 sur une route d'action doit devenir unknownAction, pas notServed")
        }
    }

    func testSwiftCancellationErrorIsReportedAsCancelled() async {
        let api = client { _ in throw CancellationError() }
        let state = await api.capabilities(of: machine)
        XCTAssertEqual(state, .cancelled)
    }

    func testURLErrorCancelledIsAlsoReportedAsCancelled() async {
        // URLSession ne lève pas toujours `CancellationError` : selon le moment où l'annulation
        // survient, elle arrive en `URLError(.cancelled)`. Un refactor qui reviendrait à
        // `error is CancellationError` seul repasserait ce test au rouge (fix round 2).
        let api = client { _ in throw URLError(.cancelled) }
        let state = await api.capabilities(of: machine)
        XCTAssertEqual(state, .cancelled)
    }
}
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter ExploitAPIClientTests`
Expected: FAIL — le type n'existe pas.

- [ ] **Step 3: Écrire l'implémentation minimale**

```swift
import Foundation

/// La couture réseau du client exploit. Elle porte une `URLRequest` et non une `URL` —
/// contrairement à `HomeportHTTPFetch` — parce que ce client fait des `POST` : un test qui ne
/// verrait que l'URL ne pourrait pas vérifier le corps, et le corps est la moitié du contrat.
public typealias ExploitHTTPFetch = @Sendable (URLRequest) async throws -> HTTPReply

/// Conformance ajoutée ici, pas dans `ExploitAPIContract.swift` (tâche 2) : les trois lectures
/// rendent leur échec via `Result<Value, ExploitAvailability>`, ce que `Result` exige de son
/// type `Failure`. `ExploitAvailability` reste une valeur rendue, jamais lancée (AD, cf.
/// `ExploitOutcome`) — cette conformance ne l'expose à aucun `throw`.
extension ExploitAvailability: Error {}

/// Les trois actions du catalogue v1 qui se déclenchent réellement par le flux
/// dry-run → execute. `homeport-config` figure dans `/capabilities` (§3 du contrat) mais ne
/// figure pas ici : sa lecture est un simple `GET` (`homeportConfig(of:)`), et son écriture
/// reste `hpm config push` en SSH — un cas d'enum qu'on ne peut jamais exécuter serait un
/// piège pour le prochain lecteur.
///
/// Le `params_schema` renvoyé par `/actions` est transporté, jamais interprété (AD-4) : pas
/// de générateur de formulaire.
public enum ExploitAction: Equatable, Sendable {
    case aptUpdate
    case reboot(mode: RebootMode)
    case dockerUpdate(service: String)

    public enum RebootMode: String, Equatable, Sendable, CaseIterable {
        case reboot, poweroff
    }

    public var name: String {
        switch self {
        case .aptUpdate: return "apt-update"
        case .reboot: return "reboot"
        case .dockerUpdate: return "docker-update"
        }
    }

    /// Les paramètres, à plat — c'est la forme que le serveur valide.
    var parameters: [String: String] {
        switch self {
        case .aptUpdate: return [:]
        case .reboot(let mode): return ["mode": mode.rawValue]
        case .dockerUpdate(let service): return ["service": service]
        }
    }

    /// Initialiseur faillible consommé par le CLI (tâche 5) : refuse un nom hors catalogue,
    /// un `reboot` sans `mode` valide, ou un `docker-update` sans `service`, avant d'émettre —
    /// plutôt que de laisser le serveur répondre `422`.
    public init(name: String, mode: String?, service: String?) throws {
        switch name {
        case "apt-update":
            self = .aptUpdate
        case "reboot":
            guard let mode, let parsed = RebootMode(rawValue: mode) else {
                throw HPMError("reboot requiert --mode reboot|poweroff")
            }
            self = .reboot(mode: parsed)
        case "docker-update":
            guard let service, !service.isEmpty else {
                throw HPMError("docker-update requiert --service <nom>")
            }
            self = .dockerUpdate(service: service)
        default:
            throw HPMError("action inconnue: \(name)")
        }
    }
}

/// Une valeur JSON quelconque. Le `detail` du serveur est hétérogène — listes de paquets,
/// booléens, `null` — donc `[String: String]` ne le décode pas. Le client le transporte sans
/// l'interpréter (AD-4) et se contente de savoir l'afficher.
public enum JSONValue: Equatable, Sendable, Decodable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "valeur JSON non reconnue")
        }
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    /// Les lignes qu'une interface affiche pour un `detail` : une par valeur scalaire, une par
    /// élément de liste. L'ordre des clés est stable pour que l'affichage ne saute pas.
    var displayLines: [String] {
        keys.sorted().flatMap { key -> [String] in
            switch self[key] {
            case .array(let items): return items.map { "\(key): \($0.displayText)" }
            case .some(let value): return ["\(key): \(value.displayText)"]
            case nil: return []
            }
        }
    }
}

public extension JSONValue {
    var displayText: String {
        switch self {
        case .string(let s): return s
        // `Int(n)` trappe si `n` dépasse la capacité d'un `Int` (ex. 1e30) — `detail` est
        // transporté sans être interprété (AD-4), donc rien ne garantit qu'un nombre qui y
        // arrive tienne dans un `Int`. `Int(exactly:)` échoue proprement à la place ; on
        // retombe alors sur la représentation `Double`.
        case .number(let n):
            if n.isFinite, n == n.rounded(), let whole = Int(exactly: n) {
                return String(whole)
            }
            return String(n)
        case .bool(let b): return b ? "oui" : "non"
        case .null: return "—"
        case .array(let items): return items.map(\.displayText).joined(separator: ", ")
        case .object(let o): return o.displayLines.joined(separator: " · ")
        }
    }
}

/// Le résultat métier d'un dry-run ou d'une exécution. `ok` est indépendant du code HTTP.
public struct ExploitResult: Equatable, Sendable {
    public let ok: Bool
    public let message: String
    /// Transporté tel quel : le client ne décide pas de sa forme (AD-4).
    public let detail: [String: JSONValue]
    /// Présent seulement sur un dry-run réussi.
    public let planID: String?
}

/// La forme décodée d'une réponse de dry-run ou d'exécution. Type nommé au niveau fichier —
/// et non une struct locale à `post(...)` — parce que les tests le décodent directement.
struct ExploitResultPayload: Decodable {
    let ok: Bool
    let message: String
    let detail: [String: JSONValue]?
    let plan_id: String?

    var result: ExploitResult {
        ExploitResult(ok: ok, message: message, detail: detail ?? [:], planID: plan_id)
    }
}

public enum ExploitOutcome: Equatable, Sendable {
    case completed(ExploitResult)
    /// 409 : jeton requis, expiré ou déjà consommé. Sa réponse est « refaire le dry-run »,
    /// jamais un renouvellement silencieux — qui exécuterait sans avoir rien montré.
    ///
    /// Un jeton est brûlé par la **tentative**, pas par le succès : `pending.consume()`
    /// marque `used=1` avant de vérifier que l'action et les paramètres correspondent.
    /// Un `execute` envoyé avec des paramètres valides mais différents de ceux prévisualisés
    /// consomme donc le jeton **et** échoue. Corollaire pour ce client : ne jamais rejouer
    /// un `plan_id` avec d'autres paramètres, et traiter tout 409 comme définitif.
    case staleToken
    /// 404 sur `/actions/{name}/dry-run` ou `/execute` — l'action envoyée ne figure pas dans le
    /// catalogue de ce serveur. Distinct de `.unavailable(.notServed)` : ce dernier veut dire
    /// « antérieur à `/capabilities` », et le handshake qui a précédé cet appel a justement
    /// réussi — c'est un désaccord sur *quelles* actions sont servies, pas sur si le contrat
    /// l'est. Pas un cas d'`ExploitAvailability` : ce n'est pas un état de la machine.
    case unknownAction
    case unavailable(ExploitAvailability)
}

/// Une ligne de `GET /audit` (§8), exactement les sept champs que `homeportexploit/audit.py`
/// sert — pas de `id` : le serveur n'en garde aucun. Une vue qui a besoin d'une identité stable
/// s'en construit une (index, ou composite `ts`+`action`) ; ce n'est pas au modèle d'en inventer
/// une que le contrat ne porte pas.
public struct ExploitAuditEntry: Equatable, Sendable {
    /// Calculé depuis `ts` (secondes Unix, §8) — c'est cette forme qu'un affichage voudra.
    public let timestamp: Date
    public let identity: String
    public let action: String
    /// Les paramètres de l'action, sérialisés en JSON dans une chaîne (§8). Transporté tel
    /// quel : un client qui veut les paramètres structurés reparse ce champ lui-même.
    public let params: String
    /// `dry_run` arrive en entier `0`/`1` côté fil (§8 : « pas un booléen JSON ») ; exposé ici
    /// en `Bool`, la forme qu'un appelant Swift veut.
    public let dryRun: Bool
    public let ok: Bool
    public let message: String
}

public struct ExploitDockerService: Equatable, Sendable, Identifiable, Decodable {
    public var id: String { name }
    public let name: String
    public let image: String

    private enum CodingKeys: String, CodingKey {
        case name, image
    }
}

public struct ExploitAPIClient: Sendable {
    private let fetch: ExploitHTTPFetch

    public init(fetch: @escaping ExploitHTTPFetch = ExploitAPIClient.urlSessionFetch()) {
        self.fetch = fetch
    }

    public static func urlSessionFetch(timeout: TimeInterval = 10) -> ExploitHTTPFetch {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 3
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HPMError("réponse non HTTP de \(request.url?.absoluteString ?? "?")")
            }
            return HTTPReply(status: http.statusCode, body: data)
        }
    }

    /// L'adresse d'une surface. `nil` quand la machine ne déclare pas de port exploit —
    /// l'appelant en fait `.notDeployed`, jamais une erreur.
    static func endpoint(_ path: String, on machine: Machine, query: [URLQueryItem] = []) -> URL? {
        guard let port = machine.exploitPort, (1...65535).contains(port),
              let host = apiHost(for: machine) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/\(path)"
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    private struct CapabilitiesPayload: Decodable {
        let contract: String
        let server: String
        let actions: [String]
    }

    /// Une annulation vue par `URLSession` n'est pas toujours une `CancellationError` Swift :
    /// selon le moment où elle survient, elle arrive aussi en `URLError(.cancelled)` — comme
    /// `HomeportAPIClient.isCancellation` (privé à son fichier, donc dupliqué ici plutôt que
    /// réutilisé) le documente déjà. Une tâche annulée est un onglet fermé, jamais un signal
    /// sur la machine.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    public func capabilities(of machine: Machine) async -> ExploitAvailability {
        guard let url = Self.endpoint("capabilities", on: machine) else { return .notDeployed }
        let reply: HTTPReply
        do {
            reply = try await fetch(URLRequest(url: url))
        } catch {
            if Self.isCancellation(error) { return .cancelled }
            return .unreachable(String(describing: error))
        }
        switch reply.status {
        case 200: break
        case 403: return .forbidden
        case 404: return .unavailable(.notServed)
        default: return .unreachable("HTTP \(reply.status)")
        }
        // Un handshake auquel il manque un champ, ou dont un champ a le mauvais type, est
        // traité EXACTEMENT comme un 404 : dans les deux cas, ce serveur ne sert pas ce contrat.
        guard let payload = try? JSONDecoder().decode(CapabilitiesPayload.self, from: reply.body),
              let version = SemanticVersion(parsing: payload.contract) else {
            return .unavailable(.notServed)
        }
        guard ExploitContract.consumes(version) else {
            return .unavailable(.outOfRange(payload.contract))
        }
        return .available(ExploitCapabilities(contract: version, server: payload.server,
                                              actions: payload.actions))
    }

    public func dryRun(_ action: ExploitAction, on machine: Machine) async -> ExploitOutcome {
        await post(action.parameters, to: "actions/\(action.name)/dry-run", on: machine)
    }

    public func execute(_ action: ExploitAction, planID: String, on machine: Machine) async -> ExploitOutcome {
        // Le jeton voyage À PLAT, à côté des paramètres : le serveur le retire du corps avant
        // de valider le reste. Une charge utile imbriquée reçoit un 422.
        var body = action.parameters
        body["plan_id"] = planID
        return await post(body, to: "actions/\(action.name)/execute", on: machine)
    }

    private func post(_ body: [String: String], to path: String, on machine: Machine) async -> ExploitOutcome {
        guard let url = Self.endpoint(path, on: machine) else { return .unavailable(.notDeployed) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let reply: HTTPReply
        do {
            reply = try await fetch(request)
        } catch {
            if Self.isCancellation(error) { return .unavailable(.cancelled) }
            return .unavailable(.unreachable(String(describing: error)))
        }
        switch reply.status {
        case 200: break
        case 403: return .unavailable(.forbidden)
        // Le handshake a réussi avant cet appel (sinon on ne serait pas ici) : ce 404 ne dit
        // pas « serveur trop vieux », il dit « action inconnue de ce catalogue ». Confondre les
        // deux enverrait l'utilisateur mettre à jour un serveur qui n'a rien de périmé.
        case 404: return .unknownAction
        case 409: return .staleToken
        default: return .unavailable(.unreachable("HTTP \(reply.status)"))
        }
        guard let payload = try? JSONDecoder().decode(ExploitResultPayload.self, from: reply.body) else {
            return .unavailable(.unreachable("réponse illisible"))
        }
        return .completed(payload.result)
    }

    // MARK: Les trois lectures (§8, §9, §10)

    /// La forme réelle d'une ligne `/audit` (§8, vérifié contre `homeportexploit/audit.py`) :
    /// `ts` en secondes Unix, `dry_run`/`ok` en `0`/`1`, aucun `id`. `params` est transporté
    /// tel quel — chaîne JSON, jamais reparsée ici (AD-4).
    private struct AuditEntryPayload: Decodable {
        let ts: Int64
        let identity: String
        let action: String
        let params: String
        let dry_run: Int
        let ok: Int
        let message: String
    }

    /// `GET /audit?limit=` — bornée à la machine interrogée (§8) : ce client ne fusionne
    /// jamais les résultats de plusieurs machines.
    public func audit(of machine: Machine, limit: Int) async -> Result<[ExploitAuditEntry], ExploitAvailability> {
        await get([AuditEntryPayload].self, path: "audit", query: [URLQueryItem(name: "limit", value: String(limit))],
                   on: machine) { payloads in
            payloads.map {
                ExploitAuditEntry(timestamp: Date(timeIntervalSince1970: TimeInterval($0.ts)),
                                   identity: $0.identity, action: $0.action, params: $0.params,
                                   dryRun: $0.dry_run != 0, ok: $0.ok != 0, message: $0.message)
            }
        }
    }

    /// `GET /docker-services` — filtré côté serveur sur `name`/`image` uniquement (§9).
    public func dockerServices(of machine: Machine) async -> Result<[ExploitDockerService], ExploitAvailability> {
        await get([ExploitDockerService].self, path: "docker-services", on: machine) { $0 }
    }

    private struct HomeportConfigPayload: Decodable {
        let content: String
    }

    /// `GET /homeport-config/current` — lecture seule ; l'écriture reste `hpm config push`
    /// en SSH (décision actée, brief tâche 3).
    ///
    /// Ne partage PAS le motif `get(...)` des deux autres lectures : §10 donne à son 404 un
    /// sens propre — « configuration Homeport illisible ou introuvable », le serveur sert la
    /// route très bien — sans rapport avec un serveur antérieur au contrat v1. Rendre ce cas
    /// en `.unavailable(.notServed)` via le motif partagé enverrait l'appelant "mettre à jour
    /// HomePortExploit" pour un fichier manquant côté Homeport. `.success(nil)` porte ce sens
    /// sans ajouter de cas à `ExploitAvailability` : ce n'est pas un état de la machine, c'est
    /// l'absence d'un fichier.
    public func homeportConfig(of machine: Machine) async -> Result<String?, ExploitAvailability> {
        guard let url = Self.endpoint("homeport-config/current", on: machine) else { return .failure(.notDeployed) }
        let reply: HTTPReply
        do {
            reply = try await fetch(URLRequest(url: url))
        } catch {
            if Self.isCancellation(error) { return .failure(.cancelled) }
            return .failure(.unreachable(String(describing: error)))
        }
        switch reply.status {
        case 200: break
        case 403: return .failure(.forbidden)
        case 404: return .success(nil)
        default: return .failure(.unreachable("HTTP \(reply.status)"))
        }
        guard let payload = try? JSONDecoder().decode(HomeportConfigPayload.self, from: reply.body) else {
            return .failure(.unreachable("réponse illisible"))
        }
        return .success(payload.content)
    }

    /// Le motif commun à `audit(of:)` et `dockerServices(of:)` : `endpoint(...)` → `nil` donne
    /// `.notDeployed`, puis le même classement 200 / 403 / 404 / défaut que `capabilities(of:)`.
    /// `homeportConfig(of:)` ne le partage pas (voir son commentaire) : son 404 ne veut pas dire
    /// la même chose, et tordre ce motif pour le faire mentir sur un cas serait pire que le
    /// dédoubler.
    private func get<Payload: Decodable, Value>(
        _ type: Payload.Type, path: String, query: [URLQueryItem] = [], on machine: Machine,
        map: (Payload) -> Value
    ) async -> Result<Value, ExploitAvailability> {
        guard let url = Self.endpoint(path, on: machine, query: query) else { return .failure(.notDeployed) }
        let reply: HTTPReply
        do {
            reply = try await fetch(URLRequest(url: url))
        } catch {
            if Self.isCancellation(error) { return .failure(.cancelled) }
            return .failure(.unreachable(String(describing: error)))
        }
        switch reply.status {
        case 200: break
        case 403: return .failure(.forbidden)
        case 404: return .failure(.unavailable(.notServed))
        default: return .failure(.unreachable("HTTP \(reply.status)"))
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: reply.body) else {
            return .failure(.unreachable("réponse illisible"))
        }
        return .success(map(payload))
    }
}
```

> **Note sur `detail`** : le serveur renvoie un objet aux valeurs hétérogènes — listes de paquets, booléens, `null`. C'est pourquoi `JSONValue` et `ExploitResultPayload` ci-dessus existent, et pourquoi `ExploitResult.detail` est `[String: JSONValue]` et non `[String: String]`. Les paramètres **envoyés** (`ExploitAction.parameters`, le corps de `post`) restent `[String: String]` : ceux-là sont bien tous des chaînes. **Écrire d'abord le test qui décode le `detail` réel d'un dry-run `apt-update`** (`{"packages": ["chromium/stable 1.2 arm64", …]}`) et le voir échouer.

- [ ] **Step 4: Écrire les tests des trois lectures et de l'initialiseur faillible**

```swift
func testAuditDecodesEntriesOfThisMachineOnly() async {
    // Fixture conforme à ce que `homeportexploit/audit.py` sert réellement (§8) : `ts` en
    // secondes Unix, `dry_run`/`ok` en `0`/`1`, `params` en chaîne JSON, aucun `id`. La
    // première version de ce test avait une fixture auto-cohérente avec un mauvais modèle
    // (`id`, `timestamp` ISO 8601, booléens JSON) — corrigé après vérification du code
    // Python amont, cf. fix round 1.
    let api = client { request in
        XCTAssertEqual(request.url?.query, "limit=50")
        return self.ok(#"[{"ts": 1756800000, "identity": "vincent.lauriat@gmail.com", "action": "apt-update", "params": "{}", "dry_run": 1, "ok": 1, "message": "5 paquet(s) à mettre à jour"}]"#)
    }
    guard case .success(let entries) = await api.audit(of: machine, limit: 50) else {
        return XCTFail("décodage attendu")
    }
    XCTAssertEqual(entries.first?.action, "apt-update")
    // La conversion 0/1 → Bool et ts → Date, pas seulement la présence des champs.
    XCTAssertEqual(entries.first?.dryRun, true)
    XCTAssertEqual(entries.first?.ok, true)
    XCTAssertEqual(entries.first?.timestamp, Date(timeIntervalSince1970: 1756800000))
    XCTAssertEqual(entries.first?.params, "{}")
}

func testDockerServicesPopulateTheSelector() async {
    let api = client { _ in self.ok(#"[{"name": "homeassistant", "image": "ghcr.io/x/y:stable"}]"#) }
    guard case .success(let services) = await api.dockerServices(of: machine) else {
        return XCTFail("décodage attendu")
    }
    XCTAssertEqual(services.map(\.name), ["homeassistant"])
}

func testDockerServicesForbiddenIsItsOwnFailure() async {
    // Le motif partagé `get(...)` (audit/docker-services) n'était testé que via
    // `homeportConfig`, qui ne le partage plus depuis le fix round 1 — les branches
    // 403/404 du motif partagé lui-même n'avaient donc plus de test (fix round 2).
    let api = client { _ in HTTPReply(status: 403, body: Data()) }
    guard case .failure(let availability) = await api.dockerServices(of: machine) else {
        return XCTFail("403 doit rester une panne, pas une liste vide")
    }
    XCTAssertEqual(availability, .forbidden)
}

func testAuditNotFoundMeansTooOldToServeTheRoute() async {
    // À la différence de `homeportConfig`, `/audit` n'a pas de sens propre pour son 404 dans
    // le contrat (§8 ne le documente pas) : le motif partagé continue de le traiter comme
    // un serveur antérieur au contrat, cohérent avec `capabilities(of:)`.
    let api = client { _ in HTTPReply(status: 404, body: Data()) }
    guard case .failure(let availability) = await api.audit(of: machine, limit: 50) else {
        return XCTFail("404 doit rester une panne du motif partagé")
    }
    XCTAssertEqual(availability, .unavailable(.notServed))
}

func testHomeportConfigIsReadOnlyText() async {
    let api = client { _ in self.ok(#"{"content": "services:\n  - name: ha\n"}"#) }
    guard case .success(let text) = await api.homeportConfig(of: machine) else {
        return XCTFail("décodage attendu")
    }
    XCTAssertEqual(text, "services:\n  - name: ha\n")
}

func testHomeportConfigMissingFileIsNilNotNotServed() async {
    // §10 : ce 404 signifie « configuration Homeport illisible ou introuvable », pas
    // « serveur antérieur au contrat v1 ». `.success(nil)` porte ce sens sans ajouter de
    // cas à `ExploitAvailability`.
    let api = client { _ in HTTPReply(status: 404, body: Data()) }
    guard case .success(let text) = await api.homeportConfig(of: machine) else {
        return XCTFail("un 404 sur cette route n'est pas une panne de machine")
    }
    XCTAssertNil(text)
}

func testUnknownActionNameIsRejectedBeforeAnyRequest() {
    XCTAssertThrowsError(try ExploitAction(name: "rm-rf", mode: nil, service: nil))
    XCTAssertThrowsError(try ExploitAction(name: "reboot", mode: nil, service: nil),
                         "reboot sans mode doit échouer côté client, pas en 422 côté serveur")
}

func testAptUpdateDetailRendersItsPackageList() throws {
    // Le `detail` réel d'un dry-run apt-update : des valeurs hétérogènes, pas des String.
    let json = #"{"ok": true, "message": "5 paquet(s)", "detail": {"packages": ["chromium/stable 1.2 arm64"]}, "plan_id": "x"}"#
    let payload = try JSONDecoder().decode(ExploitResultPayload.self, from: Data(json.utf8))
    XCTAssertTrue(payload.result.detail.displayLines.contains { $0.contains("chromium") })
}

func testDisplayTextDoesNotTrapOnANumberLargerThanInt() throws {
    // `detail` est transporté sans être interprété (AD-4) : rien ne garantit qu'un nombre
    // qui y arrive tienne dans un `Int`. `Int(1e30)` trappe ; `displayText` ne doit pas
    // (fix round 2).
    let json = #"{"ok": true, "message": "m", "detail": {"huge": 1e30}, "plan_id": null}"#
    let payload = try JSONDecoder().decode(ExploitResultPayload.self, from: Data(json.utf8))
    XCTAssertEqual(payload.result.detail.displayLines, ["huge: 1e+30"])
}
```

Les trois lectures suivent le même motif que `capabilities(of:)` : `endpoint(...)` → `nil` donne
`.failure(.notDeployed)`, puis le même `switch` sur 200 / 403 / 404 / défaut. `audit` passe
`limit` en `URLQueryItem` et mappe `dry_run` → `dryRun`.

`JSONValue` est un `enum Decodable` à six cas (`string`, `number`, `bool`, `null`, `array`,
`object`) ; `displayLines` aplatit récursivement en lignes lisibles.

`JSONValue`, son `displayLines` et `ExploitResultPayload` sont **déjà écrits en entier** au
step 3 : les transcrire, ne pas les réinventer. **Écrire le test
`testAptUpdateDetailRendersItsPackageList` en premier et le voir échouer** : c'est lui qui
prouve que `[String: String]` ne suffisait pas.

`ExploitAction.init(name:mode:service:)` rejette un nom hors catalogue, un `reboot` sans
`mode` valide et un `docker-update` sans `service`, avec un `HPMError` nommant l'option
manquante — le client refuse avant d'émettre, plutôt que de laisser le serveur répondre 422.

- [ ] **Step 5: Lancer les tests**

Run: `swift test --filter ExploitAPIClientTests`
Expected: PASS.

- [ ] **Step 6: Lancer la suite entière**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/HomePortKit/ExploitAPIClient.swift Tests/HomePortKitTests/ExploitAPIClientTests.swift
git commit -m "feat: add ExploitAPIClient with request-level injection seam"
```

---

### Task 4: Journal, verrou, et la surcharge `async`

**Files:**
- Modify: `Sources/HomePortKit/Manager+Journal.swift` (surcharge `async` de `journaled`)
- Modify: `Sources/HomePortKit/Manager+Prereqs.swift:11-40` — c'est là que `HomeportManager` est **déclarée** (malgré le nom du fichier). Y ajouter `public let exploit: ExploitAPIClient` et le paramètre d'init correspondant, avec `ExploitAPIClient()` par défaut, sur le modèle de `runner` et `history`.
- Create: `Sources/HomePortKit/Manager+Maintenance.swift`
- Test: `Tests/HomePortKitTests/ManagerMaintenanceTests.swift`

> **La propriété du journal s'appelle `history`, pas `historyStore`** (`public let history: HistoryStore?`, nullable — le journal se dégrade, il ne bloque jamais l'action). Les squelettes de test ci-dessous emploient `historyStore` : c'est un nom d'emprunt à corriger.

**Interfaces:**
- Consumes: tâche 3.
- Produces sur `HomeportManager` :
  - `func maintenanceCapabilities(of: Machine) async -> ExploitAvailability` (lecture : journalisée, **non verrouillée**)
  - `func maintenancePlan(_ action: ExploitAction, on: Machine) async throws -> ExploitOutcome` (journal `maintenance-plan`, **verrouillée**)
  - `func maintenanceRun(_ action: ExploitAction, planID: String, on: Machine) async throws -> ExploitOutcome` (journal `maintenance-run`, **verrouillée**)
  - `func maintenanceAudit(of: Machine, limit: Int) async -> Result<[ExploitAuditEntry], ExploitAvailability>` (lecture)

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
func testPlanTakesTheLockBecauseDryRunWritesOnThePi() async throws {
    // Le dry-run d'apt-update exécute `sudo apt-get update`, qui écrit les listes de paquets
    // et prend les verrous d'apt. Ce n'est pas une lecture, et il doit verrouiller.
    let manager = makeManagerWithTemporaryHistory()
    let held = try manager.historyStore.acquireLock(machine: "raspcorse", pid: 4242, now: Date())
    XCTAssertNotNil(held)
    do {
        _ = try await manager.maintenancePlan(.aptUpdate, on: machine)
        XCTFail("le verrou tenu ailleurs doit refuser l'opération")
    } catch is LockContentionError {
        // attendu
    }
}

func testCapabilitiesDoesNotTakeTheLock() async throws {
    let manager = makeManagerWithTemporaryHistory()
    _ = try manager.historyStore.acquireLock(machine: "raspcorse", pid: 4242, now: Date())
    // Une lecture reste libre et parallèle (AD-16) : aucune exception.
    _ = await manager.maintenanceCapabilities(of: machine)
}

func testRunIsRecordedInTheFleetJournal() async throws {
    let manager = makeManagerWithTemporaryHistory()
    _ = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: machine)
    let entries = try manager.historyStore.recent(limit: 10)
    XCTAssertTrue(entries.contains { $0.action == "maintenance-run" && $0.machine == "raspcorse" })
}
```

> **Ces trois tests sont un squelette à adapter, pas du code à coller.** `makeManagerWithTemporaryHistory()` et `manager.historyStore` sont des noms d'emprunt : `HomeportManager` n'expose pas nécessairement son `HistoryStore` sous ce nom. **Lire `Tests/HomePortKitTests/LockTests.swift` et `ManagerBackupJobTests.swift` avant d'écrire ceux-ci** et réutiliser leurs fabriques telles quelles. Injecter un `ExploitAPIClient` à couture bouchonnée — jamais de réseau réel dans un test.

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter ManagerMaintenanceTests`
Expected: FAIL — les méthodes n'existent pas.

- [ ] **Step 3: Ajouter la surcharge `async` de `journaled`**

Dupliquer le corps de `journaled(_:on:locking:_:)` dans une surcharge dont la closure est
`async throws -> T`, en préservant **exactement** la sémantique existante :

- profondeur de réentrance (`journal.enter()` / `exit()`, corps exécuté nu si `depthBefore != 0`) ;
- portée de la libération du verrou à l'acquisition exacte (machine, pid, `acquired_at`) — le `defer` tardif ne doit jamais libérer un verrou réacquis entre-temps ;
- `LockContentionError` relancée **avant toute écriture au journal** ;
- `warnLockUnavailable(error)` pour les autres échecs de verrou.

Ne pas factoriser les deux versions dans un tronc commun tant que la surcharge n'est pas verte : `defer` et `async` interagissent différemment, et une refactorisation prématurée casserait le chemin synchrone déjà couvert par `LockTests`.

- [ ] **Step 4: Écrire `Manager+Maintenance.swift`**

```swift
import Foundation

extension HomeportManager {
    /// Lecture (AD-16) : journalisée, jamais verrouillée.
    public func maintenanceCapabilities(of machine: Machine) async -> ExploitAvailability {
        await exploit.capabilities(of: machine)
    }

    /// Le dry-run écrit sur le Pi (`apt-get update`) : il verrouille comme une exécution.
    public func maintenancePlan(_ action: ExploitAction, on machine: Machine) async throws -> ExploitOutcome {
        try await journaled("maintenance-plan", on: machine, locking: true) {
            await exploit.dryRun(action, on: machine)
        }
    }

    public func maintenanceRun(_ action: ExploitAction, planID: String,
                               on machine: Machine) async throws -> ExploitOutcome {
        try await journaled("maintenance-run", on: machine, locking: true) {
            await exploit.execute(action, planID: planID, on: machine)
        }
    }
}
```

`exploit` est une propriété `ExploitAPIClient` ajoutée à `HomeportManager`, injectable au constructeur avec `ExploitAPIClient()` par défaut — même motif que `ssh` et `history`.

- [ ] **Step 5: Lancer les tests**

Run: `swift test`
Expected: PASS, `LockTests` comprises et **inchangées**.

- [ ] **Step 6: Commit**

```bash
git add Sources/HomePortKit/Manager+Journal.swift Sources/HomePortKit/Manager+Maintenance.swift \
        Tests/HomePortKitTests/ManagerMaintenanceTests.swift
git commit -m "feat: journal and lock maintenance actions delegated to HomePortExploit"
```

---

### Task 5: `hpm maintenance`

**Files:**
- Modify: `Sources/hpm/Commands.swift`
- Modify: `Sources/hpm/HPM.swift:15-20` (ajouter `MaintenanceCmd.self`)
- Test: `Tests/HomePortKitTests/ManagerMaintenanceTests.swift` (rendu des états)

**Interfaces:**
- Consumes: tâche 4.
- Produces: `hpm maintenance actions|plan|run|history <machine>`.

- [ ] **Step 1: Écrire le test de rendu qui échoue**

Le rendu des cinq états est la partie testable sans process. Extraire une fonction pure et la tester :

```swift
func testEachStateRendersItsOwnCause() {
    XCTAssertTrue(describe(.notDeployed).contains("pas déployé"))
    XCTAssertTrue(describe(.forbidden).contains("admin"))
    XCTAssertTrue(describe(.unavailable(.notServed)).contains("trop ancien"))
    XCTAssertTrue(describe(.unavailable(.outOfRange("2.0.0"))).contains("2.0.0"))
    // Le piège qui a coûté une demi-journée au déploiement initial : un timeout est
    // indiscernable d'une panne machine si le message ne nomme pas l'ACL.
    XCTAssertTrue(describe(.unreachable("timed out")).contains("ACL Tailscale"))
}
```

- [ ] **Step 2: Lancer le test pour vérifier qu'il échoue**

Run: `swift test --filter testEachStateRendersItsOwnCause`
Expected: FAIL — `describe` n'existe pas.

- [ ] **Step 3: Écrire `describe` et les commandes**

`describe(_ state: ExploitAvailability) -> String` est **ajoutée à `Sources/HomePortKit/ExploitAPIContract.swift`** (tâche 2), partagée par le CLI et l'onglet : une seule formulation par état, pas deux qui divergeront. Les six messages :

| État | Message |
|---|---|
| `.notDeployed` | `HomePortExploit n'est pas déployé sur cette machine (aucun exploitPort dans fleet.yaml).` |
| `.unreachable(let why)` | `injoignable (\(why)) — machine éteinte, service arrêté, ou port absent de l'ACL Tailscale.` |
| `.unavailable(.notServed)` | `HomePortExploit répond mais est trop ancien : pas de route /capabilities.` |
| `.unavailable(.outOfRange(let v))` | `contrat \(v) hors de la plage consommée — mettre à jour hpm ou HomePortExploit.` |
| `.forbidden` | `refusé : l'identité tailnet de ce Mac n'est pas l'admin déclaré sur cette machine.` |
| `.available(let caps)` | `HomePortExploit \(caps.server) — actions : \(caps.actions.joined(separator: ", "))` |

Puis, dans `Commands.swift`, sur le modèle de `DoctorCmd` et de `BackupCmd` (groupe à sous-commandes) :

```swift
struct MaintenanceCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maintenance",
        abstract: "Run HomePortExploit maintenance actions on a machine.",
        subcommands: [Actions.self, Plan.self, Run.self, History.self]
    )

    struct Actions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "What this machine serves, or why it serves nothing.")
        @Argument var machine: String

        func run() async throws {
            let target = try FleetStore().machine(named: self.machine)
            let state = await makeManager().maintenanceCapabilities(of: target)
            print(describe(state))
            if case .available = state { return }
            throw ExitCode(1)
        }
    }
    // Plan, Run, History suivent le même motif.
}
```

`Run` enchaîne **toujours** le dry-run avant l'exécution — c'est le seul moyen d'obtenir un `plan_id`, et le serveur refuse (409) sans lui :

```swift
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Dry-run, show the preview, confirm, then execute.")
    @Argument var machine: String
    @Argument var action: String
    @Option(help: "reboot | poweroff (reboot only).") var mode: String?
    @Option(help: "Docker service name (docker-update only).") var service: String?
    @Flag(name: .long, help: "Skip the interactive question. The preview is still shown.") var yes = false

    func run() async throws {
        let target = try FleetStore().machine(named: self.machine)
        let manager = makeManager()
        let parsed = try ExploitAction(name: action, mode: mode, service: service)

        guard case .completed(let preview) = try await manager.maintenancePlan(parsed, on: target) else {
            print("prévisualisation impossible"); throw ExitCode(1)
        }
        print(preview.message)
        preview.detail.displayLines.forEach { print("  \($0)") }
        guard preview.ok, let planID = preview.planID else { throw ExitCode(1) }

        if !yes {
            print("Exécuter ? [o/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "o" || answer == "oui" else {
                print("annulé"); return
            }
        }
        switch try await manager.maintenanceRun(parsed, planID: planID, on: target) {
        case .completed(let result):
            print(result.message)
            if !result.ok { throw ExitCode(1) }
        case .staleToken:
            print("prévisualisation expirée (jeton valable 5 minutes) — relancer la commande")
            throw ExitCode(1)
        case .unavailable(let state):
            print(describe(state)); throw ExitCode(1)
        }
    }
}
```

`ExploitAction(name:mode:service:)` est un initialiseur faillible ajouté en tâche 3 qui rejette un nom d'action inconnu et un paramètre manquant avec un `HPMError` explicite.

- [ ] **Step 4: Enregistrer la commande et lancer les tests**

Ajouter `MaintenanceCmd.self` à la liste `subcommands` de `HPM.swift`.

Run: `swift test && swift build && .build/debug/hpm maintenance --help`
Expected: PASS, et l'aide liste les quatre sous-commandes.

- [ ] **Step 5: Commit**

```bash
git add Sources/hpm/Commands.swift Sources/hpm/HPM.swift Sources/HomePortKit/ExploitAPIContract.swift \
        Tests/HomePortKitTests/ManagerMaintenanceTests.swift
git commit -m "feat: add hpm maintenance command group"
```

---

### Task 6: L'onglet Maintenance

**Files:**
- Modify: `App/Sources/MachineDetailView.swift` (enum `MachineTab` + routage)
- Create: `App/Sources/MaintenanceTabView.swift`
- Modify: `App/Sources/Localizable.xcstrings`

**Interfaces:**
- Consumes: tâches 4 et 5 (dont `describe`).
- Produces: `MachineTab.maintenance`, raccourci ⌘9.

- [ ] **Step 1: Ajouter le cas d'enum et laisser le compilateur lister le travail**

Ajouter `case maintenance` après `updates` dans `MachineTab`. Le dépôt a fait le choix
délibéré de switches **exhaustifs sans `default:`** — précisément pour qu'un onglet ajouté ne
puisse pas se faufiler. Compiler et traiter chaque erreur :

Run: `swift build 2>&1 | grep -c "must be exhaustive"`
Expected: un compte non nul. Chaque site (`title`, `pendingMessage`, `fillsSheet`, `fullTab`, et le corps de `MachineDetailView`) doit répondre explicitement pour `.maintenance` :
- `title` → `"Maintenance"` (clé de catalogue) ;
- `pendingMessage` → `nil` (l'onglet est rempli) ;
- `fillsSheet` → `false` (il scrolle dans la feuille comme Summary).

- [ ] **Step 2: Écrire `MaintenanceTabView`**

Structure, de haut en bas :

1. **L'état**, rendu par `describe(state)`. Pour `.notDeployed`, un encart **neutre** — pas une pastille d'erreur : deux machines sur trois sont dans cet état, c'est l'écran le plus vu. Pastille + libellé texte : aucun état porté par la couleur seule (UX-DR7).
2. **Une carte par action servie**, filtrée par `caps.serves(_:)`. Le sélecteur de `docker-update` est peuplé par `GET /docker-services` — **jamais une liste codée en dur** : c'est le défaut connu de l'UI web du Pi, on ne le reproduit pas.
3. **La feuille de confirmation destructive** (UX-DR6), réutilisant le motif de `pendingAction` déjà présent dans `MachineDetailView`. Elle affiche `preview.detail.displayLines` — pour `apt-update`, la liste réelle des paquets. Un `.staleToken` au moment de valider affiche « prévisualisation expirée, relancer », **jamais** une erreur brute.
4. **La config Homeport en lecture seule**, depuis `GET /homeport-config/current` : le contenu de `services.yaml` dans un bloc monospace non éditable, avec la mention que l'écriture passe par `hpm config push`. Un 404 (fichier absent ou illisible) affiche « configuration Homeport introuvable », pas une erreur brute.
5. **L'historique** depuis `GET /audit` — borné à cette machine, il n'existe pas d'audit inter-machines.

- [ ] **Step 3: Localiser**

Ajouter chaque chaîne à `App/Sources/Localizable.xcstrings` en fr / en / zh-Hans. Vérifier qu'aucune chaîne littérale ne subsiste dans la vue :

Run: `grep -nE 'Text\("' App/Sources/MaintenanceTabView.swift`
Expected: aucune correspondance qui ne soit pas une clé de catalogue.

- [ ] **Step 4: Construire et vérifier**

Run: `swift test && Scripts/verify-app-build.sh; echo "rc=$?"`
Expected: PASS et `rc=0`. **Attention au piège du code de sortie dans un pipe** : `cmd | tail; echo $?` capture le code de `tail`, pas celui de `cmd`.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/MachineDetailView.swift App/Sources/MaintenanceTabView.swift App/Sources/Localizable.xcstrings
git commit -m "feat: add Maintenance tab driven by the HomePortExploit API"
```

---

### Task 7: Vérification de bout en bout, à travers le tailnet

**Files:** aucun. Cette tâche exécute contre la vraie machine.

**Prérequis :** plan jumeau terminé et déployé (`GET /capabilities` répond sur raspcorse).

- [ ] **Step 1: Déclarer le port dans `fleet.yaml`**

Ajouter `exploitPort: 8081` sous `raspcorse` dans `~/.config/hpm/fleet.yaml`. Ne rien ajouter aux deux autres machines — leur état `notDeployed` est précisément ce qu'on veut voir rendu.

- [ ] **Step 2: Les trois états réels, en une commande chacun**

```bash
.build/debug/hpm maintenance actions raspcorse    # attendu : available, 4 actions
.build/debug/hpm maintenance actions raspyellow   # attendu : notDeployed, sortie non nulle
.build/debug/hpm maintenance actions mba13m5      # attendu : notDeployed
```

- [ ] **Step 3: Le dry-run, en vrai**

```bash
.build/debug/hpm maintenance plan raspcorse apt-update
```

Expected: la liste réelle des paquets à mettre à jour sur raspcorse.

- [ ] **Step 4: L'onglet, dans la vraie app**

Ouvrir la console, sélectionner `raspcorse`, ⌘9 : les cartes d'action, le sélecteur Docker peuplé, l'historique rempli. Puis sélectionner `raspyellow` : l'encart neutre `notDeployed`, pas une erreur.

- [ ] **Step 5: L'exécution — seulement sur demande explicite de Vincent**

`hpm maintenance run` déclenche un vrai `apt upgrade` sur une machine de production. **Ne pas le lancer pour valider un test.** Le demander, et n'exécuter que sur un oui explicite.

- [ ] **Step 6: Consigner**

Mettre à jour `MEMORY.md`, `CHANGES.md` et `TODOS.md` des **deux** dépôts avec la sortie réelle, puis vérifier que les deux copies du contrat sont toujours identiques :

```bash
diff docs/api/homeportexploit-api-v1.md ../HomePortExploit/docs/api/homeportexploit-api-v1.md \
  && echo "contrat synchronisé"
```
