// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import AppKit

final class AppMemoryBarView: NSView {
    private(set) var fraction = 0.0

    init(fraction: Double, frame: NSRect) {
        super.init(frame: frame)
        update(fraction: fraction)
    }

    func update(fraction: Double) {
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        needsDisplay = true
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
    private let memory = NSTextField(labelWithString: "")
    private var quitRequested = false
    var memoryText: String { memory.stringValue }
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
        memory.stringValue = usage.formattedBytes
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

    func update(_ current: AppMemoryUsage?, largest: UInt64, stillRunning: Bool) {
        if let current = current {
            memory.stringValue = current.formattedBytes
            bar.update(fraction: current.fraction(relativeTo: largest))
            let sameInstance = current.quitTargets.contains { live in
                usage.quitTargets.contains { original in
                    original.stamp == live.stamp && original.executablePath == live.executablePath
                }
            }
            quitButton.isEnabled = sameInstance && !quitRequested
        } else {
            memory.stringValue = stillRunning ? "Unavailable" : "Closed"
            bar.update(fraction: 0)
            quitButton.isEnabled = false
        }
        setAccessibilityLabel("\(usage.name), \(memory.stringValue)")
    }

    @objc private func quitApp() {
        // Live values may change, but a tracked row never changes its Quit target.
        quitRequested = true
        quitButton.isEnabled = false
        onQuit(usage)
    }
}

final class AppMemoryMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let queue = DispatchQueue(label: "Minilet.app-memory", qos: .utility)
    private let readApps: ([MemoryAppIdentity]) throws -> [AppMemoryUsage]
    private var refreshing = false
    private var refreshRequested = false
    private var tracking = false
    private var hasRows = false
    private var timer: Timer?
    private var latest: Result<[AppMemoryUsage], Error>?

    override convenience init() {
        self.init(readApps: { try LiveAppMemoryReader().read(apps: $0, limit: nil) })
    }

    init(readApps: @escaping ([MemoryAppIdentity]) throws -> [AppMemoryUsage]) {
        self.readApps = readApps
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        showMessage("Reading apps…")
    }

    deinit { timer?.invalidate() }

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
        guard !refreshing else { refreshRequested = true; return }
        refreshing = true
        refreshRequested = false
        let apps = Self.runningApps()
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = Result { try self.readApps(apps) }
            // Deliver in menu tracking mode, not only when the normal app loop resumes.
            RunLoop.main.perform(inModes: [.common, .eventTracking]) {
                self.refreshing = false
                self.apply(result)
                if self.refreshRequested && self.tracking { self.refresh() }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }
    func menuWillOpen(_ menu: NSMenu) {
        // This fires even when reopening only the child menu in the same root session.
        tracking = true
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        refresh()
    }
    func menuDidClose(_ menu: NSMenu) {
        tracking = false
        timer?.invalidate()
        timer = nil
        if let result = latest { render(result) }
    }

    private func showMessage(_ title: String) {
        menu.removeAllItems()
        let message = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        message.isEnabled = false
        menu.addItem(message)
        hasRows = false
    }

    func apply(_ result: Result<[AppMemoryUsage], Error>) {
        latest = result
        guard tracking && hasRows else { render(result); return }
        let apps: [AppMemoryUsage]
        switch result {
        case .success(let values): apps = values
        case .failure: apps = []
        }
        let byBundle = Dictionary(apps.map { ($0.bundlePath, $0) }, uniquingKeysWith: { first, _ in first })
        let largest = apps.map { $0.bytes }.max() ?? 0
        for item in menu.items {
            guard let row = item.view as? AppMemoryRowView else { continue }
            let running = row.usage.quitTargets.contains { target in
                guard let app = NSRunningApplication(processIdentifier: target.stamp.pid) else { return false }
                return !app.isTerminated && app.bundleURL?.resolvingSymlinksInPath().path == target.bundlePath
            }
            row.update(byBundle[row.usage.bundlePath], largest: largest, stillRunning: running)
        }
    }

