import Foundation
import IOBluetooth

/// Set BUDSCTL_DEBUG=1 to trace connection and protocol activity on stderr.
func budsLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["BUDSCTL_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data(("[budsctl] " + message() + "\n").utf8))
}

protocol BudsLinkDelegate: AnyObject {
    func linkDidChangeConnection(_ link: BudsLink)
    func linkDidUpdateStatus(_ link: BudsLink)
}

/// Owns the RFCOMM channel to the earbuds: finds the paired device that
/// advertises the Galaxy Buds SPP service, keeps the channel open, decodes
/// incoming messages and sends commands.
final class BudsLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    weak var delegate: BudsLinkDelegate?

    private(set) var deviceName: String?
    private(set) var isConnected = false
    private(set) var status = BudsStatus()

    private var channel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private var inBuffer: [UInt8] = []
    private var retryTimer: Timer?
    private var connecting = false
    private var pending: [IOBluetoothDevice] = []

    /// Polls for the earbuds and reconnects whenever the link is down. Cheap
    /// enough to run forever: it is a no-op unless the device is in range.
    func start() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.connectIfNeeded()
        }
        connectIfNeeded()
    }

    func connectIfNeeded() {
        guard !isConnected, !connecting else { return }
        connecting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let candidates = self?.budsCandidates() ?? []
            DispatchQueue.main.async {
                self?.pending = candidates
                self?.openNextCandidate()
            }
        }
    }

    /// Paired devices advertising the Galaxy Buds SPP service, most likely first.
    /// Matching on the service UUID rather than the device name means every
    /// Galaxy Buds model is picked up, not just the Buds3 Pro.
    ///
    /// `isConnected()` only influences the ordering: it reports false for an
    /// idle-but-reachable earbud, so it cannot be used to rule one out.
    private func budsCandidates() -> [IOBluetoothDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            budsLog("pairedDevices() returned nil - is Bluetooth permission granted?")
            return []
        }
        for dev in paired { _ = dev.performSDPQuery(nil) }
        // performSDPQuery is asynchronous; give the service records a moment to land.
        Thread.sleep(forTimeInterval: 1.5)

        var seen = Set<String>()
        let matches = paired.filter { dev in
            guard Self.serviceRecord(on: dev) != nil else { return false }
            return seen.insert(dev.addressString ?? UUID().uuidString).inserted
        }
        budsLog("candidates: " + matches.map { $0.name ?? "?" }.joined(separator: ", "))
        return matches.sorted { $0.isConnected() && !$1.isConnected() }
    }

    private static func serviceRecord(on dev: IOBluetoothDevice) -> IOBluetoothSDPServiceRecord? {
        var bytes = Proto.serviceUUID.uuid
        let sdpUUID = withUnsafeBytes(of: &bytes) { IOBluetoothSDPUUID(bytes: $0.baseAddress!, length: 16) }
        return dev.getServiceRecord(for: sdpUUID)
    }

    /// Opens the next candidate. The open is asynchronous because IOBluetooth
    /// delivers its result through the run loop of the calling thread, and only
    /// the main thread is guaranteed to have one.
    private func openNextCandidate() {
        guard !pending.isEmpty else {
            budsLog("no reachable earbuds advertising the SPP service")
            connecting = false
            return
        }
        let dev = pending.removeFirst()
        guard let record = Self.serviceRecord(on: dev) else { return openNextCandidate() }

        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { return openNextCandidate() }

        var chan: IOBluetoothRFCOMMChannel?
        let result = dev.openRFCOMMChannelAsync(&chan, withChannelID: channelID, delegate: self)
        guard result == kIOReturnSuccess, let chan else {
            budsLog("open on channel \(channelID) failed immediately: \(result)")
            return openNextCandidate()
        }
        budsLog("opening RFCOMM channel \(channelID) on \(dev.name ?? "?")")
        device = dev
        channel = chan
    }

    func disconnect() {
        channel?.close()
        teardown()
    }

    private func teardown() {
        guard isConnected || channel != nil else { return }
        channel = nil
        device = nil
        isConnected = false
        status = BudsStatus()
        delegate?.linkDidChangeConnection(self)
    }

    // MARK: - Commands

    func send(_ id: Proto.MsgID, _ payload: [UInt8] = []) {
        guard let channel else { return }
        var bytes = Proto.frame(id, payload)
        _ = channel.writeAsync(&bytes, length: UInt16(bytes.count), refcon: nil)
    }

    func setMode(_ mode: NoiseMode) {
        send(.noiseControls, [mode.rawValue])
        status.mode = mode                       // optimistic; the ack confirms it
        delegate?.linkDidUpdateStatus(self)
    }

    /// Ambient loudness when per-ear customisation is off. The earbuds accept
    /// any byte here without validating it, so the clamp has to happen here.
    func setAmbientVolume(_ level: Int) {
        let v = min(max(level, 0), BudsStatus.ambientMax)
        send(.ambientVolume, [UInt8(v)])
        status.ambientVolume = v
        delegate?.linkDidUpdateStatus(self)
    }

    /// Per-ear ambient levels and timbre. Unlike the volume message, the
    /// earbuds reject this one outright if any component exceeds 4.
    func setAmbientCustom(enabled: Bool, left: Int, right: Int, tone: Int) {
        let l = min(max(left, 0), BudsStatus.ambientMax)
        let r = min(max(right, 0), BudsStatus.ambientMax)
        let t = min(max(tone, 0), BudsStatus.ambientToneMax)
        send(.customizeAmbientSound, [enabled ? 1 : 0, UInt8(l), UInt8(r), UInt8(t)])
        status.ambientCustomEnabled = enabled
        status.ambientLeft = l
        status.ambientRight = r
        status.ambientTone = t
        delegate?.linkDidUpdateStatus(self)
    }

    func setDetectConversations(_ on: Bool) {
        send(.setDetectConversations, [on ? 1 : 0])
        status.detectConversations = on
        delegate?.linkDidUpdateStatus(self)
    }

    func findMyEarbuds(_ on: Bool) {
        send(on ? .findMyEarbudsStart : .findMyEarbudsStop)
    }

    // MARK: - IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!,
                           length: Int) {
        let chunk = UnsafeBufferPointer(start: dataPointer.assumingMemoryBound(to: UInt8.self), count: length)
        inBuffer.append(contentsOf: chunk)
        budsLog("rx chunk: " + chunk.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ") + " (\(length) bytes)")
        var changed = false
        let msgs = Proto.drain(&inBuffer)
        budsLog("decoded \(msgs.count) message(s): " + msgs.map { "\($0.id)/\($0.payload.count)" }.joined(separator: ", "))
        for msg in msgs where handle(msg) { changed = true }
        if changed { delegate?.linkDidUpdateStatus(self) }
    }

    func rfcommChannelOpenComplete(_ chan: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess else {
            budsLog("open failed: \(error)")
            channel = nil
            device = nil
            openNextCandidate()
            return
        }
        connecting = false
        pending.removeAll()
        isConnected = true
        deviceName = device?.name
        inBuffer.removeAll()
        budsLog("connected to \(deviceName ?? "?")")
        delegate?.linkDidChangeConnection(self)
        // Identifying ourselves prompts the earbuds to push their full status.
        send(.managerInfo, [1, 1, 34])
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        budsLog("channel closed")
        teardown()
    }

    private func handle(_ msg: Proto.Message) -> Bool {
        switch Proto.MsgID(rawValue: msg.id) {
        case .extendedStatusUpdated:
            guard let s = BudsStatus.fromExtended(msg.payload) else { return false }
            status = s
            budsLog("status: mode=\(s.mode) L=\(s.batteryLeft)% R=\(s.batteryRight)% case=\(s.batteryCase)% voiceDetect=\(s.detectConversations)")
            return true
        case .statusUpdated:
            status.applyStatusUpdate(msg.payload)
            return true
        case .noiseControlsUpdate:
            guard let m = msg.payload.first.flatMap({ NoiseMode(rawValue: $0) }) else { return false }
            status.mode = m
            return true
        case .ack:
            // payload: [message id being acknowledged, value]
            guard msg.payload.count >= 2 else { return false }
            switch Proto.MsgID(rawValue: msg.payload[0]) {
            case .noiseControls:
                guard let m = NoiseMode(rawValue: msg.payload[1]) else { return false }
                budsLog("earbuds acknowledged mode \(m)")
                status.mode = m
                return true
            case .setDetectConversations:
                status.detectConversations = msg.payload[1] == 1
                return true
            case .ambientVolume:
                status.ambientVolume = Int(msg.payload[1])
                return true
            case .customizeAmbientSound:
                guard msg.payload.count >= 5 else { return false }
                status.ambientCustomEnabled = msg.payload[1] == 1
                status.ambientLeft = Int(msg.payload[2])
                status.ambientRight = Int(msg.payload[3])
                status.ambientTone = Int(msg.payload[4])
                return true
            default:
                return false
            }
        default:
            return false
        }
    }
}
