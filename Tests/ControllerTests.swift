// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fatalError(message) }
}
func expectError(_ message: String, _ body: () throws -> Void) {
    checks += 1
    do { try body(); fatalError(message) } catch { }
}
func requestedRPM(_ output: FanOutput) -> Double {
    guard case .rpm(let rpm) = output else { fatalError("Expected continuous RPM, got \(output)") }
    return rpm
}

final class FakeDevice: FanDevice {
    var temp = 65.0
    var rpms = [2400.0, 2500.0]
    var calls: [String] = []
    var sensorFailure = false
    var writeFailure = false
    var autoFailure = false
    func temperature() throws -> Double {
        if sensorFailure { throw "Sensor missing" }
        return temp
    }
    func speeds() throws -> [Double] { rpms }
    func minimumRPM() throws -> Double { 2400 }
    func maximumRPM() throws -> Double { 7800 }
    func automatic() throws {
        calls.append("auto")
        if autoFailure { throw "Auto failed" }
    }
    func setRPM(_ rpm: Double) throws {
        calls.append("rpm \(Int(rpm))")
        if writeFailure { throw "Write failed" }
        rpms = [rpm, rpm]
    }
    func full() throws { calls.append("full"); rpms = [7826, 7826] }
}

let curve = GuardCurve()
let settings = Settings()
check(try curve.output(temperature: 70, settings: settings) == .rpm(2400), "Cooling must hold minimum RPM, never auto")
check(try curve.output(temperature: 75, settings: settings) == .rpm(2400), "Ramp starts at hardware minimum")
check(try curve.output(temperature: 90, settings: settings) == .rpm(5500), "Ramp ends at selected cap")
check(try curve.output(temperature: 92, settings: settings) == .full, "Raw emergency overrides cap")
check(try curve.output(temperature: 95, settings: settings) == .full, "Emergency above threshold")
expectError("Reject NaN target") { try Settings(target: .nan).validate() }
expectError("Reject unsafe target") { try Settings(target: 110).validate() }
expectError("Reject infinite cap") { try Settings(maxRPM: .infinity).validate() }
expectError("Reject low cap") { try Settings(maxRPM: 2500).validate() }
expectError("Reject target below minimum") { try Settings(target: 29).validate() }
expectError("Reject invalid sensor") { _ = try curve.output(temperature: .nan, settings: settings) }
expectError("Reject invalid fan minimum") { _ = try curve.output(temperature: 80, settings: settings, minimumRPM: .nan) }
expectError("Reject cap below hardware minimum") { _ = try curve.output(temperature: 80, settings: settings, minimumRPM: 6000) }
check(try curve.output(temperature: 30, settings: settings, minimumRPM: 2317) == .rpm(2317), "Rounding must not go below hardware minimum")
check(try curve.output(temperature: 65, settings: Settings(target: 55, maxRPM: 3250, curve: .linear)) == .rpm(3250), "Rounding must not exceed speed cap")

