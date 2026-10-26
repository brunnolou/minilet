// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

var workerLaunchChecks = 0
func launchCheck(_ condition: Bool, _ message: String) {
    workerLaunchChecks += 1
    precondition(condition, message)
}
let launchFixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("minilet-launch-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: launchFixtureDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: launchFixtureDirectory) }
let launchFixturePID = launchFixtureDirectory.appendingPathComponent("ready-pid")
let launchStart = ProcessInfo.processInfo.systemUptime
try WorkerLaunch.start(executable: CommandLine.arguments[0], arguments: ["--launch-test-ready", launchFixturePID.path], timeout: 3)
let fixturePID = pid_t(try String(contentsOf: launchFixturePID, encoding: .utf8))!
launchCheck(ProcessInfo.processInfo.systemUptime - launchStart < 3, "Launcher exits after readiness, not after the worker session")
launchCheck(kill(fixturePID, 0) == 0, "Session child remains alive after the startup launcher returns")
kill(fixturePID, SIGTERM)
do {
    try WorkerLaunch.start(executable: CommandLine.arguments[0], arguments: ["--launch-test-failure"], timeout: 3)
    preconditionFailure("A failed worker must not look ready")
} catch {
    launchCheck(String(describing: error).contains("Fixture startup failed"), "Startup failures keep their diagnostic message")
}
let timeoutPIDFile = launchFixtureDirectory.appendingPathComponent("timeout-pid")
do {
    try WorkerLaunch.start(executable: CommandLine.arguments[0], arguments: ["--launch-test-timeout", timeoutPIDFile.path], timeout: 1)
    preconditionFailure("An unready worker must time out")
} catch {
    launchCheck(String(describing: error).contains("timed out"), "Worker startup has a bounded timeout")
    if let raw = try? String(contentsOf: timeoutPIDFile, encoding: .utf8), let pid = pid_t(raw) {
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { break }
            usleep(10_000)
        }
        launchCheck(kill(pid, 0) != 0, "Startup timeout terminates the unready child")
    }
}
do {
    try WorkerLaunch.start(executable: "/minilet-nonexistent-executable", arguments: [])
    preconditionFailure("A missing worker executable must fail")
} catch { launchCheck(true, "Spawn failures return instead of hanging") }
let approvalPIDFile = launchFixtureDirectory.appendingPathComponent("approval-pid")
let approval = Process()
approval.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
let quoteShell: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
let command = [URL(fileURLWithPath: CommandLine.arguments[0]).path, "--launch-test-launcher", approvalPIDFile.path].map(quoteShell).joined(separator: " ")
let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
approval.arguments = ["-e", "do shell script \"\(escaped)\""]
approval.standardOutput = FileHandle.nullDevice
approval.standardError = FileHandle.nullDevice
try approval.run()
let approvalDeadline = ProcessInfo.processInfo.systemUptime + 5
while approval.isRunning && ProcessInfo.processInfo.systemUptime < approvalDeadline { usleep(10_000) }
let returned = !approval.isRunning
if !returned { approval.terminate() }
launchCheck(returned && approval.terminationStatus == 0, "AppleScript returns after readiness instead of polling for the entire session")
if let raw = try? String(contentsOf: approvalPIDFile, encoding: .utf8), let pid = pid_t(raw) {
    launchCheck(kill(pid, 0) == 0, "The session remains running after AppleScript exits")
    kill(pid, SIGTERM)
} else { preconditionFailure("AppleScript must have started the fixture") }
var monitorCreations = 0
let monitorDevice = FakeDevice()
let cachedMonitor = LiveFanMonitor(makeDevice: { monitorCreations += 1; return monitorDevice })
let firstMonitorRead = try cachedMonitor.read()
monitorDevice.temp = 71
let secondMonitorRead = try cachedMonitor.read()
launchCheck(monitorCreations == 1 && firstMonitorRead.temperature == 65 && secondMonitorRead.temperature == 71,
            "Monitoring reuses its connection but still samples fresh temperatures")
launchCheck(monitorDevice.calls.isEmpty, "The reusable monitor never writes fan controls")
monitorDevice.sensorFailure = true
do { _ = try cachedMonitor.read(); preconditionFailure("Failed sensors must be reported") } catch { }
monitorDevice.sensorFailure = false
_ = try cachedMonitor.read()
launchCheck(monitorCreations == 2, "Monitoring recreates its connection after a read error")
cachedMonitor.reset()
_ = try cachedMonitor.read()
launchCheck(monitorCreations == 3, "Wake/controller transfer discards the old monitoring connection")
print("\(workerLaunchChecks) worker-launch and monitoring checks passed")
