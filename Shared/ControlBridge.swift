import Foundation

/// The seam between the app and its Control Center extension.
///
/// The extension runs in its own sandboxed process and cannot touch the
/// Bluetooth channel, so the two sides talk over distributed notifications in
/// both directions. Everything is encoded in the notification *name*: a
/// sandboxed process may post a distributed notification, but macOS strips
/// the `userInfo` from it, and the name is the one field guaranteed to arrive.
/// Doing it this way also needs no entitlements, so the project builds with an
/// ad-hoc signature and no Apple developer account.
///
///     extension → app   …setMode.<mode>   …cycle   …query
///     app → extension   …state.<connected 0|1>.<mode>
enum ControlBridge {
    private static let prefix = "dev.local.budscontrol."

    struct State: Equatable {
        var connected: Bool
        var mode: NoiseMode
        static let disconnected = State(connected: false, mode: .off)
    }

    enum Command: Equatable {
        case setMode(NoiseMode)
        case cycle
        case query
    }

    // MARK: Wire format

    static func name(for command: Command) -> String {
        switch command {
        case .setMode(let mode): return prefix + "setMode.\(mode.rawValue)"
        case .cycle: return prefix + "cycle"
        case .query: return prefix + "query"
        }
    }

    static func name(for state: State) -> String {
        prefix + "state.\(state.connected ? 1 : 0).\(state.mode.rawValue)"
    }

    static func command(from name: String) -> Command? {
        guard name.hasPrefix(prefix) else { return nil }
        let parts = name.dropFirst(prefix.count).split(separator: ".")
        switch parts.first {
        case "cycle": return .cycle
        case "query": return .query
        case "setMode":
            guard parts.count == 2, let raw = UInt8(parts[1]), let mode = NoiseMode(rawValue: raw) else { return nil }
            return .setMode(mode)
        default: return nil
        }
    }

    static func state(from name: String) -> State? {
        guard name.hasPrefix(prefix) else { return nil }
        let parts = name.dropFirst(prefix.count).split(separator: ".")
        guard parts.count == 3, parts[0] == "state",
              let raw = UInt8(parts[2]), let mode = NoiseMode(rawValue: raw) else { return nil }
        return State(connected: parts[1] == "1", mode: mode)
    }

    // MARK: Transport

    static func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// The distributed notification centre only delivers names it has been
    /// asked for by name (a nil name is not a wildcard through the block API),
    /// so each side registers every name it understands. Both vocabularies are
    /// small and closed, which is what makes this workable.
    static var allCommandNames: [String] {
        NoiseMode.allCases.map { name(for: .setMode($0)) } + [name(for: .cycle), name(for: .query)]
    }

    static var allStateNames: [String] {
        NoiseMode.allCases.flatMap { mode in
            [name(for: State(connected: false, mode: mode)), name(for: State(connected: true, mode: mode))]
        }
    }

    static func observe<T>(_ names: [String],
                           _ parse: @escaping (String) -> T?,
                           _ handler: @escaping (T) -> Void) -> [NSObjectProtocol] {
        names.map { n in
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(n), object: nil, queue: .main) { note in
                if let value = parse(note.name.rawValue) { handler(value) }
            }
        }
    }
}