let oldSettings = try JSONDecoder().decode(Settings.self, from: Data(#"{"target":73,"maxRPM":4800}"#.utf8))
check(oldSettings.target == 73 && oldSettings.maxRPM == 4800, "Migration preserves slider values")
check(oldSettings.curve == .exponential, "Migration defaults to exponential")
expectError("Reject unknown curve") {
    _ = try JSONDecoder().decode(Settings.self, from: Data(#"{"target":80,"maxRPM":5500,"curve":"unknown"}"#.utf8))
}
for type in CurveType.allCases {
    let configured = Settings(curve: type)
    check(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(configured)) == configured, "Settings round trip")
    check(abs(type.ease(0)) < 1e-10, "Curve starts at zero")
    check(abs(type.ease(1) - 1) < 1e-10, "Curve ends at one")
    check(type.ease(-1) == 0 && abs(type.ease(2) - 1) < 1e-10, "Curve clamps progress")
    var previous = 0.0
    for step in 0...20 {
        let value = type.ease(Double(step) / 20)
        check(value.isFinite && value >= previous && value <= 1.0000000001, "Curve must be bounded and monotonic")
        previous = value
    }
    for target in [30.0, 40, 45, 55, 80, 85] {
        let configured = Settings(target: target, maxRPM: 7800, curve: type)
        check(try curve.output(temperature: target - 10, settings: configured) == .rpm(2400), "Cold guard stays manual at minimum")
        check(try curve.output(temperature: target - 5, settings: configured) == .rpm(2400), "Every ramp starts at minimum")
        let atCap = try curve.output(temperature: configured.rampEndTemperature, settings: configured)
        check(atCap == (configured.rampEndTemperature == 92 ? .full : .rpm(7800)), "All curves reach cap within ten degrees above target")
        var previousRPM = 2400.0
        for step in 0...20 {
            let temp = (target - 5) + Double(step) / 20 * (configured.rampEndTemperature - (target - 5))
            let output = try curve.output(temperature: min(91.999, temp), settings: configured)
            let rpm = requestedRPM(output)
            check(rpm >= previousRPM && rpm <= configured.maxRPM, "Curve continuously increases RPM without auto toggles")
            previousRPM = rpm
        }
    }
}
check(CurveType.exponential.ease(0.5) < CurveType.linear.ease(0.5), "Exponential is quieter near start")
check(CurveType.logarithmic.ease(0.5) > CurveType.linear.ease(0.5), "Logarithmic cools sooner")
check(CurveType.smoothstep.ease(0.25) < 0.25 && CurveType.smoothstep.ease(0.75) > 0.75, "Smoothstep is S-shaped")

// A trace crossing the old auto/manual thresholds must never request automatic.
var regulator = GuardRegulator()
let lowSettings = Settings(target: 55, maxRPM: 7800, curve: .logarithmic)
var previousRPM = requestedRPM(try regulator.output(temperature: 49, settings: lowSettings, minimumRPM: 2400, actualRPM: 2400, now: 0))
check(previousRPM == 2400, "Start cold at minimum")
for (index, temp) in [56.0, 49, 57, 48, 56, 49, 55, 45, 58, 49].enumerated() {
    let next = try regulator.output(temperature: temp, settings: lowSettings, minimumRPM: 2400, actualRPM: previousRPM, now: Double(index + 1) * 5)
    let rpm = requestedRPM(next)
    check(rpm - previousRPM <= 800.000001, "Speed must increase no faster than 800 RPM per five seconds")
    check(previousRPM - rpm <= 300.000001, "Speed must decrease no faster than 300 RPM per five seconds")
    check(rpm >= 2400 && rpm <= 7800, "Smoothed output stays inside fan limits")
    previousRPM = rpm
}
check(regulator.smoothedTemperature != 49, "Control temperature must be smoothed, not raw")
let noTimePassed = try regulator.output(temperature: 80, settings: lowSettings, minimumRPM: 2400, actualRPM: previousRPM, now: 50)
check(requestedRPM(noTimePassed) == previousRPM, "Repeated option requests cannot accelerate the ramp without elapsed time")
let smallStep = requestedRPM(try regulator.output(temperature: 80, settings: lowSettings, minimumRPM: 2400, actualRPM: previousRPM, now: 50.5))
check(smallStep - previousRPM <= 80.000001, "Speed limit must depend on elapsed time, not request count")
check(try regulator.output(temperature: 93, settings: lowSettings, minimumRPM: 2400, actualRPM: smallStep, now: 51) == .full, "Emergency must bypass filter and slew limit immediately")
check(try regulator.output(temperature: 91, settings: lowSettings, minimumRPM: 2400, actualRPM: 7826, now: 56) == .full, "Emergency must not chatter around 92 C")
check(try regulator.output(temperature: 88, settings: lowSettings, minimumRPM: 2400, actualRPM: 7826, now: 61) != .full, "Emergency releases at 88 C")
expectError("Reject missing sensor before smoothing") {
    _ = try regulator.output(temperature: .nan, settings: lowSettings, minimumRPM: 2400, actualRPM: 3000, now: 66)
}
expectError("Reject invalid actual RPM") {
    _ = try regulator.output(temperature: 50, settings: lowSettings, minimumRPM: 2400, actualRPM: .nan, now: 66)
}
// A changed curve is used on the next check without clearing the filter or RPM history.
var changing = GuardRegulator()
let linear = Settings(target: 55, maxRPM: 7800, curve: .linear)
let startRPM = requestedRPM(try changing.output(temperature: 56, settings: linear, minimumRPM: 2400, actualRPM: 2400, now: 0))
let changedRPM = requestedRPM(try changing.output(temperature: 56, settings: lowSettings, minimumRPM: 2400, actualRPM: startRPM, now: 5))
check(changedRPM > startRPM && changedRPM <= startRPM + 800, "Curve changes apply without a speed jump")
check(changing.smoothedTemperature == 56, "Curve changes preserve thermal filter state")

let device = FakeDevice()
let controller = FanController(device: device)
controller.tick(now: 0)
check(device.calls.isEmpty, "Monitoring must not write fans")
try controller.stop()
check(device.calls.isEmpty, "Quitting monitoring must not write fans")
try controller.select(.high, settings: settings)
check(device.calls.last == "rpm 5000", "High preset")
try controller.select(.xhigh, settings: settings)
check(device.calls.last == "rpm 6000", "Extra high preset")
try controller.select(.medium, settings: settings)
check(device.calls.last == "rpm 4000", "Medium preset is a fixed 4000 RPM, not a hardware percentage")
try controller.select(.full, settings: settings)
check(device.calls.last == "full", "Full preset")
try controller.select(.guardMode, settings: lowSettings)
device.temp = 56
controller.tick(now: 5)
check(controller.mode == .guardMode && controller.reply.smoothedTemperature != nil, "Guard reports control temperature")
let autoWritesBefore = device.calls.filter { $0 == "auto" }.count
for index in 1...15 {
    device.temp = index % 2 == 0 ? 49 : 56
    controller.tick(now: Double(index + 1) * 5)
    check(controller.mode == .guardMode, "Temperature swings must not disable guard")
    check(controller.output != .automatic, "Guard must continuously command RPM")
}
check(device.calls.filter { $0 == "auto" }.count == autoWritesBefore, "Threshold crossings must not write automatic mode")
let filterBefore = controller.regulator.smoothedTemperature
try controller.select(.guardMode, settings: Settings(target: 55, maxRPM: 7800, curve: .exponential))
check(controller.regulator.smoothedTemperature == filterBefore, "Settings updates preserve regulator state")
device.temp = 93
controller.tick(now: 90)
check(device.calls.last == "full", "Emergency reaches hardware immediately")
device.temp = 91
controller.tick(now: 95)
check(device.calls.last == "full", "Emergency remains latched above 88 C")
device.temp = 70
controller.tick(now: 100)
check(controller.output != .automatic, "Cooling reduces speed, never returns to auto")
try controller.select(.auto, settings: settings)
check(device.calls.last == "auto", "Explicit Automatic releases control")
try controller.select(.guardMode, settings: settings)
device.sensorFailure = true
controller.tick(now: 105)
check(controller.mode == .auto && controller.reply.error != nil && device.calls.last == "auto", "Sensor error stops guard and restores auto")
device.sensorFailure = false
try controller.select(.guardMode, settings: settings)
device.writeFailure = true
controller.tick(now: 110)
check(controller.mode == .auto && device.calls.last == "auto", "Partial write failure restores auto")
device.writeFailure = false
device.autoFailure = true
controller.fail("Test failure")
check(controller.reply.error?.contains("Restoring auto FAILED") == true, "Cleanup errors must be visible")
device.autoFailure = false
try controller.stop()
check(device.calls.last == "auto", "Quit restores automatic")

// Shared inline speed/temperature controls and hardware-resolved caps.
for (index, speed) in FanMode.sliderModes.enumerated() {
    check(speed.sliderIndex == index && FanMode.sliderMode(value: Double(index)) == speed, "Speed slider stop mapping")
    var selection = FanControlSelection(speed: speed)
    check(selection.mode == speed, "Temperature Off uses fixed-speed behavior")
    selection.temperature = 55
    check(selection.mode == .guardMode, "Every speed stop becomes a cap while a target is active")
    selection.temperature = nil
    check(selection.mode == speed, "Off returns to the selected speed")
}
check(FanMode.sliderMode(value: .nan) == .auto && FanMode.sliderMode(value: -50) == .auto, "Invalid speed slider input stays safe")
check(FanMode.sliderMode(value: Double.greatestFiniteMagnitude) == .full, "Speed slider clamps before integer conversion")
check(FanControlSelection.temperature(value: 0) == nil && FanControlSelection.temperature(value: .nan) == nil, "Zero and invalid temperature slider input are Off")
check(FanControlSelection.temperature(value: 1) == 30 && FanControlSelection.temperature(value: 56) == 85, "Temperature slider endpoints")
check(FanControlSelection.temperature(value: 100) == 85 && FanControlSelection.temperature(value: -1) == nil, "Temperature slider bounds")
check(oldSettings.speedCap == nil, "Old saved settings retain their exact legacy RPM cap")
for (speed, expected) in [(FanMode.medium, 4000.0), (.high, 5000), (.xhigh, 6000), (.full, 7800)] {
    let setting = Settings(target: 55, curve: .linear, speedCap: speed)
    let resolved = try setting.resolvingSpeedCap(minimumRPM: 2400, maximumRPM: 7800)
    check(resolved.maxRPM == expected, "Speed-cap presets resolve against hardware")
    check(try GuardCurve().output(temperature: 65, settings: resolved) == .rpm(expected), "Temperature curve reaches the selected speed cap")
    check(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(setting)) == setting, "Speed-cap selection survives IPC and preferences encoding")
    let capDevice = FakeDevice()
    capDevice.rpms = [7800, 7800]
    let capController = FanController(device: capDevice)
    try capController.select(.guardMode, settings: setting)
    capController.tick(now: 0)
    check(capController.mode == .guardMode && requestedRPM(capController.output!) <= expected && capController.reply.error == nil,
          "Cap selection remains temperature regulation, not a fixed-speed write")
    capDevice.temp = 93
    capController.tick(now: 5)
    check(capDevice.calls.last == "full", "Emergency bypasses every shared speed cap")
}
let mediumCap = Settings(speedCap: .medium)
check(try mediumCap.resolvingSpeedCap(minimumRPM: 4200, maximumRPM: 7800).maxRPM == 4200, "Medium cap never drops below hardware minimum")
check(try mediumCap.resolvingSpeedCap(minimumRPM: 2400, maximumRPM: 3500).maxRPM == 3500, "Medium cap never exceeds a lower hardware maximum")
expectError("Automatic is unavailable as a temperature-control cap") { _ = try Settings(speedCap: .auto).resolvingSpeedCap(minimumRPM: 2400, maximumRPM: 7800) }
check(try Settings(speedCap: .xhigh).resolvingSpeedCap(minimumRPM: 2400, maximumRPM: 4500).maxRPM == 4500, "Fixed-RPM caps never exceed hardware maximum")
expectError("Reject a temperature mode as a speed cap") { try Settings(speedCap: .guardMode).validate() }
expectError("Reject unreadable hardware maximum") { _ = try mediumCap.resolvingSpeedCap(minimumRPM: 2400, maximumRPM: .nan) }
expectError("Reject incompatible hardware limits") { _ = try mediumCap.resolvingSpeedCap(minimumRPM: 5000, maximumRPM: 4000) }
expectError("Legacy caps still reject out-of-range values") { try Settings(maxRPM: 500).validate() }

let invalidCapDevice = FakeDevice()
let invalidCapController = FanController(device: invalidCapDevice)
expectError("Controller rejects Auto as a cap before taking ownership") {
    try invalidCapController.select(.guardMode, settings: Settings(speedCap: .auto))
}
check(invalidCapDevice.calls.isEmpty && !invalidCapController.ownsFans, "An invalid Auto cap performs no fan writes")

// Real Unix-socket regression, without sudo or actual fan writes.
func testSlowReply() throws {
    let path = "/tmp/fan-menu-test-\(UUID().uuidString).sock"
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw "Cannot create test socket" }
    defer { close(listener); unlink(path) }
    var address = try socketAddress(path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0, listen(listener, 1) == 0 else { throw "Cannot listen on test socket" }
    _ = fcntl(listener, F_SETFL, O_NONBLOCK)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { finished.signal() }
        var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&readiness, 1, 5000) > 0 else { return }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        configureTimeout(client)
        do {
            let request = try JSONDecoder().decode(Request.self, from: receiveData(fd: client))
            Thread.sleep(forTimeInterval: 2.5)
            let blocking = (fcntl(client, F_GETFL) & O_NONBLOCK) == 0
            var data = try JSONEncoder().encode(Reply(mode: .guardMode, output: request.settings?.curve.rawValue ?? "missing",
                                                    error: blocking ? nil : "Accepted socket is nonblocking"))
            data.append(10)
            try sendData(data, fd: client)
        } catch { }
    }
    let started = ProcessInfo.processInfo.systemUptime
    let reply = try queryWorker(path: path, request: Request(command: "guard", settings: Settings(curve: .logarithmic)))
    check(ProcessInfo.processInfo.systemUptime - started >= 2.4, "Regression must exceed the old timeout")
    check(reply.mode == .guardMode, "Slow reply must arrive successfully")
    check(reply.output == "logarithmic", "Selected curve must cross IPC correctly")
    check(reply.error == nil, "Accepted sockets must clear inherited O_NONBLOCK on macOS")
    guard finished.wait(timeout: .now() + 5) == .success else { throw "Mock controller did not finish" }
}
try testSlowReply()
print("\(checks) controller and IPC checks passed")
