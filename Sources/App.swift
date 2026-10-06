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
        refresh()
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObserver = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            // No preset is automatically re-enabled after waking.
            self.pending = .auto
            self.refresh()
        }
        wakeObserver = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pending = .auto
            self?.refresh()
        }
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
        statusItem.button?.title = " --°"
        statusItem.button?.toolTip = "Minilet · monitoring only"
        statusItem.menu = menu
        menu.addItem(temperatureItem)
        menu.addItem(controlTempItem)
        menu.addItem(speedItem)
        outputItem.target = self
        outputItem.action = #selector(showControlError)
        menu.addItem(outputItem)
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
        let quitItem = NSMenuItem(title: "Quit and restore automatic", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        updateSliderLabels()
        updateChecks()
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
                    if let temp = reply.temperature {
                        self.statusItem.button?.title = " \(Int(temp.rounded()))°"
                        self.temperatureItem.title = "Hottest die   \(String(format: "%.1f", temp))°C"
                    }
                    self.hasControlTemperature = reply.smoothedTemperature != nil
                    self.updateGuardVisibility()
                    if let temp = reply.smoothedTemperature {
                        self.controlTempItem.title = "Control temperature   \(String(format: "%.1f", temp))°C"
                    }
                    self.speedItem.title = reply.rpms.enumerated().map { "Fan \($0.offset + 1): \(Int($0.element))" }.joined(separator: "   ") + " RPM"
                    self.lastError = reply.error
                    self.outputItem.title = reply.error == nil ? reply.output : "Control error · click for details"
                    self.outputItem.isEnabled = reply.error != nil
                    self.statusItem.button?.toolTip = reply.error ?? reply.output
                    self.authorizeItem.title = self.connected ? "Controls enabled for this session" : (self.authProcess == nil ? "Enable fan controls…" : "Waiting for authorization…")
                    self.authorizeItem.isEnabled = !self.connected && self.authProcess == nil
                    if let error = reply.error, selected != nil { self.showError(error) }
                case .failure(let error):
                    self.statusItem.button?.title = " --°"
                    self.temperatureItem.title = "Temperature unavailable"
                    self.outputItem.title = "\(error)"
                    self.statusItem.button?.toolTip = "\(error)"
                }
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
        NSStatusBar.system.removeStatusItem(statusItem)
        print("\(checks) native menu checks passed")
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
