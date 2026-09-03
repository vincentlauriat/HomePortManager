import XCTest
import ArgumentParser
@testable import hpm

/// `hpm machine add --exploit-port` (m2, revue finale) : jusqu'ici, `exploitPort` n'était
/// réglable qu'en éditant `fleet.yaml` à la main — la fonctionnalité de maintenance qu'il
/// déclenche restait inatteignable. Ces tests couvrent seulement le *parsing* de l'option,
/// via `ParsableCommand.parse(_:)`, jamais `run()` : `run()` écrit dans le vrai
/// `~/.config/hpm/fleet.yaml` de Vincent (`FleetStore()` sans chemin explicite), ce que la
/// consigne de revue interdit d'exécuter depuis ce correctif.
final class MachineCmdAddTests: XCTestCase {
    func testAddParsesExploitPort() throws {
        let cmd = try MachineCmd.Add.parse(["raspcorse", "--ssh", "raspcorse", "--exploit-port", "8081"])
        XCTAssertEqual(cmd.exploitPort, 8081)
        XCTAssertEqual(cmd.name, "raspcorse")
        XCTAssertEqual(cmd.ssh, "raspcorse")
    }

    /// Un ajout sans `--exploit-port` doit rester possible et rendre `nil` — la machine reste
    /// simplement hors du périmètre de maintenance, jamais une erreur (comportement `.notDeployed`
    /// déjà couvert côté kit).
    func testAddExploitPortDefaultsToNilWhenOmitted() throws {
        let cmd = try MachineCmd.Add.parse(["raspcorse", "--ssh", "raspcorse"])
        XCTAssertNil(cmd.exploitPort)
    }
}
