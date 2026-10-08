// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import AppKit

final class AppMemoryBarView: NSView {
    let fraction: Double

    init(fraction: Double, frame: NSRect) {
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("Use init(fraction:frame:)") }

    override func draw(_ dirtyRect: NSRect) {
        let track = MemoryVisuals.capsule(bounds)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        track.fill()
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        NSColor.labelColor.withAlphaComponent(0.8).setFill()
        NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class AppMemoryRowView: NSView {
    let usage: AppMemoryUsage
    let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    let bar: AppMemoryBarView
    private let onQuit: (AppMemoryUsage) -> Void

    init(usage: AppMemoryUsage, largest: UInt64, onQuit: @escaping (AppMemoryUsage) -> Void) {
        self.usage = usage
        self.onQuit = onQuit
        bar = AppMemoryBarView(fraction: usage.fraction(relativeTo: largest),
                               frame: NSRect(x: 49, y: 10, width: 235, height: 6))
        super.init(frame: NSRect(x: 0, y: 0, width: 365, height: 52))
        let icon = NSImageView(frame: NSRect(x: 17, y: 15, width: 24, height: 24))
        icon.image = NSWorkspace.shared.icon(forFile: usage.bundlePath)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        let name = NSTextField(labelWithString: usage.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 49, y: 25, width: 160, height: 19)
        addSubview(name)
        let memory = NSTextField(labelWithString: usage.formattedBytes)
        memory.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        memory.alignment = .right
        memory.textColor = .secondaryLabelColor
        memory.frame = NSRect(x: 214, y: 25, width: 70, height: 19)
        addSubview(memory)
        addSubview(bar)
        quitButton.bezelStyle = .rounded
        quitButton.font = .systemFont(ofSize: 12)
        quitButton.frame = NSRect(x: 301, y: 16, width: 52, height: 25)
        quitButton.target = self
        quitButton.action = #selector(quitApp)
        quitButton.setAccessibilityLabel("Quit \(usage.name)")
        addSubview(quitButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(usage.name), \(usage.formattedBytes)")
    }

    required init?(coder: NSCoder) { fatalError("Use init(usage:largest:onQuit:)") }

    @objc private func quitApp() {
        // The row keeps its original app identity even if a scan finishes while
        // the pointer is over Quit. No index-based lookup or force termination.
        quitButton.isEnabled = false
        onQuit(usage)
    }
}

final class AppMemoryMenuController: NSObject, NSMenuDelegate {
    let item = NSMenuItem(title: "Apps using memory", action: nil, keyEquivalent: "")
    let menu = NSMenu()
    private let queue = DispatchQueue(label: "Minilet.app-memory", qos: .utility)
    private let reader = LiveAppMemoryReader()
    private var refreshing = false
    private var tracking = false
    private var hasRows = false
    private var deferred: Result<[AppMemoryUsage], Error>?

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.submenu = menu
        item.image = NSImage(systemSymbolName: "app.stack", accessibilityDescription: nil)
        showMessage("Reading apps…")
    }

    static func runningApps() -> [MemoryAppIdentity] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, app.activationPolicy != .prohibited,
                  let bundle = app.bundleURL?.resolvingSymlinksInPath(),
                  let executable = app.executableURL?.resolvingSymlinksInPath() else { return nil }
            // Exclude OS infrastructure, not named applications. Apple's regular
            // apps in /System/Applications remain eligible.
            guard !bundle.path.contains("/System/Library/"),
                  !bundle.path.contains("/usr/libexec/"),
                  bundle.pathExtension.lowercased() == "app" else { return nil }
            let name = app.localizedName ?? Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? bundle.deletingPathExtension().lastPathComponent
            return MemoryAppIdentity(pid: app.processIdentifier, name: name, bundlePath: bundle.path,
                                     executablePath: executable.path)
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let apps = Self.runningApps()
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = Result { try self.reader.read(apps: apps) }
            DispatchQueue.main.async {
                self.refreshing = false
                // Do not reshuffle actionable rows under the user's pointer.
                if self.tracking && self.hasRows { self.deferred = result }
                else { self.apply(result) }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }
    func menuWillOpen(_ menu: NSMenu) { tracking = true }
    func menuDidClose(_ menu: NSMenu) {
        tracking = false
        if let result = deferred {
            deferred = nil
            apply(result)
        }
    }

    private func showMessage(_ title: String) {
        menu.removeAllItems()
        let message = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        message.isEnabled = false
        menu.addItem(message)
        hasRows = false
    }

    func apply(_ result: Result<[AppMemoryUsage], Error>) {
        switch result {
        case .failure: showMessage("App memory unavailable")
        case .success(let apps):
            let top = Array(apps.prefix(AppMemoryGrouping.limit))
            guard let largest = top.map({ $0.bytes }).max() else { showMessage("No app memory available"); return }
            menu.removeAllItems()
            for app in top {
                let row = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
                row.view = AppMemoryRowView(usage: app, largest: largest) { [weak self] usage in self?.quit(usage) }
                menu.addItem(row)
            }
            hasRows = true
        }
    }

    static func requestQuit(_ usage: AppMemoryUsage) -> Bool {
        var rejected = false
        for target in usage.quitTargets {
            guard let app = NSRunningApplication(processIdentifier: target.stamp.pid), !app.isTerminated,
                  app.bundleURL?.resolvingSymlinksInPath().path == target.bundlePath,
                  let process = LiveAppMemoryReader.process(target.stamp.pid), target.matches(process, uid: getuid()) else { continue }
            if !app.terminate() { rejected = true }
        }
        return !rejected
    }

    private func quit(_ usage: AppMemoryUsage) {
        if !Self.requestQuit(usage) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Could not quit \(usage.name)"
            alert.informativeText = "The app did not accept the quit request."
            alert.runModal()
        }
        refresh()
    }

    static func runSelfTest() -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        let controller = AppMemoryMenuController()
        check(controller.item.submenu === controller.menu, "App memory belongs in a submenu")
        check(controller.menu.items.count == 1 && !controller.menu.items[0].isEnabled, "Initial state is a disabled reading row")
        let apps = (0..<12).map { index in
            AppMemoryUsage(name: "Sample app \(index)", bundlePath: "/Applications/Sample\(index).app",
                           bytes: UInt64(12 - index) * (1 << 30), quitTargets: [])
        }
        controller.apply(.success(apps))
        check(controller.menu.items.count == 10, "App submenu must show at most ten rows")
        let rows = controller.menu.items.compactMap { $0.view as? AppMemoryRowView }
        check(rows.count == 10, "Each app needs a comparison bar and Quit button")
        check(rows[0].bar.fraction == 1 && abs(rows[9].bar.fraction - 0.25) < 1e-10, "Bars compare against the largest app")
        check(rows.allSatisfy { $0.quitButton.title == "Quit" }, "Every app uses Quit, never Review or Open")
        var requested: String?
        let row = AppMemoryRowView(usage: apps[0], largest: apps[0].bytes) { requested = $0.bundlePath }
        row.quitButton.performClick(nil)
        check(requested == apps[0].bundlePath && !row.quitButton.isEnabled, "Quit is bound to the original app, not its row index")
        controller.tracking = true
        controller.hasRows = true
        controller.deferred = .success(Array(apps.reversed()))
        check(controller.menu.items.first?.title == apps[0].name, "Queued updates cannot reorder a tracked menu")
        controller.menuDidClose(controller.menu)
        check(controller.menu.items.first?.title == apps.last?.name, "Deferred results apply after tracking ends")
        controller.apply(.success([]))
        check(controller.menu.items.count == 1 && !controller.menu.items[0].isEnabled, "Empty reads do not invent zero-memory apps")
        controller.apply(.failure(MemoryReadError.unavailable("test")))
        check(controller.menu.items.first?.title == "App memory unavailable", "Failed reads have a compact unavailable state")
        return checks
    }
}
