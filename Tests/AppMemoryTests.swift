// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

let appMemoryChecksStart = checks
let appMemoryUID: UInt32 = 501
func sampleProcess(_ pid: Int32, _ parent: Int32, _ path: String, _ bytes: UInt64?, uid: UInt32 = 501,
                   seconds: UInt64 = 100) -> MemoryProcess {
    MemoryProcess(stamp: MemoryProcessStamp(pid: pid, seconds: seconds, microseconds: 50),
                  parentPID: parent, uid: uid, executablePath: path, footprint: bytes)
}
let nebula = MemoryAppIdentity(pid: 10, name: "Nébula Editor", bundlePath: "/Applications/Nebula.app",
                               executablePath: "/Applications/Nebula.app/Contents/MacOS/nebula")
let lantern = MemoryAppIdentity(pid: 20, name: "Lantern", bundlePath: "/Applications/Lantern.app",
                                executablePath: "/Applications/Lantern.app/Contents/MacOS/main")
let nebulaMain = sampleProcess(10, 1, nebula.executablePath, 100)
let lanternMain = sampleProcess(20, 1, lantern.executablePath, 200)
let nebulaHelper = sampleProcess(11, 1, "/Applications/Nebula.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", 300)
let externalChild = sampleProcess(12, 10, "/opt/runtime/bin/node", 400)
let grandchild = sampleProcess(13, 12, "/opt/workers/custom-agent", 500)
let nestedIdentity = MemoryAppIdentity(pid: 11, name: "Noisy Helper", bundlePath: "/Applications/Nebula.app/Contents/Frameworks/Helper.app",
                                       executablePath: nebulaHelper.executablePath)
let baseProcesses = [nebulaMain, lanternMain, nebulaHelper, externalChild, grandchild]
let grouped = AppMemoryGrouping.group(apps: [nebula, lantern, nestedIdentity], processes: baseProcesses, uid: appMemoryUID)
check(grouped.count == 2, "Nested helpers must not appear as separate apps")
check(grouped[0].name == "Nébula Editor" && grouped[0].bytes == 1300, "Use metadata names and group helpers and descendants without name matching")
check(grouped[1].name == "Lantern" && grouped[1].bytes == 200, "Rank by descending attributed footprint")
check(grouped[0].quitTargets.count == 1 && grouped[0].quitTargets[0].stamp.pid == 10, "Quit must target only the main app, not helper processes")
check(grouped[0].fraction(relativeTo: 1300) == 1, "Largest app fills the comparison bar")
check(abs(grouped[1].fraction(relativeTo: 1300) - 200.0 / 1300) < 1e-10, "Bars represent relative app memory")
check(grouped[0].fraction(relativeTo: 0) == 0 && grouped[0].fraction(relativeTo: 1) == 1, "Comparison fractions are bounded")
let unassigned = [sampleProcess(30, 1, "/opt/unknown", 999999),
                  sampleProcess(31, 1, "/Applications/Nebula.app-other/Contents/main", 999999),
                  sampleProcess(32, 1, "/Applications/Nebula.app/Contents/foreign", 999999, uid: 999),
                  sampleProcess(33, 10, "/opt/foreign-child", 999999, uid: 999)]
let withUnknowns = AppMemoryGrouping.group(apps: [nebula, lantern], processes: baseProcesses + unassigned, uid: appMemoryUID)
check(withUnknowns.map { $0.bytes } == grouped.map { $0.bytes }, "Unattributed, foreign-user and prefix-lookalike processes must be excluded")
let cycles = [sampleProcess(40, 41, "/opt/a", 100), sampleProcess(41, 40, "/opt/b", 100)]
check(AppMemoryGrouping.group(apps: [nebula], processes: [nebulaMain] + cycles, uid: appMemoryUID).first?.bytes == 100,
      "Cyclic parent chains terminate without inventing an owner")
let denied = sampleProcess(11, 10, nebulaHelper.executablePath, nil)
check(AppMemoryGrouping.group(apps: [nebula], processes: [nebulaMain, denied], uid: appMemoryUID).first?.bytes == 100,
      "Unreadable footprints must not fall back to misleading resident memory")
let deniedMain = sampleProcess(10, 1, nebula.executablePath, nil)
check(AppMemoryGrouping.group(apps: [nebula], processes: [deniedMain, nebulaHelper], uid: appMemoryUID).first?.bytes == 300,
      "Readable helpers can still be attributed to a verified app with an unreadable main footprint")