    private func render(_ result: Result<[AppMemoryUsage], Error>) {
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
        let controller = AppMemoryMenuController(readApps: { _ in [] })
        check(controller.menu.delegate === controller, "The app-memory submenu keeps its live-refresh delegate")
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
        let reduced = AppMemoryUsage(name: apps[0].name, bundlePath: apps[0].bundlePath,
                                     bytes: 1 << 30, quitTargets: [])
        let updated = Array(apps.dropFirst()) + [reduced]
        controller.apply(.success(updated))
        check(controller.menu.items.first?.title == apps[0].name && controller.menu.items.first?.view === rows[0], "Live scans cannot move or replace Quit rows under the pointer")
        check(rows[0].memoryText == "1.0 GB" && abs(rows[0].bar.fraction - 1.0 / 11) < 1e-10, "Live values and bars must update even when an app falls outside the new top ten")
        controller.apply(.success(Array(updated.dropFirst())))
        check(rows[1].memoryText == "Closed" && !rows[1].quitButton.isEnabled && rows[1].bar.fraction == 0, "Exited apps must immediately show Closed and disable Quit")
        controller.menuDidClose(controller.menu)
        check(controller.menu.items.first?.title == apps[2].name, "Latest ranking applies when the child menu closes, without closing the root menu")
        check(controller.timer == nil && !controller.tracking, "Closing the submenu stops its live timer")
        controller.refreshing = true
        let cachedView = controller.menu.items.first?.view
        controller.menuWillOpen(controller.menu)
        check(controller.menu.items.first?.view === cachedView, "Will-open must not rebuild cached items while AppKit is opening the submenu")
        check(controller.timer?.isValid == true && controller.refreshRequested, "Each submenu opening starts live polling and requests a fresh scan, even with a scan in flight")
        controller.menuDidClose(controller.menu)
        controller.refreshing = false
        controller.refreshRequested = false
        let originalTarget = MemoryQuitTarget(stamp: MemoryProcessStamp(pid: 99, seconds: 10, microseconds: 0),
                                               bundlePath: apps[0].bundlePath, executablePath: "/sample/app")
        let original = AppMemoryUsage(name: apps[0].name, bundlePath: apps[0].bundlePath,
                                      bytes: 8 << 30, quitTargets: [originalTarget])
        let identityRow = AppMemoryRowView(usage: original, largest: original.bytes) { _ in }
        identityRow.update(original, largest: original.bytes, stillRunning: true)
        check(identityRow.quitButton.isEnabled, "Live updates preserve Quit for the same app instance")
        let replacementTarget = MemoryQuitTarget(stamp: MemoryProcessStamp(pid: 99, seconds: 11, microseconds: 0),
                                                  bundlePath: originalTarget.bundlePath, executablePath: originalTarget.executablePath)
        let replacement = AppMemoryUsage(name: original.name, bundlePath: original.bundlePath,
                                         bytes: 2 << 30, quitTargets: [replacementTarget])
        identityRow.update(replacement, largest: 8 << 30, stillRunning: true)
        check(!identityRow.quitButton.isEnabled && identityRow.usage.quitTargets[0].stamp == originalTarget.stamp,
              "A restarted app cannot replace the tracked row's Quit identity")
        identityRow.update(nil, largest: 0, stillRunning: true)
        check(identityRow.memoryText == "Unavailable" && !identityRow.quitButton.isEnabled,
              "Unreadable memory must not label a still-running app Closed")
        controller.apply(.success([]))
        check(controller.menu.items.count == 1 && !controller.menu.items[0].isEnabled, "Empty reads do not invent zero-memory apps")
        controller.apply(.failure(MemoryReadError.unavailable("test")))
        check(controller.menu.items.first?.title == "App memory unavailable", "Failed reads have a compact unavailable state")
        return checks
    }
}
