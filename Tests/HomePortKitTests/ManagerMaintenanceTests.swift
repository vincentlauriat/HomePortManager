import XCTest
import SQLite3
@testable import HomePortKit

/// Couvre les quatre actions de maintenance déléguées à HomePortExploit vues depuis le
/// journal de flotte et le verrou par machine (AD-12/AD-16) : ce que la surcharge `async`
/// de `journaled` doit préserver du chemin synchrone, et rien de plus.
///
/// Aucune requête réseau : la couture `fetch` du client est bouchonnée dans chaque test,
/// et le manager par défaut de `makeTestManager` refuse tout appel exploit.
final class ManagerMaintenanceTests: XCTestCase {
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse", port: 80, exploitPort: 8081)
    /// Sans `exploitPort`, `endpoint(...)` rend `nil` : aucune requête ne part.
    private let bare = Machine(name: "raspyellow", ssh: "raspyellow")
    private var root: String!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "hpm-maintenance-\(UUID().uuidString)"
        dbPath = root + "/hpm.db"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    /// Les requêtes vues par la couture bouchonnée. Une classe parce que le corps `async`
    /// du seam les enregistre depuis la closure : un `var` capturé ne se relit pas.
    private final class FetchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []

        func record(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
        }

        var all: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }
    }

    /// Une barrière à usage unique. L'attente se fait sur une file globale et jamais sur un
    /// thread coopératif : le bloquer figerait la tâche qu'on cherche justement à faire
    /// avancer.
    private final class Signal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func fire() { semaphore.signal() }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.semaphore.wait()
                    continuation.resume()
                }
            }
        }
    }

    private func ok(_ json: String) -> HTTPReply { HTTPReply(status: 200, body: Data(json.utf8)) }

    private let planJSON = #"{"ok": true, "message": "12 paquets à mettre à jour", "plan_id": "abc"}"#
    private let runJSON = #"{"ok": true, "message": "12 paquets mis à jour"}"#

    /// Un manager câblé sur une couture qui journalise ses requêtes et rend `reply`.
    private func makeManager(historyPath: String?, log: FetchLog = FetchLog(),
                             reply: @escaping (URLRequest) async throws -> HTTPReply)
        -> (HomeportManager, FetchLog) {
        let exploit = ExploitAPIClient(fetch: { request in
            log.record(request)
            return try await reply(request)
        })
        return (makeTestManager(mock: MockProcessRunner(), historyPath: historyPath, exploit: exploit), log)
    }

    // MARK: - Verrou

    /// Le dry-run d'`apt-update` lance `sudo apt-get update` sur le Pi : il écrit les listes
    /// de paquets et prend les verrous d'apt. Ce n'est pas une lecture, et il doit verrouiller.
    func testPlanIsRefusedUnderAForeignLockBecauseDryRunWritesOnThePi() async throws {
        let (manager, log) = makeManager(historyPath: dbPath) { _ in
            XCTFail("le corps refusé ne doit pas partir sur le réseau")
            return HTTPReply(status: 200, body: Data())
        }
        // Un autre « processus » (un second store, le PID vivant de celui-ci) tient la machine.
        let holder = try HistoryStore(path: dbPath)
        try holder.acquireLock(machine: "raspcorse", pid: getpid())

        do {
            _ = try await manager.maintenancePlan(.aptUpdate, on: machine)
            XCTFail("le verrou tenu ailleurs doit refuser l'opération")
        } catch is LockContentionError {
            // attendu
        }
        XCTAssertTrue(log.all.isEmpty, "le corps refusé n'a pas dû s'exécuter")
        XCTAssertEqual(try holder.tasks().count, 0, "un refus n'est jamais journalisé")
        XCTAssertEqual(try holder.currentLock(machine: "raspcorse")?.pid, getpid())
    }

    func testRunIsRefusedUnderAForeignLock() async throws {
        let (manager, log) = makeManager(historyPath: dbPath) { _ in
            XCTFail("le corps refusé ne doit pas partir sur le réseau")
            return HTTPReply(status: 200, body: Data())
        }
        let holder = try HistoryStore(path: dbPath)
        try holder.acquireLock(machine: "raspcorse", pid: getpid())

        do {
            _ = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: machine)
            XCTFail("le verrou tenu ailleurs doit refuser l'opération")
        } catch is LockContentionError {
            // attendu
        }
        XCTAssertTrue(log.all.isEmpty)
        XCTAssertEqual(try holder.tasks().count, 0)
    }

    /// AD-16 : les deux lectures restent libres et parallèles — elles passent une machine
    /// tenue par un autre et laissent son verrou exactement comme elles l'ont trouvé.
    func testReadsNeitherLockNorJournal() async throws {
        let (manager, log) = makeManager(historyPath: dbPath) { request in
            if request.url?.path == "/capabilities" {
                return self.ok(#"{"contract": "1.0.0", "server": "0.2.0", "actions": ["apt-update"]}"#)
            }
            return self.ok("[]")
        }
        let holder = try HistoryStore(path: dbPath)
        let acquiredAt = Date(timeIntervalSince1970: 1_755_945_600)
        try holder.acquireLock(machine: "raspcorse", pid: getpid(), now: acquiredAt)

        _ = await manager.maintenanceCapabilities(of: machine)
        _ = await manager.maintenanceAudit(of: machine, limit: 10)

        XCTAssertEqual(log.all.count, 2, "les deux lectures ont bien atteint la couture")
        let lock = try XCTUnwrap(holder.currentLock(machine: "raspcorse"))
        XCTAssertEqual(lock.pid, getpid())
        XCTAssertEqual(lock.acquiredAt, acquiredAt, "une lecture ne touche pas le verrou")
        // `capabilities` est un sondage par visite d'onglet : le journaliser le noierait.
        XCTAssertEqual(try holder.tasks().count, 0, "les lectures ne journalisent pas")
    }

    func testSuccessfulRunReleasesTheLock() async throws {
        let (manager, _) = makeManager(historyPath: dbPath) { _ in self.ok(self.runJSON) }
        _ = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: machine)
        XCTAssertNil(try XCTUnwrap(manager.history).currentLock(machine: "raspcorse"))
    }

    /// L'exigence n° 1 de la surcharge `async` : la libération est bornée à l'acquisition
    /// exacte (machine, pid, `acquired_at`). Si un autre processus reprend le verrou
    /// pendant le corps — ici depuis la couture réseau, qui *est* le point de suspension —
    /// le `defer` tardif ne doit pas libérer le verrou du repreneur.
    func testLateReleaseDoesNotFreeALockReacquiredDuringTheBody() async throws {
        let path = try XCTUnwrap(dbPath)
        let (manager, _) = makeManager(historyPath: path) { _ in
            // Un repreneur dont la sonde voit tout détenteur mort reprend en plein corps.
            let taker = try? HistoryStore(path: path, isProcessAlive: { _ in false })
            try? taker?.acquireLock(machine: "raspcorse", pid: 99_999)
            return self.ok(self.runJSON)
        }

        _ = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: machine)

        let observer = try HistoryStore(path: path)
        XCTAssertEqual(try observer.currentLock(machine: "raspcorse")?.pid, 99_999,
                       "la libération tardive doit laisser intact le verrou repris entre-temps")
        // Le repreneur a clos l'orphelin : le `finish` tardif du détenteur dégrade en
        // avertissement et ne réécrit pas le verdict.
        XCTAssertEqual(try observer.tasks().first?.status, .interrupted)
    }

    /// La garde de réentrance portée sur le chemin `async` : une action de maintenance
    /// imbriquée dans une action journalisée ne rouvre ni entrée ni verrou. C'est aussi la
    /// seule preuve empirique que `enter()` et le `defer { exit() }` s'apparient malgré le
    /// point de suspension — une garde cassée se voit soit en seconde entrée, soit en
    /// auto-contention.
    func testNestedMaintenanceActionJournalsAndLocksOnlyOnce() async throws {
        let (manager, log) = makeManager(historyPath: dbPath) { _ in self.ok(self.runJSON) }

        try await manager.journaled("outer", on: machine, locking: true) {
            _ = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: self.machine)
        }

        XCTAssertEqual(log.all.count, 1, "le corps imbriqué a bien tourné")
        let history = try XCTUnwrap(manager.history)
        XCTAssertEqual(try history.tasks().map(\.action), ["outer"],
                       "l'action imbriquée ne journalise pas la sienne")
        XCTAssertNil(try history.currentLock(machine: "raspcorse"),
                     "une seule acquisition, une seule libération")
    }

    /// L'autre sens de l'imbrication, et la raison pour laquelle la surcharge `async`
    /// incrémente **aussi** le compteur du manager : une action **synchrone** imbriquée dans
    /// un corps `async` doit composer, pas ouvrir sa propre entrée. Sans cet incrément elle
    /// redemanderait le verrou que l'action englobante tient déjà — auto-contention.
    func testSynchronousActionNestedInAnAsyncOneComposes() async throws {
        let (manager, _) = makeManager(historyPath: dbPath) { _ in self.ok(self.runJSON) }

        try await manager.journaled("outer", on: machine, locking: true) {
            // Sans cette suspension, le corps est synchrone et Swift choisit l'AUTRE
            // surcharge : le test ne dirait alors rien du seam `async`.
            await Task.yield()
            _ = try manager.backup(on: self.machine)
        }

        let history = try XCTUnwrap(manager.history)
        XCTAssertEqual(try history.tasks().map(\.action), ["outer"],
                       "le backup imbriqué ne journalise pas la sienne")
        XCTAssertNil(try history.currentLock(machine: "raspcorse"),
                     "une seule acquisition, une seule libération")
    }

    /// L'autre moitié de la doctrine : seule la contention refuse. Une base vivante dont la
    /// mécanique de verrou casse en vol dégrade exactement comme le journal — un
    /// avertissement, et l'action tourne sans verrou.
    func testLockMachineryFailureDegradesWithoutBlockingTheAction() async throws {
        let (manager, log) = makeManager(historyPath: dbPath) { _ in self.ok(self.runJSON) }
        var saboteur: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &saboteur), SQLITE_OK)
        defer { sqlite3_close_v2(saboteur) }
        XCTAssertEqual(sqlite3_exec(saboteur, "DROP TABLE locks;", nil, nil, nil), SQLITE_OK)

        _ = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: machine)

        XCTAssertEqual(log.all.count, 1, "l'action doit tourner malgré la mécanique cassée")
        // Le journal, lui, est intact et adopte l'action.
        XCTAssertEqual(try XCTUnwrap(manager.history).tasks().map(\.status), [.success])
    }

    // MARK: - Journal

    func testPlanAndRunLandUnderTheirOwnIdentifiers() async throws {
        let (manager, _) = makeManager(historyPath: dbPath) { request in
            request.url?.path.hasSuffix("/dry-run") == true ? self.ok(self.planJSON) : self.ok(self.runJSON)
        }

        _ = try await manager.maintenancePlan(.aptUpdate, on: machine)
        _ = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: machine)

        let entries = try XCTUnwrap(manager.history).tasks()
        XCTAssertEqual(entries.map(\.action), ["maintenance-run", "maintenance-plan"])
        XCTAssertTrue(entries.allSatisfy { $0.machine == "raspcorse" && $0.status == .success }, "\(entries)")
        XCTAssertTrue(entries.allSatisfy { $0.finishedAt != nil }, "les entrées doivent être closes")
    }

    /// Le corps délégué ne parle pas de lui-même : sans la ligne de compte rendu émise par
    /// `Manager+Maintenance`, l'entrée se fermerait avec un `output` vide — une
    /// historisation qui n'historise rien.
    func testJournalEntryCarriesTheDelegatedOutcome() async throws {
        let (manager, _) = makeManager(historyPath: dbPath) { _ in self.ok(self.runJSON) }
        _ = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: machine)

        let entry = try XCTUnwrap(try XCTUnwrap(manager.history).tasks().first)
        XCTAssertTrue(entry.output.contains("apt-update"), entry.output)
        XCTAssertTrue(entry.output.contains("12 paquets mis à jour"), entry.output)
    }

    /// Aucun échec du contrat n'est une erreur : une machine sans `exploitPort` rend
    /// `.unavailable(.notDeployed)` comme une valeur — l'appelant reçoit un `outcome`, rien
    /// ne lance. Mais le journal, lui, doit dire la vérité : l'entrée se clôt en `.failure`.
    func testUnavailableOutcomeIsAValueAndJournalsAFailure() async throws {
        let (manager, log) = makeManager(historyPath: dbPath) { _ in
            XCTFail("aucune requête sans exploitPort")
            return HTTPReply(status: 200, body: Data())
        }

        let outcome = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: bare)
        XCTAssertEqual(outcome, .unavailable(.notDeployed))
        XCTAssertTrue(log.all.isEmpty)

        let entry = try XCTUnwrap(try XCTUnwrap(manager.history).tasks().first)
        XCTAssertEqual(entry.action, "maintenance-run")
        XCTAssertEqual(entry.machine, "raspyellow")
        XCTAssertEqual(entry.status, .failure,
                       "une coche sur une action qui n'a pas eu lieu serait pire qu'aucune entrée")
        XCTAssertNotNil(entry.finishedAt)
        // I1 (revue finale) : avant le correctif, cette assertion pinnait la réflexion Swift
        // brute (`unavailable(notDeployed)`) que `summary(of:)` interpolait — exactement le
        // défaut que le correctif supprime. `entry.output` doit désormais porter la phrase de
        // `describe(_:)`, jamais le nom du cas.
        XCTAssertTrue(entry.output.contains("pas déployé"), entry.output)
        XCTAssertFalse(entry.output.contains("notDeployed"), entry.output)
        XCTAssertFalse(entry.output.contains("ExploitAvailability"), entry.output)
    }

    /// Les deux autres verdicts négatifs que le serveur peut rendre sans que rien ne lance :
    /// un jeton de plan brûlé (409) et une action qui a bien tourné mais a échoué.
    func testRefusedTokenAndFailedResultBothJournalAFailure() async throws {
        let (manager, _) = makeManager(historyPath: dbPath) { request in
            request.url?.path.hasSuffix("/dry-run") == true
                ? HTTPReply(status: 409, body: Data())
                : self.ok(#"{"ok": false, "message": "dpkg est verrouillé"}"#)
        }

        let plan = try await manager.maintenancePlan(.aptUpdate, on: machine)
        XCTAssertEqual(plan, .staleToken)
        let run = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: machine)
        XCTAssertEqual(run, .completed(ExploitResult(ok: false, message: "dpkg est verrouillé",
                                                      detail: [:], planID: nil)))

        let entries = try XCTUnwrap(manager.history).tasks()
        XCTAssertEqual(entries.map(\.action), ["maintenance-run", "maintenance-plan"])
        XCTAssertTrue(entries.allSatisfy { $0.status == .failure }, "\(entries.map(\.status))")
        // Et le verrou est bien rendu dans les deux cas.
        XCTAssertNil(try XCTUnwrap(manager.history).currentLock(machine: "raspcorse"))
    }

    /// La conséquence assumée de la profondeur `@TaskLocal` : deux plans concurrents sur la
    /// **même** machine ne sont plus deux compositions imaginaires — ce sont deux actions,
    /// et elles se disputent le verrou. Deux `apt-get update` simultanés sur un Pi, c'est
    /// exactement ce qu'AD-12 existe pour empêcher.
    ///
    /// Avec la profondeur partagée d'avant, le second se serait exécuté **nu** : ni entrée
    /// au journal, ni verrou, et sans un mot.
    func testConcurrentPlansOnTheSameMachineContendForTheLock() async throws {
        let inFlight = Signal(), proceed = Signal()
        let (manager, log) = makeManager(historyPath: dbPath) { _ in
            inFlight.fire()
            await proceed.wait()
            return self.ok(self.planJSON)
        }

        // Le premier plan part dans sa propre tâche et se suspend dans son corps, verrou tenu.
        async let first = manager.maintenancePlan(.aptUpdate, on: machine)
        await inFlight.wait()

        do {
            _ = try await manager.maintenancePlan(.aptUpdate, on: machine)
            XCTFail("le second plan concurrent doit se heurter au verrou du premier")
        } catch is LockContentionError {
            // attendu
        }

        proceed.fire()
        let outcome = try await first
        guard case .completed(let result) = outcome else { return XCTFail("attendu un plan abouti") }
        XCTAssertEqual(result.planID, "abc")

        XCTAssertEqual(log.all.count, 1, "seul le premier plan a atteint le réseau")
        let entries = try XCTUnwrap(manager.history).tasks()
        XCTAssertEqual(entries.map(\.action), ["maintenance-plan"], "le refus ne journalise pas")
        XCTAssertEqual(entries.first?.status, .success)
        XCTAssertNil(try XCTUnwrap(manager.history).currentLock(machine: "raspcorse"))
    }

    /// La doctrine 1.2 étendue au chemin `async` : pas de base utilisable, donc ni journal
    /// ni verrou ni refus — l'action passe telle quelle.
    func testHistoryNilMeansNoLockNoJournalAndNoRefusal() async throws {
        let (manager, log) = makeManager(historyPath: nil) { _ in self.ok(self.runJSON) }
        _ = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: machine)
        _ = try await manager.maintenanceRun(.aptUpdate, planID: "abc", on: machine)

        XCTAssertNil(manager.history)
        XCTAssertEqual(log.all.count, 2, "les deux exécutions ont bien eu lieu")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath))
    }

    // MARK: - Contrat réseau

    /// Le seam ne doit rien changer à ce que la tâche 3 envoie : le `plan_id` voyage à plat
    /// dans le corps du `POST`, à côté des paramètres.
    func testRunPostsThePlanTokenFlatBesideTheParameters() async throws {
        let (manager, log) = makeManager(historyPath: dbPath) { _ in self.ok(self.runJSON) }
        _ = try await manager.maintenanceRun(.reboot(mode: .poweroff), planID: "tok-1", on: machine)

        let request = try XCTUnwrap(log.all.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://raspcorse:8081/actions/reboot/execute")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["mode": "poweroff", "plan_id": "tok-1"])
    }

    // MARK: - describe

    /// Le rendu des états est la seule partie testable sans process : `describe(_:)` est
    /// partagée par `hpm maintenance` et l'onglet SwiftUI, donc chaque état doit se
    /// distinguer par sa propre cause dans le texte, pas seulement par sa forme.
    func testEachStateRendersItsOwnCause() {
        XCTAssertTrue(describe(.notDeployed).contains("pas déployé"))
        XCTAssertTrue(describe(.forbidden).contains("admin"))
        XCTAssertTrue(describe(.unavailable(.notServed)).contains("trop ancien"))
        XCTAssertTrue(describe(.unavailable(.outOfRange("2.0.0"))).contains("2.0.0"))
        // Le piège qui a coûté une demi-journée au déploiement initial : un timeout est
        // indiscernable d'une panne machine si le message ne nomme pas l'ACL.
        XCTAssertTrue(describe(.unreachable("timed out")).contains("ACL Tailscale"))
    }

    /// C1 (revue finale) : le pendant honnête de `.unreachable` — une réponse EST arrivée, donc
    /// le message ne doit jamais reprendre les trois causes que sa seule réception réfute
    /// (machine éteinte, service arrêté, ACL absente).
    func testUnexpectedResponseNeverInventsMachineOffCauses() {
        let message = describe(.unexpectedResponse("HTTP 500"))
        XCTAssertTrue(message.contains("500"), message)
        XCTAssertFalse(message.contains("éteinte"), message)
        XCTAssertFalse(message.contains("arrêté"), message)
        XCTAssertFalse(message.contains("ACL"), message)
    }

    /// I1 (revue finale) : `summary(of:)` n'avait aucun test avant ce correctif (m4). Doit
    /// passer par `describe(_:)`, jamais interpoler `ExploitAvailability` brut — la réflexion
    /// Swift (`unavailable(unreachable("…"))`) finirait sinon imprimée par le CLI et écrite en
    /// dur dans `hpm.db`.
    func testSummaryOfUnavailableUsesDescribeNotRawReflection() {
        let summary = HomeportManager.summary(of: .unavailable(.notDeployed))
        XCTAssertTrue(summary.contains("pas déployé"), summary)
        XCTAssertFalse(summary.contains("ExploitAvailability"), summary)
        XCTAssertFalse(summary.contains("notDeployed"), summary)
    }

    func testSummaryOfCompletedFailureCarriesTheServerMessage() {
        let result = ExploitResult(ok: false, message: "dpkg est verrouillé", detail: [:], planID: nil)
        XCTAssertEqual(HomeportManager.summary(of: .completed(result)), "échec — dpkg est verrouillé")
    }

    /// `.cancelled` n'est pas dans le tableau du brief — un simple switch exhaustif oblige
    /// à le rendre malgré tout, et il ne doit jamais se lire comme une panne de la machine
    /// (c'est la tâche appelante qui a disparu, pas le Pi).
    func testCancelledIsNeverPhrasedAsAMachineFailure() {
        let message = describe(.cancelled)
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.lowercased().contains("injoignable"))
        XCTAssertFalse(message.lowercased().contains("panne"))
    }

    func testAvailableNamesTheServerAndItsActions() {
        let caps = ExploitCapabilities(contract: SemanticVersion(1, 0, 0), server: "0.2.0",
                                       actions: ["apt-update", "reboot"])
        let message = describe(.available(caps))
        XCTAssertTrue(message.contains("0.2.0"))
        XCTAssertTrue(message.contains("apt-update"))
        XCTAssertTrue(message.contains("reboot"))
    }

    /// Les deux raisons d'`.unavailable` se réparent différemment (déployer vs. mettre à
    /// jour) : leurs messages ne doivent jamais se confondre l'un avec l'autre.
    func testNotServedAndOutOfRangeStayDistinguishable() {
        let notServed = describe(.unavailable(.notServed))
        let outOfRange = describe(.unavailable(.outOfRange("2.0.0")))
        XCTAssertNotEqual(notServed, outOfRange)
        XCTAssertFalse(notServed.contains("2.0.0"))
    }
}