check(AppMemoryGrouping.group(apps: [nebula], processes: [lanternMain, nebulaHelper], uid: appMemoryUID).isEmpty,
      "An exited or unverified main app cannot become a quit target")
let wrongMain = sampleProcess(10, 1, "/opt/reused-pid", 100)
check(AppMemoryGrouping.group(apps: [nebula], processes: [wrongMain, nebulaHelper], uid: appMemoryUID).isEmpty,
      "Executable identity must match the running app")
let target = grouped[0].quitTargets[0]
check(target.matches(nebulaMain, uid: appMemoryUID), "Unchanged process identity may be quit")
check(!target.matches(sampleProcess(10, 1, nebula.executablePath, 100, seconds: 101), uid: appMemoryUID),
      "PID reuse must not quit a newly launched app")
check(!target.matches(sampleProcess(10, 1, "/opt/replacement", 100), uid: appMemoryUID), "Changed executable must not be quit")
check(!target.matches(sampleProcess(10, 1, nebula.executablePath, 100, uid: 999), uid: appMemoryUID), "Foreign-user apps must never be quit")
let secondInstance = MemoryAppIdentity(pid: 15, name: nebula.name, bundlePath: nebula.bundlePath, executablePath: nebula.executablePath)
let multiple = AppMemoryGrouping.group(apps: [nebula, secondInstance],
    processes: [nebulaMain, sampleProcess(15, 1, nebula.executablePath, 200)], uid: appMemoryUID)
check(multiple.count == 1 && multiple[0].bytes == 300 && multiple[0].quitTargets.count == 2, "Multiple instances of one bundle share one app row")
let duplicate = AppMemoryGrouping.group(apps: [nebula], processes: [nebulaMain, nebulaMain, nebulaHelper], uid: appMemoryUID)
check(duplicate[0].bytes == 400, "Each PID must count only once")
let overflow = AppMemoryGrouping.group(apps: [nebula], processes: [sampleProcess(10, 1, nebula.executablePath, .max), nebulaHelper], uid: appMemoryUID)
check(overflow[0].bytes == .max, "Aggregating memory must not overflow")
let separate = MemoryAppIdentity(pid: 21, name: "Nébula Editor", bundlePath: "/Applications/Other.app", executablePath: "/Applications/Other.app/Contents/main")
let sameNames = AppMemoryGrouping.group(apps: [nebula, separate], processes: [nebulaMain, sampleProcess(21, 1, separate.executablePath, 100)], uid: appMemoryUID)
check(sameNames.count == 2, "Identical display names must not merge unrelated apps")
var manyApps: [MemoryAppIdentity] = []
var manyProcesses: [MemoryProcess] = []
for i in 0..<15 {
    let app = MemoryAppIdentity(pid: Int32(100 + i), name: "App \(i)", bundlePath: "/Applications/App\(i).app", executablePath: "/Applications/App\(i).app/Contents/main")
    manyApps.append(app)
    manyProcesses.append(sampleProcess(app.pid, 1, app.executablePath, UInt64(i + 1)))
}
let topTen = AppMemoryGrouping.group(apps: manyApps, processes: manyProcesses, uid: appMemoryUID)
check(topTen.count == 10 && topTen.first?.bytes == 15 && topTen.last?.bytes == 6, "Keep the ten largest apps")
check(AppMemoryGrouping.group(apps: [], processes: manyProcesses, uid: appMemoryUID).isEmpty, "No recognizable apps means no actionable rows")
check(AppMemoryUsage(name: "x", bundlePath: "x", bytes: 1 << 30, quitTargets: []).formattedBytes == "1.0 GB", "Use binary GB for larger app footprints")
check(AppMemoryUsage(name: "x", bundlePath: "x", bytes: 10 << 20, quitTargets: []).formattedBytes == "10 MB", "Use readable MB for small apps")
if let live = LiveAppMemoryReader.process(getpid()) {
    check(live.uid == getuid() && live.footprint != nil && !live.executablePath.isEmpty, "Native footprint reads require no administrator permission")
} else { fatalError("Cannot read test process identity") }
print("\(checks - appMemoryChecksStart) app-memory grouping and identity checks passed")
