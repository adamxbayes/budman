import AppIntents
import SwiftUI
import WidgetKit

@main
struct BudsControls: WidgetBundle {
    var body: some Widget {
        NoiseControlButton()
        NoiseCancellingToggle()
        AmbientSoundToggle()
    }
}

// MARK: - State

/// What Control Center asks for before it draws a control: ask the app and
/// give it a moment to answer. No answer means the app is not running.
struct ModeProvider: ControlValueProvider {
    var previewValue: ControlBridge.State { .init(connected: true, mode: .anc) }

    func currentValue() async throws -> ControlBridge.State {
        await StateListener.shared.fetch()
    }
}

@MainActor
final class StateListener {
    static let shared = StateListener()

    private var latest: ControlBridge.State?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers = ControlBridge.observe(ControlBridge.allStateNames, ControlBridge.state(from:)) { [weak self] state in
            self?.latest = state
            self?.generation += 1
        }
    }

    func fetch() async -> ControlBridge.State {
        let before = generation
        ControlBridge.post(ControlBridge.name(for: .query))
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(40))
            if generation != before, let latest { return latest }
        }
        return latest ?? .disconnected
    }
}

private extension ControlBridge.State {
    var title: String { connected ? mode.title : "Not connected" }
}

// MARK: - Controls

/// One button that steps through the modes, mirroring the earbuds' pinch gesture.
struct NoiseControlButton: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.local.budscontrol.cycle", provider: ModeProvider()) { state in
            ControlWidgetButton(action: CycleModeIntent()) {
                Label(state.title, systemImage: "headphones")
            }
        }
        .displayName("Galaxy Buds noise control")
        .description("Cycles noise cancelling, ambient sound and off.")
    }
}

struct NoiseCancellingToggle: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.local.budscontrol.anc", provider: ModeProvider()) { state in
            ControlWidgetToggle(isOn: state.connected && state.mode == .anc,
                                action: SetNoiseCancellingIntent()) {
                Label("Noise cancelling", systemImage: "headphones.circle.fill")
            }
        }
        .displayName("Galaxy Buds noise cancelling")
        .description("Turns noise cancelling on or off.")
    }
}

struct AmbientSoundToggle: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.local.budscontrol.ambient", provider: ModeProvider()) { state in
            ControlWidgetToggle(isOn: state.connected && state.mode == .ambient,
                                action: SetAmbientSoundIntent()) {
                Label("Ambient sound", systemImage: "headphones.circle")
            }
        }
        .displayName("Galaxy Buds ambient sound")
        .description("Turns ambient sound on or off.")
    }
}

// MARK: - Intents
//
// These run inside the extension. They hand the request to the app, which owns
// the Bluetooth link, and the app republishes state once the earbuds confirm.

struct CycleModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Cycle noise control"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        ControlBridge.post(ControlBridge.name(for: .cycle))
        return .result()
    }
}

struct SetNoiseCancellingIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set noise cancelling"
    static let isDiscoverable = false

    @Parameter(title: "On")
    var value: Bool

    func perform() async throws -> some IntentResult {
        ControlBridge.post(ControlBridge.name(for: .setMode(value ? .anc : .off)))
        return .result()
    }
}

struct SetAmbientSoundIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set ambient sound"
    static let isDiscoverable = false

    @Parameter(title: "On")
    var value: Bool

    func perform() async throws -> some IntentResult {
        ControlBridge.post(ControlBridge.name(for: .setMode(value ? .ambient : .off)))
        return .result()
    }
}
