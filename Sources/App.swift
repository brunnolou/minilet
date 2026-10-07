// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import AppKit

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func appleScriptString(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let temperatureItem = NSMenuItem(title: "Reading temperature…", action: nil, keyEquivalent: "")
    private let speedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let controlTempItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let outputItem = NSMenuItem(title: "Monitoring only", action: nil, keyEquivalent: "")
    private let authorizeItem = NSMenuItem(title: "Enable fan controls…", action: #selector(authorize), keyEquivalent: "")
    private let memoryItem = NSMenuItem(title: "Reading memory…", action: nil, keyEquivalent: "")
    private let pressureItem = NSMenuItem(title: "Memory pressure   Reading…", action: nil, keyEquivalent: "")
    private let compressedItem = NSMenuItem(title: "Compressed   -- GB", action: nil, keyEquivalent: "")
    private let swapItem = NSMenuItem(title: "Swap used   -- GB", action: nil, keyEquivalent: "")
    private let pressureHistoryView = PressureHistoryView()
    private let memoryQueue = DispatchQueue(label: "Minilet.memory", qos: .utility)
    private let memoryReader = LiveMemoryReader()
    private var memoryHistory = PressureHistory()
    private var latestMemory: MemorySnapshot?
    private var latestTemperature: Double?
    private var hardwareStatus = "Monitoring only"
    private var memoryRefreshing = false
    private var modeItems: [FanMode: NSMenuItem] = [:]
    private var guardOptionItems: [NSMenuItem] = []
    private var hasControlTemperature = false
    private let curveMenuItem = NSMenuItem(title: "Guard curve", action: nil, keyEquivalent: "")
    private var curveItems: [CurveType: NSMenuItem] = [:]
    private let targetLabel = NSTextField(labelWithString: "")
    private let maxLabel = NSTextField(labelWithString: "")
    private let rampItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let targetSlider = NSSlider(value: 80, minValue: 40, maxValue: 85, target: nil, action: nil)
    private let maxSlider = NSSlider(value: 5500, minValue: 3200, maxValue: 8000, target: nil, action: nil)
    private let queue = DispatchQueue(label: "Minilet.controller")
    private let session = UUID().uuidString
    private var socketPath: String { "/var/run/minilet-\(session).sock" }
    private var authProcess: Process?
    private var timer: Timer?
    private var memoryTimer: Timer?
    private var settings = Settings()
    private var mode: FanMode?
    private var connected = false
    private var refreshing = false
    private var refreshRequested = false
    private var terminating = false
    private var pending: FanMode?
    private var inFlightMode: FanMode?
    private var lastError: String?
    private var debounce: DispatchWorkItem?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private lazy var welcomeController = WelcomeWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Don't run two UI instances with conflicting controller sessions.
        let instances = ["com.brunnolou.Minilet", "com.brunnolou.FanMenu"].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
        if instances.contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil)
            return
        }
        // Preserve the sliders and curve when upgrading from Fan Menu.
        let stored = UserDefaults.standard.data(forKey: "settings")
            ?? (UserDefaults.standard.persistentDomain(forName: "com.brunnolou.FanMenu")?["settings"] as? Data)
        if let stored = stored,
           let saved = try? JSONDecoder().decode(Settings.self, from: stored),
           (try? saved.validate()) != nil {
            settings = saved
            UserDefaults.standard.set(stored, forKey: "settings")
        }
        createMenu()
        timer = Timer(timeInterval: 2, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        memoryTimer = Timer(timeInterval: 2, target: self, selector: #selector(refreshMemory), userInfo: nil, repeats: true)
        RunLoop.main.add(memoryTimer!, forMode: .common)
        refreshMemory()
        refresh()
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObserver = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            // No preset is automatically re-enabled after waking.
            self.pending = .auto
            self.memoryHistory.clear()
            self.pressureHistoryView.history = self.memoryHistory
            self.refresh()
        }
        wakeObserver = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.pending = .auto
            self.memoryHistory.clear()
            self.pressureHistoryView.history = self.memoryHistory
            self.refreshMemory()
            self.refresh()
        }
        if WelcomeWindowController.shouldShowOnLaunch() { showWelcome() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // An explicit launch from Finder should explain where the app lives,
        // even if startup welcomes were disabled.
        showWelcome()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func showWelcome() { welcomeController.present() }
    @objc private func openSupport() { NSWorkspace.shared.open(MiniletLinks.support) }
    @objc private func openSource() { NSWorkspace.shared.open(MiniletLinks.source) }
    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
    @objc private func openLicense() {
        let url = Bundle.main.url(forResource: "LICENSE", withExtension: "md") ?? MiniletLinks.license
        NSWorkspace.shared.open(url)
    }

    private func createMenu() {
        menu.autoenablesItems = false
        temperatureItem.isEnabled = false
        speedItem.isEnabled = false
        controlTempItem.isEnabled = false
        controlTempItem.isHidden = true
        outputItem.isEnabled = false
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "Minilet")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.attributedTitle = MemoryVisuals.statusTitle(temperature: nil, memory: nil)
        statusItem.button?.toolTip = "Minilet · monitoring only"
        statusItem.menu = menu
        menu.addItem(temperatureItem)
        menu.addItem(controlTempItem)
        menu.addItem(speedItem)
        outputItem.target = self
        outputItem.action = #selector(showControlError)
        menu.addItem(outputItem)
        menu.addItem(.separator())
        createMemoryMenu()
        menu.addItem(.separator())
        for preset in FanMode.allCases {
            if preset == .guardMode { menu.addItem(.separator()) }
            let item = NSMenuItem(title: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.image = presetIcon(preset)
            item.target = self
            item.representedObject = preset.rawValue
            modeItems[preset] = item
            menu.addItem(item)
        }
        addGuardOption(.separator())
        let curveMenu = NSMenu()
        curveMenu.autoenablesItems = false
        for curve in CurveType.allCases {
            let item = NSMenuItem(title: "\(curve.title) · \(curve.description)", action: #selector(selectCurve(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = curve.rawValue
            curveItems[curve] = item
            curveMenu.addItem(item)
        }
        curveMenuItem.submenu = curveMenu
        addGuardOption(curveMenuItem)
        updateCurveChecks()
        targetSlider.doubleValue = settings.target
        maxSlider.doubleValue = settings.maxRPM
        for slider in [targetSlider, maxSlider] {
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            slider.isContinuous = true
        }
        addGuardOption(sliderItem(label: targetLabel, slider: targetSlider))
        addGuardOption(sliderItem(label: maxLabel, slider: maxSlider))
        rampItem.isEnabled = false
        addGuardOption(rampItem)
        let note = NSMenuItem(title: "Full speed overrides the cap at 92°C", action: nil, keyEquivalent: "")
        note.isEnabled = false
        addGuardOption(note)
        menu.addItem(.separator())
        authorizeItem.target = self
        menu.addItem(authorizeItem)
        menu.addItem(.separator())
        let welcomeItem = NSMenuItem(title: "Welcome to Minilet…", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        welcomeItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(welcomeItem)
        let supportItem = NSMenuItem(title: "Buy me a coffee", action: #selector(openSupport), keyEquivalent: "")
        supportItem.target = self
        supportItem.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        supportItem.toolTip = MiniletLinks.support.absoluteString
        menu.addItem(supportItem)
        let licenseItem = NSMenuItem(title: "License and source", action: nil, keyEquivalent: "")
        licenseItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        let licenseMenu = NSMenu()
        licenseMenu.autoenablesItems = false
        for title in ["Copyright 2026 brunnolou", "GNU GPL v3.0 · No warranty", "Redistribution permitted under GPL v3.0"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            licenseMenu.addItem(item)
        }
        licenseMenu.addItem(.separator())
        let readLicense = NSMenuItem(title: "Read license…", action: #selector(openLicense), keyEquivalent: "")
        readLicense.target = self
        licenseMenu.addItem(readLicense)
        let sourceItem = NSMenuItem(title: "Source code…", action: #selector(openSource), keyEquivalent: "")
        sourceItem.target = self
        licenseMenu.addItem(sourceItem)
        licenseItem.submenu = licenseMenu
        menu.addItem(licenseItem)
        let quitItem = NSMenuItem(title: "Quit and restore automatic", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        updateSliderLabels()
        updateChecks()
    }

    private func createMemoryMenu() {
        memoryItem.isEnabled = false
        memoryItem.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)
        compressedItem.isEnabled = false
        swapItem.isEnabled = false
        pressureItem.isEnabled = false
        pressureItem.image = MemoryVisuals.badge(.unknown)
        menu.addItem(memoryItem)
        menu.addItem(pressureItem)
        menu.addItem(compressedItem)
        menu.addItem(swapItem)
        let history = NSMenuItem()
        history.view = pressureHistoryView
        menu.addItem(history)
        let activity = NSMenuItem(title: "Open Activity Monitor…", action: #selector(openActivityMonitor), keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)
    }

    @objc private func refreshMemory() {
        guard !terminating, !memoryRefreshing else { return }
        memoryRefreshing = true
        // Independent of fan IPC. A slow SMC operation cannot freeze RAM readings.
        memoryQueue.async { [weak self] in
            guard let self = self else { return }
            let result = Result { try self.memoryReader.read() }
            DispatchQueue.main.async {
                self.memoryRefreshing = false
                guard !self.terminating else { return }
                switch result {
                case .success(let snapshot): self.applyMemory(snapshot)
                case .failure(let error):
                    self.latestMemory = nil
                    self.memoryItem.title = "Memory unavailable"
                    self.memoryItem.toolTip = error.localizedDescription
                    self.pressureItem.title = "Memory pressure   Unavailable"
                    self.pressureItem.image = MemoryVisuals.badge(.unknown)
                    self.compressedItem.title = "Compressed   Unavailable"
                    self.swapItem.title = "Swap used   Unavailable"
                    self.memoryHistory.record(.unknown, at: ProcessInfo.processInfo.systemUptime)
                    self.pressureHistoryView.history = self.memoryHistory
                    self.updateStatusDisplay()
                }
            }
        }
    }

    private func applyMemory(_ snapshot: MemorySnapshot) {
        latestMemory = snapshot
        memoryItem.title = "Memory used   \(snapshot.compactUsage)"
        memoryItem.toolTip = nil
        pressureItem.title = "Memory pressure   \(snapshot.pressure.title)"
        pressureItem.image = MemoryVisuals.badge(snapshot.pressure)
        compressedItem.title = "Compressed   \(MemoryFormat.gigabytes(snapshot.compressedBytes)) GB"
        swapItem.title = snapshot.swapUsedBytes.map { "Swap used   \(MemoryFormat.gigabytes($0)) GB" } ?? "Swap used   Unavailable"
        memoryHistory.record(snapshot.pressure, at: snapshot.timestamp)
        pressureHistoryView.history = memoryHistory
        updateStatusDisplay()
    }

    private func updateStatusDisplay() {
        statusItem.button?.attributedTitle = MemoryVisuals.statusTitle(temperature: latestTemperature, memory: latestMemory)
        let temperature = latestTemperature.map { String(format: "%.1f°C", $0) } ?? "Unavailable"
        let usage = latestMemory?.compactUsage ?? "Unavailable"
        let pressure = latestMemory?.pressure.title ?? "Unavailable"
        statusItem.button?.toolTip = "Hottest die: \(temperature)\nMemory: \(usage)\nMemory pressure: \(pressure)\n\(hardwareStatus)"
        statusItem.button?.setAccessibilityLabel("Minilet. Temperature \(temperature). Memory \(usage). Pressure \(pressure). \(hardwareStatus)")
    }

    private func presetIcon(_ preset: FanMode) -> NSImage? {
        let image = NSImage(systemSymbolName: preset.symbolName, accessibilityDescription: preset.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    private func addGuardOption(_ item: NSMenuItem) {
        guardOptionItems.append(item)
        menu.addItem(item)
    }

    private func updateGuardVisibility() {
        // Show options as soon as Guard is selected, including while waiting
        // for authorization. A newly selected preset hides them immediately.
        let selected = pending ?? inFlightMode ?? mode
        let showGuard = selected == .guardMode
        for item in guardOptionItems { item.isHidden = !showGuard }
        controlTempItem.isHidden = !showGuard || !hasControlTemperature
    }

    private func sliderItem(label: NSTextField, slider: NSSlider) -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 285, height: 65))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.frame = NSRect(x: 17, y: 39, width: 255, height: 18)
        slider.frame = NSRect(x: 17, y: 8, width: 250, height: 24)
        view.addSubview(label)
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func updateSliderLabels() {
        targetLabel.stringValue = "Guard target   \(Int(settings.target))°C"
        maxLabel.stringValue = "Guard speed cap   \(Int(settings.maxRPM)) RPM"
        rampItem.title = "Min RPM below \(Int(settings.target - 5))°C · cap at \(Int(settings.rampEndTemperature))°C"
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        settings.target = targetSlider.doubleValue.rounded()
        settings.maxRPM = (maxSlider.doubleValue / 100).rounded() * 100
        updateSliderLabels()
        saveAndApplySettings()
    }

    @objc private func selectCurve(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let curve = CurveType(rawValue: raw) else { return }
        settings.curve = curve
        updateCurveChecks()
        saveAndApplySettings()
    }

    private func updateCurveChecks() {
        curveMenuItem.title = "Guard curve · \(settings.curve.title)"
        for (curve, item) in curveItems { item.state = curve == settings.curve ? .on : .off }
    }

    private func saveAndApplySettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") }
        debounce?.cancel()
        // Editing guard settings while monitoring doesn't prompt or start it.
        if mode == .guardMode || pending == .guardMode {
            let work = DispatchWorkItem { [weak self] in
                self?.pending = .guardMode
                self?.refresh()
            }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    @objc private func selectPreset(_ item: NSMenuItem) {
        debounce?.cancel()
        guard let raw = item.representedObject as? String, let preset = FanMode(rawValue: raw) else { return }
        pending = preset
        updateGuardVisibility()
        if connected { refresh() }
        else { authorize() }
    }

    @objc private func authorize() {
        guard !connected, authProcess == nil else { return }
        guard let executable = Bundle.main.executablePath else { return }
        outputItem.title = "Waiting for authorization…"
        authorizeItem.title = "Waiting for authorization…"
        authorizeItem.isEnabled = false
        let command = [executable, "--worker", session, String(getuid()), String(getpid())].map(shellQuote).joined(separator: " ")
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        authProcess = process
        queue.async { [weak self] in
            var failure: String?
            do {
                try process.run()
                process.waitUntilExit() // Controller lives for this app session.
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus != 0 {
                    failure = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch { failure = String(describing: error) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.authProcess = nil
                self.connected = false
                self.mode = nil
                self.pending = nil
                self.inFlightMode = nil
                self.updateChecks()
                self.authorizeItem.title = "Enable fan controls…"
                self.authorizeItem.isEnabled = true
                if !self.terminating {
                    self.outputItem.title = failure == nil ? "Controller stopped · monitoring only" : "Authorization/controller failed"
                    if let failure = failure, !failure.contains("-128") { self.showError(failure) }
                }
            }
        }
    }

    @objc private func refresh() {
        guard !terminating else { return }
        guard !refreshing else {
            refreshRequested = true
            return
        }
        refreshRequested = false
        refreshing = true
        let path = socketPath
        let request = Request(command: pending?.rawValue ?? "status", settings: settings)
        let selected = pending
        if FileManager.default.fileExists(atPath: path) {
            pending = nil
            inFlightMode = selected
            updateGuardVisibility()
            if let selected = selected {
                outputItem.title = "Applying \(selected.title)…"
                outputItem.isEnabled = false
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<Reply, Error>
            if FileManager.default.fileExists(atPath: path) {
                result = Result { try queryWorker(path: path, request: request) }
            } else {
                result = Result {
                    let device = try LiveFanDevice()
                    return Reply(temperature: try device.temperature(), rpms: try device.speeds())
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshing = false
                self.inFlightMode = nil
                switch result {
                case .success(let reply):
                    self.connected = FileManager.default.fileExists(atPath: path)
                    self.mode = self.connected && reply.error == nil ? reply.mode : nil
                    self.updateChecks()
                    self.latestTemperature = reply.temperature
                    if let temp = reply.temperature {
                        self.temperatureItem.title = "Hottest die   \(String(format: "%.1f", temp))°C"
                    } else { self.temperatureItem.title = "Temperature unavailable" }
                    self.hasControlTemperature = reply.smoothedTemperature != nil
                    self.updateGuardVisibility()
                    if let temp = reply.smoothedTemperature {
                        self.controlTempItem.title = "Control temperature   \(String(format: "%.1f", temp))°C"
                    }
                    self.speedItem.title = reply.rpms.enumerated().map { "Fan \($0.offset + 1): \(Int($0.element))" }.joined(separator: "   ") + " RPM"
                    self.lastError = reply.error
                    self.outputItem.title = reply.error == nil ? reply.output : "Control error · click for details"
                    self.outputItem.isEnabled = reply.error != nil
                    self.hardwareStatus = reply.error ?? reply.output
                    self.authorizeItem.title = self.connected ? "Controls enabled for this session" : (self.authProcess == nil ? "Enable fan controls…" : "Waiting for authorization…")
                    self.authorizeItem.isEnabled = !self.connected && self.authProcess == nil
                    if let error = reply.error, selected != nil { self.showError(error) }
                case .failure(let error):
                    self.latestTemperature = nil
                    self.temperatureItem.title = "Temperature unavailable"
                    self.outputItem.title = "\(error)"
                    self.hardwareStatus = "\(error)"
                }
                self.updateStatusDisplay()
                self.updateGuardVisibility()
                // Flush changes queued during an in-flight SMC operation,
                // rather than waiting for the next UI polling timer.
                if self.refreshRequested { self.refresh() }
            }
        }
    }

    private func updateChecks() {
        for (preset, item) in modeItems { item.state = preset == mode ? .on : .off }
        updateGuardVisibility()
    }

    // Native menu regression checks without authorization or hardware writes.
    func runMenuSelfTest() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        createMenu()
        for preset in FanMode.allCases {
            check(modeItems[preset]?.image != nil, "Every preset needs a valid SF Symbol")
            check(modeItems[preset]?.image?.isTemplate == true, "Icons must follow the system appearance")
        }
        let guardIndex = menu.index(of: modeItems[.guardMode]!)
        check(menu.item(at: guardIndex - 1)?.isSeparatorItem == true, "Guard must have its own section")
        check(guardIndex > menu.index(of: modeItems[.full]!), "Guard must follow fixed presets")
        check(guardOptionItems.allSatisfy { $0.isHidden }, "Monitoring must hide all guard options")
        for preset in FanMode.allCases {
            mode = preset
            hasControlTemperature = true
            updateChecks()
            let guardSelected = preset == .guardMode
            check(guardOptionItems.allSatisfy { $0.isHidden == !guardSelected }, "Only Guard shows its options")
            check(controlTempItem.isHidden == !guardSelected, "Only Guard shows filtered temperature")
            check(modeItems[preset]?.state == .on, "The confirmed preset remains checked")
            check(!memoryItem.isHidden && !pressureItem.isHidden, "Memory stays visible with every fan preset")
        }
        mode = .auto
        pending = .guardMode
        updateGuardVisibility()
        check(guardOptionItems.allSatisfy { !$0.isHidden }, "Guard options appear during authorization")
        pending = nil
        inFlightMode = .guardMode
        updateGuardVisibility()
        check(guardOptionItems.allSatisfy { !$0.isHidden }, "Guard options stay visible while applying")
        pending = .high
        updateGuardVisibility()
        check(guardOptionItems.allSatisfy { $0.isHidden }, "Selecting High hides Guard options immediately")
        pending = nil
        inFlightMode = nil
        mode = nil
        updateChecks()
        check(guardOptionItems.allSatisfy { $0.isHidden }, "Lost authorization hides Guard options")
        check(menu.items.contains { $0.action == #selector(showWelcome) && $0.target === self }, "Menu can reopen the welcome window")
        check(menu.items.contains { $0.action == #selector(openSupport) && $0.target === self }, "Menu can open the support link")
        check(!applicationShouldTerminateAfterLastWindowClosed(NSApp), "Closing welcome must not quit the menu-bar app")
        let legal = menu.items.first { $0.title == "License and source" }?.submenu
        check(legal?.items.contains { $0.title == "GNU GPL v3.0 · No warranty" } == true, "Menu must display licensing and warranty notices")
        check(legal?.items.contains { $0.action == #selector(openLicense) && $0.target === self } == true, "License must be accessible from the menu")
        check(legal?.items.contains { $0.action == #selector(openSource) && $0.target === self } == true, "Source must be accessible from the menu")
        let gib = UInt64(1 << 30)
        latestTemperature = 53
        applyMemory(MemorySnapshot(totalBytes: 24 * gib, usedBytes: 18 * gib + gib / 2,
                                   compressedBytes: 2 * gib, swapUsedBytes: 3 * gib,
                                   pressure: .normal, timestamp: ProcessInfo.processInfo.systemUptime))
        let title = statusItem.button?.attributedTitle.string ?? ""
        func barAttachment() -> NSTextAttachment? {
            guard let title = statusItem.button?.attributedTitle, title.length > 0 else { return nil }
            return title.attribute(.attachment, at: title.length - 1, effectiveRange: nil) as? NSTextAttachment
        }
        check(title.contains("53°") && !title.contains("GB") && barAttachment() != nil, "Temperature and the usage bar must appear together without RAM text")
        check(memoryItem.title.contains("18.5/24 GB"), "Detailed RAM values remain in the menu")
        check(pressureItem.title.contains("Normal"), "Pressure must use macOS state")
        check(compressedItem.title.contains("2.0 GB") && swapItem.title.contains("3.0 GB"), "Menu must show compressed RAM and swap")
        check(pressureHistoryView.history.samples.count == 1, "History must not invent samples before launch")
        check(authProcess == nil && !connected, "Memory display must not authorize fan control")
        check(pressureItem.submenu == nil && !pressureItem.isEnabled, "Pressure is a plain state row, not an explanation dropdown")
        latestTemperature = nil
        updateStatusDisplay()
        check(barAttachment() != nil, "Missing temperature must not hide the usage bar")
        latestTemperature = 53
        latestMemory = nil
        updateStatusDisplay()
        check(statusItem.button?.attributedTitle.string.contains("53°") == true, "Missing memory must not hide temperature")
        for pressure in MemoryPressure.allCases {
            check(MemoryVisuals.badge(pressure).size == NSSize(width: 9, height: 9), "All pressure states need a visual indicator")
        }
        check(MemoryVisuals.color(.normal).isEqual(NSColor.labelColor.withAlphaComponent(1)), "Normal pressure must use system-neutral color")
        check(MemoryVisuals.color(.warning).isEqual(NSColor.systemYellow), "Warning pressure must use yellow")
        check(MemoryVisuals.color(.critical).isEqual(NSColor.systemRed), "Critical pressure must use red")
        let fullBar = MemoryVisuals.usageBar(fraction: 1, pressure: .normal)
        if let data = fullBar.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
            check((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.05, "Filled bars must retain transparent rounded corners")
            check((bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.95, "Full usage must fill the bar center")
        } else { preconditionFailure("Usage bar must render") }
        let historyOutline = MemoryVisuals.capsule(NSRect(x: 0, y: 0, width: 100, height: 10))
        check(!historyOutline.contains(NSPoint(x: 0.5, y: 0.5)) && historyOutline.contains(NSPoint(x: 50, y: 5)), "History uses a capsule outline for clipping its fills")
        checks += WelcomeWindowController.runSelfTest()
        NSStatusBar.system.removeStatusItem(statusItem)
        print("\(checks) native menu and welcome checks passed")
    }

    @objc private func showControlError() {
        if let error = lastError { showError(error) }
    }

    private func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Minilet"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        timer?.invalidate()
        memoryTimer?.invalidate()
        debounce?.cancel()
        guard connected else { return .terminateNow }
        let path = socketPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try queryWorker(path: path, request: Request(command: "quit")) }
            DispatchQueue.main.async {
                guard let self = self else { sender.reply(toApplicationShouldTerminate: true); return }
                if case .success(let reply) = result, let error = reply.error {
                    self.showError(error)
                    self.terminating = false
                    sender.reply(toApplicationShouldTerminate: false)
                } else {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }

}

if CommandLine.arguments.dropFirst().first == "--menu-self-test" {
    NSApplication.shared.setActivationPolicy(.accessory)
    let menuTestDelegate = AppDelegate()
    menuTestDelegate.runMenuSelfTest()
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--memory-snapshot" {
    do {
        let snapshot = try LiveMemoryReader().read()
        print("Memory: \(snapshot.compactUsage); pressure: \(snapshot.pressure.title)")
        print("Compressed: \(MemoryFormat.gigabytes(snapshot.compressedBytes)) GB")
        print("Swap used: \(snapshot.swapUsedBytes.map { MemoryFormat.gigabytes($0) + " GB" } ?? "Unavailable")")
        exit(0)
    } catch {
        fputs("Memory: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.dropFirst().first == "--worker" {
    do {
        guard CommandLine.arguments.count == 5,
              let uid = uid_t(CommandLine.arguments[3]), let pid = pid_t(CommandLine.arguments[4]) else {
            throw "Invalid worker arguments"
        }
        try runWorker(session: CommandLine.arguments[2], uid: uid, parent: pid)
        exit(0)
    } catch {
        fputs("Minilet: \(error)\n", stderr)
        exit(1)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
