import Foundation

/// The four noise-control states the Buds3 Pro exposes. Raw values are the
/// bytes the earbuds accept in a `noiseControls` message.
enum NoiseMode: UInt8, CaseIterable {
    case off = 0
    case anc = 1
    case ambient = 2
    case adaptive = 3

    var title: String {
        switch self {
        case .off: return "Off"
        case .anc: return "Noise cancelling"
        case .ambient: return "Ambient sound"
        case .adaptive: return "Adaptive"
        }
    }

    var short: String {
        switch self {
        case .off: return "OFF"
        case .anc: return "ANC"
        case .ambient: return "AMB"
        case .adaptive: return "ADP"
        }
    }
}
