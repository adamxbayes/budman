import Foundation

/// Wire format for the Samsung Galaxy Buds SPP ("GEARMANAGER") protocol.
///
///     FD <len-lo> <len-hi> <msg-id> <payload…> <crc-lo> <crc-hi> DD
///
/// The 16-bit length field counts the message id, the payload and the CRC.
/// Bit 12 of that field marks a response, bit 13 marks a fragment.
enum Proto {
    static let som: UInt8 = 0xFD
    static let eom: UInt8 = 0xDD
    static let serviceUUID = UUID(uuidString: "2E73A4AD-332D-41FC-90E2-16BEF06523F2")!

    enum MsgID: UInt8 {
        case ack = 66                    // UNIVERSAL_MSG_ID_ACKNOWLEDGEMENT
        case statusUpdated = 96
        case extendedStatusUpdated = 97
        case noiseControlsUpdate = 119   // pushed when the mode changes on the earbuds
        case noiseControls = 120
        case setDetectConversations = 122
        case customizeAmbientSound = 130
        case ambientVolume = 132
        case managerInfo = 136
        case lockTouchpad = 144
        case findMyEarbudsStart = 160
        case findMyEarbudsStop = 161
    }

    // MARK: - CRC-16/CCITT-FALSE with a zero seed, as used by the earbuds.

    private static let crcTable: [UInt16] = (0..<256).map { i in
        var c = UInt16(i) << 8
        for _ in 0..<8 { c = (c & 0x8000) != 0 ? (c << 1) ^ 0x1021 : c << 1 }
        return c
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        bytes.reduce(UInt16(0)) { crc, b in
            crcTable[Int((crc >> 8) ^ UInt16(b)) & 0xFF] ^ (crc << 8)
        }
    }

    static func frame(_ id: MsgID, _ payload: [UInt8] = []) -> [UInt8] {
        let size = UInt16(1 + payload.count + 2)
        let crc = crc16([id.rawValue] + payload)
        return [som, UInt8(size & 0xFF), UInt8(size >> 8), id.rawValue]
            + payload
            + [UInt8(crc & 0xFF), UInt8(crc >> 8), eom]
    }

    struct Message {
        let id: UInt8
        let payload: [UInt8]
    }

    /// Pulls every complete, CRC-valid frame off the front of `buffer`,
    /// leaving any partial frame behind for the next chunk of data.
    static func drain(_ buffer: inout [UInt8]) -> [Message] {
        var out: [Message] = []
        while true {
            guard let start = buffer.firstIndex(of: som) else { buffer.removeAll(); return out }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 6 else { return out }

            let header = UInt16(buffer[1]) | (UInt16(buffer[2]) << 8)
            let size = Int(header & 0x3FF)
            let total = 3 + size + 1
            guard size >= 3 else { buffer.removeFirst(); continue }
            guard buffer.count >= total else { return out }
            guard buffer[total - 1] == eom else { buffer.removeFirst(); continue }

            let id = buffer[3]
            // `size` counts the message id, the payload and the two CRC bytes.
            let payload = Array(buffer[4..<(4 + size - 3)])
            let crc = UInt16(buffer[total - 3]) | (UInt16(buffer[total - 2]) << 8)
            if crc == crc16([id] + payload) {
                out.append(Message(id: id, payload: payload))
            }
            buffer.removeFirst(total)
        }
    }
}

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

enum Placement: UInt8 {
    case disconnected = 0, wearing = 1, idle = 2, inCase = 3, unknown = 255

    var label: String {
        switch self {
        case .wearing: return "in ear"
        case .idle: return "out"
        case .inCase: return "in case"
        case .disconnected: return "off"
        case .unknown: return "?"
        }
    }
}

/// The subset of the extended status message this app relies on. Every offset
/// below was confirmed against Buds3 Pro firmware R630XXU0AYJ1 (revision 4) by
/// changing the setting and re-reading the message.
struct BudsStatus {
    var batteryLeft: Int = 0
    var batteryRight: Int = 0
    var batteryCase: Int = 0
    var placementLeft: Placement = .unknown
    var placementRight: Placement = .unknown
    var mode: NoiseMode = .off
    var detectConversations = false

    /// Ambient sound loudness, 0…4. Applies when per-ear customisation is off.
    var ambientVolume = 0
    /// When on, the earbuds use `ambientLeft`/`ambientRight` instead of `ambientVolume`.
    var ambientCustomEnabled = false
    var ambientLeft = 0
    var ambientRight = 0
    /// Ambient timbre, 0 (softest) … 4 (clearest).
    var ambientTone = 0

    static let ambientMax = 4
    static let ambientToneMax = 4

    /// EXTENDED_STATUS_UPDATED (97) — sent unprompted right after connecting.
    static func fromExtended(_ p: [UInt8]) -> BudsStatus? {
        guard p.count >= 31 else { return nil }
        var s = BudsStatus()
        s.batteryLeft = Int(p[2])
        s.batteryRight = Int(p[3])
        s.placementLeft = Placement(rawValue: (p[6] & 0xF0) >> 4) ?? .unknown
        s.placementRight = Placement(rawValue: p[6] & 0x0F) ?? .unknown
        s.batteryCase = Int(p[7])
        s.mode = NoiseMode(rawValue: p[12]) ?? .off
        s.ambientVolume = Int(p[23])
        s.detectConversations = p[26] == 1
        s.ambientCustomEnabled = p[29] == 1
        s.ambientLeft = Int((p[30] & 0xF0) >> 4)
        s.ambientRight = Int(p[30] & 0x0F)
        if p.count > 36 { s.ambientTone = Int(p[36]) }
        return s
    }

    /// STATUS_UPDATED (96) — a lighter push sent when battery or wear state moves.
    mutating func applyStatusUpdate(_ p: [UInt8]) {
        guard p.count >= 7 else { return }
        batteryLeft = Int(p[1])
        batteryRight = Int(p[2])
        placementLeft = Placement(rawValue: (p[5] & 0xF0) >> 4) ?? .unknown
        placementRight = Placement(rawValue: p[5] & 0x0F) ?? .unknown
        batteryCase = Int(p[6])
    }
}
