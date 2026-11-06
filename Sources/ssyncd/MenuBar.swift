import AppKit

/// Speaker icon in the macOS menu bar: shows whether the speakers are
/// connected and playing, and offers the common actions. The web UI stays the
/// full control surface; this only reads `Controller.state()` and calls the
/// same methods the API does.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private let controller: Controller
    private let port: Int
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?

    init(controller: Controller, port: Int) {
        self.controller = controller
        self.port = port
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refreshIcon()
        // Speakers connect and disconnect on their own; keep the icon current.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }
    }

    private enum Look { case playing, ready, missing, off }

    private func look(_ s: Controller.State) -> Look {
        if s.outputs.isEmpty { return .off }
        if s.outputs.contains(where: { $0.matchedBy == .missing }) || s.status == "error" { return .missing }
        return s.status == "playing" ? .playing : .ready
    }

    private func refreshIcon() {
        let s = controller.state()
        let (symbol, tip): (String, String)
        switch look(s) {
        case .playing: (symbol, tip) = ("hifispeaker.2.fill", "Speaker Sync: playing on \(s.outputs.count) speakers")
        case .ready: (symbol, tip) = ("hifispeaker.2", "Speaker Sync: \(s.outputs.count) speakers connected")
        case .missing: (symbol, tip) = ("exclamationmark.triangle", "Speaker Sync: a speaker is not connected")
        case .off: (symbol, tip) = ("speaker.slash", "Speaker Sync: no speakers selected")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = tip
    }

    // Built when opened, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = controller.state()
        menu.removeAllItems()

        let statusText: String
        switch s.status {
        case "playing": statusText = "Playing"
        case "paused": statusText = "Paused"
        case "ended": statusText = "Ended"
        case "loading": statusText = "Connecting…"
        case "noOutputs": statusText = "No speakers selected"
        default: statusText = s.error ?? "Not active"
        }
        menu.addItem(info("Speaker Sync: \(statusText)", bold: true))
        if !s.outputs.isEmpty { menu.addItem(info(s.source.name)) }

        if !s.outputs.isEmpty {
            menu.addItem(.separator())
            for o in s.outputs {
                let connected = o.matchedBy != .missing
                let row = info(connected ? o.name : "\(o.name) (not connected)")
                row.image = NSImage(systemSymbolName: connected ? "checkmark.circle.fill" : "xmark.circle",
                                    accessibilityDescription: connected ? "connected" : "not connected")
                menu.addItem(row)
            }
            menu.addItem(.separator())
            let playing = s.status == "playing"
            menu.addItem(action(playing ? "Pause" : "Play", #selector(togglePlay), enabled: s.status != "loading"))
            menu.addItem(action("Stop", #selector(stop), enabled: s.status == "playing" || s.status == "paused"))
            menu.addItem(action("Reconnect speakers", #selector(reconnect)))
        }

        menu.addItem(.separator())
        menu.addItem(action("Open Speaker Sync", #selector(openUI)))
        menu.addItem(action("Copy iPhone pairing link", #selector(copyLink), enabled: !lanAddresses().isEmpty))
    }

    private func info(_ title: String, bold: Bool = false) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.isEnabled = false
        if bold {
            row.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
        }
        return row
    }

    private func action(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        row.target = self
        row.isEnabled = enabled
        return row
    }

    @objc private func togglePlay() {
        if controller.state().status == "playing" { try? controller.pause() } else { try? controller.play() }
        refreshIcon()
    }

    @objc private func stop() {
        try? controller.stop()
        refreshIcon()
    }

    @objc private func reconnect() {
        Task { await controller.reconnect(); refreshIcon() }
    }

    // localhost passes the LAN filter, and the token in the fragment pairs the browser.
    @objc private func openUI() {
        if let url = URL(string: "http://localhost:\(port)/#token=\(controller.config.token)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyLink() {
        guard let ip = lanAddresses().first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://\(ip):\(port)/#token=\(controller.config.token)", forType: .string)
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
