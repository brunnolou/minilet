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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var fanIcon: NSImage?
    private var monitoringFanIcon: NSImage?
    private let menu = NSMenu()
    private let temperatureItem = NSMenuItem(title: "Reading temperature…", action: nil, keyEquivalent: "")
    private let speedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let controlTempItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let outputItem = NSMenuItem(title: "Monitoring only", action: nil, keyEquivalent: "")
    private let memoryItem = NSMenuItem(title: "Reading memory…", action: nil, keyEquivalent: "")
    private let pressureItem = NSMenuItem(title: "Memory pressure   Reading…", action: nil, keyEquivalent: "")
    private let compressedItem = NSMenuItem(title: "Compressed   -- GB", action: nil, keyEquivalent: "")
    private let swapItem = NSMenuItem(title: "Swap used   -- GB", action: nil, keyEquivalent: "")
    private let pressureHistoryView = PressureHistoryView()
    private lazy var memorySummaryView = MemorySummaryView(history: pressureHistoryView)
    private let appMemoryMenu = AppMemoryMenuController()
    private let memoryQueue = DispatchQueue(label: "Minilet.memory", qos: .utility)
    private let memoryReader = LiveMemoryReader()
    private let processorReader = LiveProcessorReader()
    private var processorGeneration = 0
    private var latestProcessors: ProcessorSnapshot?
    private var memoryHistory = PressureHistory()
    private var latestMemory: MemorySnapshot?
    private var latestTemperature: Double?
    private var hardwareStatus = "Monitoring only"
    private var memoryRefreshing = false
    private let fanPresetView = FanPresetView()
    private let fanPresetItem = NSMenuItem()
    private let temperatureControlView = TemperatureControlView()
    private let temperatureControlItem = NSMenuItem()
    private var selection = FanControlSelection()
    private var testingControls = false
    private var hasControlTemperature = false
    private let curveMenuItem = NSMenuItem(title: "Curve", action: nil, keyEquivalent: "")
    private var curveItems: [CurveType: NSMenuItem] = [:]
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
        RunLoop.main.add(memoryTimer!, forMode: .eventTracking)
        refreshMemory()
        refresh()
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObserver = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            // No preset is automatically re-enabled after waking.
            self.resetProcessorSampling()
            self.pending = .auto
            self.resetSelection()
            self.memoryHistory.clear()
            self.pressureHistoryView.history = self.memoryHistory
            self.refresh()
        }
        wakeObserver = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.resetProcessorSampling()
            self.pending = .auto
            self.resetSelection()
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
    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu { appMemoryMenu.refresh() }
    }

    private func createMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        temperatureItem.isEnabled = false
        speedItem.isEnabled = false
        controlTempItem.isEnabled = false
        controlTempItem.isHidden = true
        outputItem.isEnabled = false
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        fanPresetView.onGaugeImageChanged = { [weak self] image in self?.updateStatusFanIcon(image) }
        updateStatusFanIcon(fanPresetView.icon.image!)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.attributedTitle = MemoryVisuals.statusTitle(temperature: nil, memory: nil)
        statusItem.button?.toolTip = "Minilet · monitoring only"
        statusItem.menu = menu
        menu.addItem(temperatureItem)
        menu.addItem(speedItem)
        outputItem.target = self
        outputItem.action = #selector(showControlError)
        menu.addItem(outputItem)
        menu.addItem(.separator())
        fanPresetItem.view = fanPresetView
        fanPresetView.onChange = { [weak self] preset in self?.speedChanged(preset) }
        menu.addItem(fanPresetItem)
        temperatureControlItem.view = temperatureControlView
        temperatureControlView.onChange = { [weak self] temperature in self?.temperatureChanged(temperature) }
        menu.addItem(temperatureControlItem)
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
        updateCurveChecks()
        menu.addItem(controlTempItem)
        menu.addItem(curveMenuItem)
        menu.addItem(.separator())
        createMemoryMenu()
        menu.addItem(.separator())
        let welcomeItem = NSMenuItem(title: "About Minilet", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        welcomeItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(welcomeItem)
        let quitItem = NSMenuItem(title: "Quit and restore automatic", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        updateChecks()
    }

    private func createMemoryMenu() {
        memoryItem.isEnabled = true
        memoryItem.view = memorySummaryView
        memoryItem.submenu = appMemoryMenu.menu
        compressedItem.isEnabled = false
        swapItem.isEnabled = false
        pressureItem.isEnabled = false
        pressureItem.image = MemoryVisuals.badge(.unknown)
        updateMemorySummary()
        menu.addItem(memoryItem)
        let activity = NSMenuItem(title: "Open Activity Monitor…", action: #selector(openActivityMonitor), keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)
    }

    private func resetProcessorSampling() {
        processorGeneration += 1
        latestProcessors = nil
        memoryQueue.async { [reader = processorReader] in reader.reset() }
        updateStatusDisplay()
    }

    @objc private func refreshMemory() {
        guard !terminating, !memoryRefreshing else { return }
        memoryRefreshing = true
        let generation = processorGeneration
        // Independent of fan IPC. A slow SMC operation cannot freeze RAM readings.
        memoryQueue.async { [weak self] in
            guard let self = self else { return }
            let result = Result { try self.memoryReader.read() }
            let processors = self.processorReader.read()
            RunLoop.main.perform(inModes: [.common, .eventTracking]) {
                self.memoryRefreshing = false
                guard !self.terminating, generation == self.processorGeneration else { return }
                self.latestProcessors = processors
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

    private func updateMemorySummary() {
        memorySummaryView.update(titles: [memoryItem.title, pressureItem.title, compressedItem.title, swapItem.title],
                                 pressure: pressureItem.image)
    }

    private func updateStatusDisplay() {
        updateMemorySummary()
        statusItem.button?.attributedTitle = MemoryVisuals.statusTitle(temperature: latestTemperature, memory: latestMemory, processors: latestProcessors)
        let temperature = latestTemperature.map { String(format: "%.1f°C", $0) } ?? "Unavailable"
        let usage = latestMemory?.compactUsage ?? "Unavailable"
        let pressure = latestMemory?.pressure.title ?? "Unavailable"
        let cpu = latestProcessors?.cpuDescription ?? "Unavailable"
        let gpu = ProcessorSnapshot.percent(latestProcessors?.gpu)
        statusItem.button?.toolTip = "Hottest die: \(temperature)\nMemory: \(usage)\nMemory pressure: \(pressure)\nCPU: \(cpu)\nGPU: \(gpu)\n\(hardwareStatus)"
        statusItem.button?.setAccessibilityLabel("Minilet. Temperature \(temperature). Memory \(usage). Pressure \(pressure). CPU \(cpu). GPU \(gpu). \(hardwareStatus)")
    }

    private func updateStatusFanIcon(_ source: NSImage) {
        fanIcon = makeFanIcon(source: source, opacity: 1)
        monitoringFanIcon = makeFanIcon(source: source, opacity: 0.5)
        statusItem.button?.image = mode == nil ? monitoringFanIcon : fanIcon
    }

    private func makeFanIcon(source: NSImage, opacity: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func updateGuardVisibility() {
        let selected = pending ?? inFlightMode ?? mode
        controlTempItem.isHidden = selected != .guardMode || !hasControlTemperature
    }

    private func speedChanged(_ speed: FanMode) {
        guard selection.temperature == nil || speed != .auto else {
            updateChecks()
            return
        }
        selection.speed = speed
        settings.speedCap = speed
        debounce?.cancel()
        debounce = nil
        persistSettings()
        requestPreset(selection.mode)
    }

    private func temperatureChanged(_ temperature: Double?) {
        selection.temperature = temperature
        if let temperature = temperature {
            settings.target = temperature
            // Automatic is not a cap. Entering from Auto selects the hardware
            // maximum without forcing full RPM during temperature regulation.
            if selection.speed == .auto { selection.speed = .full }
        }
        settings.speedCap = selection.speed
        updateChecks()
        if temperature == nil {
            debounce?.cancel()
            debounce = nil
            persistSettings()
            requestPreset(selection.mode)
        } else { saveAndApplySettings() }
    }

    private func persistSettings() {
        guard !testingControls else { return }
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") }
    }

    private func resetSelection() {
        selection = FanControlSelection()
        debounce?.cancel()
        debounce = nil
        updateChecks()
    }

    @objc private func selectCurve(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let curve = CurveType(rawValue: raw) else { return }
        settings.curve = curve
        updateCurveChecks()
        persistSettings()
        if selection.temperature != nil { saveAndApplySettings() }
    }

    private func updateCurveChecks() {
        curveMenuItem.title = "Curve · \(settings.curve.title)"
        for (curve, item) in curveItems { item.state = curve == settings.curve ? .on : .off }
    }

    private func saveAndApplySettings() {
        persistSettings()
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.debounce = nil
            self.requestPreset(self.selection.mode)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func requestPreset(_ preset: FanMode) {
        pending = preset
        updateChecks()
        if connected { refresh() }
        else { authorize() }
    }

    private func authorize() {
        guard !connected, authProcess == nil else { return }
        guard let executable = Bundle.main.executablePath else { return }
        outputItem.title = "Waiting for authorization…"
        outputItem.isEnabled = false
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
                self.resetSelection()
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
                    if reply.error != nil { self.resetSelection() }
                    else if self.pending == nil && self.debounce == nil && self.authProcess == nil && !self.connected {
                        self.resetSelection()
                    }
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
                    let waitingForAuthorization = !self.connected && self.authProcess != nil
                    self.outputItem.title = waitingForAuthorization ? "Waiting for authorization…" : (reply.error == nil ? reply.output : "Control error · click for details")
                    self.outputItem.isEnabled = !waitingForAuthorization && reply.error != nil
                    self.hardwareStatus = waitingForAuthorization ? self.outputItem.title : (reply.error ?? reply.output)
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
        fanPresetView.update(selection.speed, capMode: selection.temperature != nil)
        temperatureControlView.update(selection.temperature)
        if let source = fanPresetView.icon.image { updateStatusFanIcon(source) }
        updateGuardVisibility()
    }

    // Native menu regression checks without authorization or hardware writes.
    func runMenuSelfTest() {
        testingControls = true
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        createMenu()
        check(statusItem.button?.image === monitoringFanIcon, "Monitoring starts with the dimmed fan icon")
        check(statusItem.button?.alphaValue == 1, "Only the fan icon dims, not the temperature or RAM bar")
        check(fanIcon?.isTemplate == true && monitoringFanIcon?.isTemplate == true, "Both fan states must follow the menu-bar appearance")
        func meanAlpha(_ image: NSImage?) -> Double {
            guard let image = image,
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 68, pixelsHigh: 64,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                preconditionFailure("Fan icons must render")
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: 68, height: 64), from: .zero,
                       operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            var alpha = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    alpha += Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                }
            }
            return alpha / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
        }
        let fullAlpha = meanAlpha(fanIcon)
        check(fullAlpha > 0 && abs(meanAlpha(monitoringFanIcon) / fullAlpha - 0.5) < 0.02, "Monitoring fan pixels must have 50% opacity")
        pending = .guardMode
        updateChecks()
        check(statusItem.button?.image === monitoringFanIcon, "Pending authorization must not brighten the fan before control is confirmed")
        pending = nil
        updateChecks()
        checks += FanPresetView.runSelfTest()
        checks += TemperatureControlView.runSelfTest()
        check(fanPresetItem.view === fanPresetView && temperatureControlItem.view === temperatureControlView,
              "Speed and Temperature are inline controls")
        check(menu.items.compactMap { $0.view }.flatMap { $0.subviews }.filter { $0 is NSSlider }.count == 2,
              "The temperature group has exactly two sliders")
        check(temperatureControlItem.submenu == nil, "Temperature no longer has a submenu")
        check(menu.index(of: temperatureControlItem) == menu.index(of: fanPresetItem) + 1,
              "Temperature follows the shared speed slider")
        check(menu.index(of: curveMenuItem) == menu.index(of: memoryItem) - 2 && curveMenuItem.submenu != nil,
              "Curve is the last item in the temperature group")
        check(!menu.items.contains { FanMode.sliderModes.map(\.title).contains($0.title) || $0.title.hasPrefix("Set temperature") },
              "The old preset rows and temperature submenu entry are removed")
        check(selection.temperature == nil && selection.speed == .auto && authProcess == nil,
              "Launch starts with Temperature Off and automatic fans")
        for preset in FanMode.allCases {
            mode = preset
            selection = FanControlSelection(speed: preset == .guardMode ? .high : preset,
                                            temperature: preset == .guardMode ? settings.target : nil)
            hasControlTemperature = true
            updateChecks()
            check(controlTempItem.isHidden == (preset != .guardMode), "Only temperature control shows filtered temperature")
            check(fanPresetView.capMode == (preset == .guardMode) && fanPresetView.selection == selection.speed,
                  "The speed slider reflects the selected speed or cap")
            check(statusItem.button?.image === fanIcon, "Confirmed control restores full icon opacity")
            let expectedGauge = FanPresetView.gaugeImage(value: Double(selection.speed.sliderIndex!) / 4)
            check(abs(meanAlpha(fanIcon) - meanAlpha(makeFanIcon(source: expectedGauge, opacity: 1))) < 0.001,
                  "The menu-bar icon follows the selected gauge rather than a static fan")
        }
        connected = true
        refreshing = true // Prevent hardware IPC in these tests.
        resetSelection()
        for speed in FanMode.sliderModes {
            speedChanged(speed)
            check(pending == speed && selection.temperature == nil, "With Temperature Off, speed selects its normal preset")
        }
        speedChanged(.high)
        temperatureChanged(55)
        check(selection.mode == .guardMode && settings.target == 55 && settings.speedCap == .high && debounce != nil,
              "A temperature enables control using the shared speed cap")
        debounce?.perform()
        check(pending == .guardMode && refreshRequested, "Temperature changes request guard control after debounce")
        for speed in FanMode.sliderModes.dropFirst() {
            speedChanged(speed)
            check(pending == .guardMode && settings.speedCap == speed && selection.temperature == 55,
                  "Changing any enabled speed stop in cap mode preserves temperature control")
        }
        speedChanged(.auto)
        check(selection.speed == .full && settings.speedCap == .full && pending == .guardMode,
              "Automatic cannot be selected while temperature control is active")
        temperatureChanged(nil)
        check(pending == .full && selection.mode == .full && !fanPresetView.capMode,
              "Temperature Off resumes the selected fixed-speed preset")
        speedChanged(.auto)
        check(pending == .auto, "Speed zero with Temperature Off restores macOS automatic control")
        pending = nil
        refreshRequested = false
        temperatureChanged(50)
        check(selection.speed == .full && settings.speedCap == .full && fanPresetView.slider.minValue == 1,
              "Enabling temperature from Auto selects a full hardware cap, not a full-speed preset")
        temperatureChanged(nil)
        speedChanged(.auto)
        pending = nil
        selectCurve(curveItems[.linear]!)
        check(pending == nil && debounce == nil && selection.temperature == nil,
              "Changing Curve while Off must not enable temperature control")
        temperatureChanged(40)
        selectCurve(curveItems[.smoothstep]!)
        debounce?.perform()
        check(pending == .guardMode && settings.curve == .smoothstep && settings.target == 40,
              "Curve changes apply to active temperature control")
        pending = .auto
        resetSelection()
        check(selection.temperature == nil && selection.speed == .auto && debounce == nil,
              "Sleep, wake or authorization loss clears session control and queued edits")
        pending = nil
        mode = nil
        updateChecks()
        connected = false
        refreshing = false
        refreshRequested = false
        check(statusItem.button?.image === monitoringFanIcon, "Losing fan control dims only the icon")
        check(menu.items.contains { $0.title == "About Minilet" && $0.action == #selector(showWelcome) && $0.target === self }, "About Minilet opens the welcome window")
        check(!menu.items.contains { $0.title == "Buy me a coffee" }, "The main menu must not contain the coffee link")
        check(!applicationShouldTerminateAfterLastWindowClosed(NSApp), "Closing welcome must not quit the menu-bar app")
        check(!menu.items.contains { $0.title == "License and source" }, "Licensing belongs in About, not the main menu")
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
        let meterBounds = barAttachment()?.bounds ?? .zero
        let digitCenter = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular).capHeight / 2
        check(fullBar.size.height == 4 && meterBounds.size == NSSize(width: 32, height: 14)
              && abs(meterBounds.midY - digitCenter) <= 0.25,
              "The 4px RAM bar and wider row gaps form a stack centered on the temperature digits")
        checks += StatusMeters.runSelfTest()
        latestProcessors = ProcessorSnapshot(cpu: [1] + Array(repeating: 0, count: 11), gpu: 0.5)
        updateStatusDisplay()
        check(statusItem.button?.toolTip?.contains("CPU: 8% · 12 cores") == true && statusItem.button?.toolTip?.contains("GPU: 50%") == true,
              "Processor meters expose their measured values in the existing tooltip")
        let generationBeforeReset = processorGeneration
        resetProcessorSampling()
        check(latestProcessors == nil && processorGeneration > generationBeforeReset,
              "Sleep and wake reject stale CPU/GPU results and reset their baseline")
        if let data = fullBar.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
            check((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.4, "Short filled bars must retain rounded, translucent antialiased corners")
            check((bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.95, "Full usage must fill the bar center")
        } else { preconditionFailure("Usage bar must render") }
        let historyOutline = MemoryVisuals.capsule(NSRect(x: 0, y: 0, width: 100, height: 10))
        check(!historyOutline.contains(NSPoint(x: 0.5, y: 0.5)) && historyOutline.contains(NSPoint(x: 50, y: 5)), "History uses a capsule outline for clipping its fills")
        check(memoryItem.submenu === appMemoryMenu.menu && memoryItem.view === memorySummaryView && memoryItem.isEnabled,
              "The full memory summary must open the apps submenu")
        check(!menu.items.contains { $0.title == "Apps using memory" || $0 === pressureItem || $0 === compressedItem || $0 === swapItem },
              "Memory has one hover block, not a separate apps row or individual data rows")
        check(memorySummaryView.labels[0].stringValue == memoryItem.title && pressureHistoryView.superview === memorySummaryView,
              "The hover block contains the readouts and five-minute history")
        check(memorySummaryView.hitTest(NSPoint(x: 20, y: 10)) === memorySummaryView
              && memorySummaryView.hitTest(NSPoint(x: 50, y: 125)) === memorySummaryView,
              "History and readout hit areas belong to the same submenu item")
        checks += AppMemoryMenuController.runSelfTest()
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
