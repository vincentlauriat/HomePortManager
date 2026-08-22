import ArgumentParser
import HomePortKit

@main
struct HPM: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hpm",
        abstract: "Manage the life cycle of Homeport instances."
    )
}
