import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// The menu bar item: shows the current noise-control mode and lets you change it.
final class StatusBarController: NSObject, BudsLinkDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let link = BudsLink()
    private var hotKeyRef: EventHotKeyRef?

    /// The order the global shortcut steps through, mirroring the pinch gesture
    /// on the earbuds. Adaptive stays available from the menu.
    private let cycle: [NoiseMode] = [.anc, .ambient, .off]

    override init() {
        super.init()
        link.delegate = self
        item.menu = buildMenu()
        item.menu?.delegate = self
        render()
        link.start()
        registerHotKey()
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = link.status

        if link.isConnected {
            menu.addItem(header(link.deviceName ?? "Galaxy Buds"))
            menu.addItem(header(batteryLine(s)))
            menu.addItem(.separator())

            for mode in [NoiseMode.off, .adaptive, .ambient, .anc] {
                let mi = NSMenuItem(title: mode.title,
                                    action: #selector(pickMode(_:)),
                                    keyEquivalent: "")
                mi.target = self
                mi.representedObject = mode.rawValue
                mi.state = (s.mode == mode) ? .on : .off
                menu.addItem(mi)
            }

            menu.addItem(.separator())
            addAmbientControls(to: menu, status: s)
            menu.addItem(.separator())

            let vd = NSMenuItem(title: "Voice detect",
                               action: #selector(toggleVoiceDetect),
                               keyEquivalent: "")
            vd.target = self
            vd.state = s.detectConversations ? .on : .off
            vd.toolTip = "Switches to ambient sound automatically when you start talking"
            menu.addItem(vd)

            let find = NSMenuItem(title: "Ring earbuds", action: #selector(ring), keyEquivalent: "")
            find.target = self
            menu.addItem(find)
        } else {
            menu.addItem(header("Galaxy Buds not connected"))
            let retry = NSMenuItem(title: "Look for earbuds", action: #selector(retry), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }

        menu.addItem(.separator())
        menu.addItem(header("Cycle modes: ⌥⇧A"))

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Ambient loudness and timbre. Which sliders appear depends on whether the
    /// earbuds are set to a single level or a separate level per ear — the
    /// earbuds ignore one of the two while the other is in force, so showing
    /// both at once would let you drag a slider that does nothing.
    private func addAmbientControls(to menu: NSMenu, status s: BudsStatus) {
        if s.ambientCustomEnabled {
            menu.addItem(slider("Ambient left", s.ambientLeft, BudsStatus.ambientMax) { [weak self] v in
                guard let self else { return }
                let c = self.link.status
                self.link.setAmbientCustom(enabled: true, left: v, right: c.ambientRight, tone: c.ambientTone)
            })
            menu.addItem(slider("Ambient right", s.ambientRight, BudsStatus.ambientMax) { [weak self] v in
                guard let self else { return }
                let c = self.link.status
                self.link.setAmbientCustom(enabled: true, left: c.ambientLeft, right: v, tone: c.ambientTone)
            })
        } else {
            menu.addItem(slider("Ambient level", s.ambientVolume, BudsStatus.ambientMax) { [weak self] v in
                self?.link.setAmbientVolume(v)
            })
        }

        menu.addItem(slider("Ambient tone", s.ambientTone, BudsStatus.ambientToneMax) { [weak self] v in
            guard let self else { return }
            let c = self.link.status
            self.link.setAmbientCustom(enabled: c.ambientCustomEnabled,
                                       left: c.ambientLeft,
                                       right: c.ambientRight,
                                       tone: v)
        })

        let perEar = NSMenuItem(title: "Separate level per ear",
                                action: #selector(togglePerEar),
                                keyEquivalent: "")
        perEar.target = self
        perEar.state = s.ambientCustomEnabled ? .on : .off
        menu.addItem(perEar)
    }

    private func slider(_ title: String, _ value: Int, _ maximum: Int,
                        onChange: @escaping (Int) -> Void) -> NSMenuItem {
        let mi = NSMenuItem()
        mi.view = SliderRow(title: title, value: value, maximum: maximum, onChange: onChange)
        return mi
    }

    @objc private func togglePerEar() {
        let c = link.status
        let enabling = !c.ambientCustomEnabled
        // Carry the single level across when splitting, so the sound does not jump.
        let level = enabling ? c.ambientVolume : c.ambientLeft
        link.setAmbientCustom(enabled: enabling,
                              left: enabling ? level : c.ambientLeft,
                              right: enabling ? level : c.ambientRight,
                              tone: c.ambientTone)
        if !enabling { link.setAmbientVolume(c.ambientLeft) }
    }

    private func header(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func batteryLine(_ s: BudsStatus) -> String {
        var parts = ["L \(s.batteryLeft)% (\(s.placementLeft.label))",
                     "R \(s.batteryRight)% (\(s.placementRight.label))"]
        if s.batteryCase > 0 { parts.append("case \(s.batteryCase)%") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Actions

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? UInt8,
              let mode = NoiseMode(rawValue: raw) else { return }
        link.setMode(mode)
    }

    @objc private func toggleVoiceDetect() {
        link.setDetectConversations(!link.status.detectConversations)
    }

    @objc private func ring() {
        link.findMyEarbuds(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.link.findMyEarbuds(false) }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            budsLog("login item toggle failed: \(error)")
        }
    }

    @objc private func retry() {
        link.connectIfNeeded()
    }

    func cycleMode() {
        guard link.isConnected else { return }
        let next = cycle.firstIndex(of: link.status.mode).map { cycle[($0 + 1) % cycle.count] } ?? cycle[0]
        link.setMode(next)
    }

    // MARK: - Rendering

    private func render() {
        guard let button = item.button else { return }
        let s = link.status
        button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Galaxy Buds")
        button.image?.isTemplate = true
        button.title = link.isConnected ? " \(s.mode.short)" : ""
        button.appearsDisabled = !link.isConnected
    }

    // MARK: - Global shortcut (⌥⇧A)

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<StatusBarController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { controller.cycleMode() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let id = EventHotKeyID(signature: OSType(0x42554453), id: 1)  // 'BUDS'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_A),
                                         UInt32(optionKey | shiftKey),
                                         id,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotKeyRef)
        budsLog(status == noErr ? "registered hotkey ⌥⇧A" : "hotkey registration failed: \(status)")
    }

    // MARK: - BudsLinkDelegate

    func linkDidChangeConnection(_ link: BudsLink) { render() }
    func linkDidUpdateStatus(_ link: BudsLink) { render() }
}
