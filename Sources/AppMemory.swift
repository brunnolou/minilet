// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import Foundation
import Darwin

struct MemoryProcessStamp: Equatable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
}

struct MemoryProcess {
    let stamp: MemoryProcessStamp
    let parentPID: Int32
    let uid: UInt32
    let executablePath: String
    let footprint: UInt64?
}

struct MemoryAppIdentity {
    let pid: Int32
    let name: String
    let bundlePath: String
    let executablePath: String
}

struct MemoryQuitTarget {
    let stamp: MemoryProcessStamp
    let bundlePath: String
    let executablePath: String

    func matches(_ process: MemoryProcess, uid: UInt32) -> Bool {
        process.uid == uid && process.stamp == stamp && process.executablePath == executablePath
    }
}

struct AppMemoryUsage {
    let name: String
    let bundlePath: String
    let bytes: UInt64
    let quitTargets: [MemoryQuitTarget]

    func fraction(relativeTo largest: UInt64) -> Double {
        largest == 0 ? 0 : min(1, Double(bytes) / Double(largest))
    }

    var formattedBytes: String {
        if bytes >= 1 << 30 { return "\(MemoryFormat.gigabytes(bytes)) GB" }
        return "\(max(1, Int((Double(bytes) / Double(1 << 20)).rounded()))) MB"
    }
}

enum AppMemoryGrouping {
    static let limit = 10

    static func contains(_ executable: String, in bundle: String) -> Bool {
        !bundle.isEmpty && executable.hasPrefix(bundle + "/")
    }

    static func group(apps: [MemoryAppIdentity], processes: [MemoryProcess], uid: UInt32,
                      limit: Int? = AppMemoryGrouping.limit) -> [AppMemoryUsage] {
        var byPID: [Int32: MemoryProcess] = [:]
        for process in processes where process.uid == uid { byPID[process.stamp.pid] = process }
        // Only a verified running app is an owner. A helper's bundle metadata
        // alone is not permission to offer Quit for an arbitrary process.
        let verified = apps.filter { app in
            guard let process = byPID[app.pid] else { return false }
            return !app.name.isEmpty && contains(app.executablePath, in: app.bundlePath)
                && process.executablePath == app.executablePath
        }
        // Electron and other nested helper apps belong to their outer app.
        let owners = verified.filter { app in
            !verified.contains { outer in
                outer.bundlePath != app.bundlePath && contains(app.bundlePath, in: outer.bundlePath)
            }
        }
        var appsByPID: [Int32: MemoryAppIdentity] = [:]
        var appsByBundle: [String: [MemoryAppIdentity]] = [:]
        for app in owners {
            appsByPID[app.pid] = app
            appsByBundle[app.bundlePath, default: []].append(app)
        }
        let bundlePaths = appsByBundle.keys.sorted { $0.count > $1.count }
        func directOwner(_ process: MemoryProcess) -> String? {
            if let app = appsByPID[process.stamp.pid] { return app.bundlePath }
            return bundlePaths.first { contains(process.executablePath, in: $0) }
        }
        var totals: [String: UInt64] = [:]
        for process in byPID.values {
            guard let footprint = process.footprint, footprint > 0 else { continue }
            var owner = directOwner(process)
            var ancestor = process
            var visited: Set<Int32> = [process.stamp.pid]
            while owner == nil, let parent = byPID[ancestor.parentPID], visited.insert(parent.stamp.pid).inserted {
                ancestor = parent
                owner = directOwner(parent)
            }
            guard let bundle = owner else { continue }
            let sum = (totals[bundle] ?? 0).addingReportingOverflow(footprint)
            totals[bundle] = sum.overflow ? .max : sum.partialValue
        }
        let ranked = totals.compactMap { bundle, bytes -> AppMemoryUsage? in
            guard let instances = appsByBundle[bundle], let app = instances.first else { return nil }
            let targets = instances.compactMap { instance -> MemoryQuitTarget? in
                guard let process = byPID[instance.pid] else { return nil }
                return MemoryQuitTarget(stamp: process.stamp, bundlePath: bundle, executablePath: instance.executablePath)
            }
            return AppMemoryUsage(name: app.name, bundlePath: bundle, bytes: bytes, quitTargets: targets)
        }.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            let names = $0.name.localizedStandardCompare($1.name)
            return names == .orderedSame ? $0.bundlePath < $1.bundlePath : names == .orderedAscending
        }
        return limit.map { Array(ranked.prefix(max(0, $0))) } ?? ranked
    }
}

struct LiveAppMemoryReader {
    static func process(_ pid: Int32) -> MemoryProcess? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_pid == UInt32(pid) else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is a C macro Swift cannot import.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        let executable = length > 0 ? URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path : ""
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        // Reject records if the PID exited or was reused between these reads.
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
              info.pbi_start_tvsec == after.pbi_start_tvsec,
              info.pbi_start_tvusec == after.pbi_start_tvusec else { return nil }
        return MemoryProcess(stamp: MemoryProcessStamp(pid: pid, seconds: info.pbi_start_tvsec,
                                                      microseconds: info.pbi_start_tvusec),
                             parentPID: Int32(info.pbi_ppid), uid: info.pbi_uid,
                             executablePath: executable, footprint: result == 0 ? usage.ri_phys_footprint : nil)
    }

    func read(apps: [MemoryAppIdentity], limit: Int? = AppMemoryGrouping.limit) throws -> [AppMemoryUsage] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw MemoryReadError.unavailable("Cannot read running apps") }
        var pids = [Int32](repeating: 0, count: Int(count) + 1024)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { throw MemoryReadError.unavailable("Cannot read running apps") }
        let uid = getuid()
        let processes = pids.prefix(min(Int(actual), pids.count)).compactMap { pid -> MemoryProcess? in
            guard pid > 0, let process = Self.process(pid), process.uid == uid else { return nil }
            return process
        }
        return AppMemoryGrouping.group(apps: apps, processes: processes, uid: uid, limit: limit)
    }
}
