// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import Foundation
import Darwin
import IOKit

struct ProcessorSnapshot {
    var cpu: [Double]?
    var gpu: Double?

    var cpuMean: Double? {
        guard let cpu = cpu, !cpu.isEmpty else { return nil }
        return cpu.reduce(0, +) / Double(cpu.count)
    }

    static func percent(_ value: Double?) -> String {
        guard let value = value, value.isFinite, (0...1).contains(value) else { return "Unavailable" }
        return "\(Int((value * 100).rounded()))%"
    }

    var cpuDescription: String {
        let usage = Self.percent(cpuMean)
        return cpu.map { "\(usage) · \($0.count) cores" } ?? usage
    }
}

struct ProcessorTicks {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    func utilization(since previous: ProcessorTicks) -> Double? {
        let deltas = [user &- previous.user, system &- previous.system,
                      idle &- previous.idle, nice &- previous.nice]
        // Valid short samples may wrap UInt32. A backwards counter reset must
        // not look like billions of ticks of CPU activity.
        guard deltas.allSatisfy({ $0 <= UInt32(Int32.max) }) else { return nil }
        let total = deltas.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { return nil }
        let busy = UInt64(deltas[0]) + UInt64(deltas[1]) + UInt64(deltas[3])
        return Double(busy) / Double(total)
    }
}

struct ProcessorSampler {
    private var previous: [ProcessorTicks]?
    private var previousTime: Double?

    mutating func reset() { previous = nil; previousTime = nil }

    mutating func sample(_ ticks: [ProcessorTicks], at time: Double) -> [Double]? {
        guard time.isFinite, !ticks.isEmpty else { reset(); return nil }
        defer { previous = ticks; previousTime = time }
        guard let previous = previous, let previousTime = previousTime,
              previous.count == ticks.count, time > previousTime, time - previousTime <= 6 else { return nil }
        var result: [Double] = []
        for (current, old) in zip(ticks, previous) {
            guard let usage = current.utilization(since: old) else { return nil }
            result.append(usage)
        }
        return result
    }
}

enum ProcessorTiles {
    static let count = 8

    static func opacities(_ usages: [Double]?, count: Int = count) -> [Double] {
        guard count > 0 else { return [] }
        guard let usages = usages, !usages.isEmpty,
              usages.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            return Array(repeating: 0, count: count)
        }
        // Each core covers its own prefix of the row. Overlapping prefixes
        // contribute 1/coreCount opacity. Fractional edge tiles preserve usage.
        return (0..<count).map { tile in
            usages.reduce(0) { $0 + min(1, max(0, $1 * Double(count) - Double(tile))) } / Double(usages.count)
        }
    }
}

final class LiveProcessorReader {
    private var sampler = ProcessorSampler()

    func reset() { sampler.reset() }

    func read() -> ProcessorSnapshot {
        let cpu: [Double]?
        do { cpu = sampler.sample(try Self.cpuTicks(), at: ProcessInfo.processInfo.systemUptime) }
        catch { sampler.reset(); cpu = nil }
        return ProcessorSnapshot(cpu: cpu, gpu: Self.gpuUsage())
    }

    static func cpuTicks() throws -> [ProcessorTicks] {
        var processors: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processors, &info, &count)
        defer {
            if let info = info, count > 0 {
                vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                              vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
            }
        }
        guard status == KERN_SUCCESS, let info = info, processors > 0, processors <= 4096,
              Int(count) >= Int(processors) * Int(CPU_STATE_MAX) else { throw "CPU counters unavailable" }
        return (0..<Int(processors)).map { index in
            let offset = index * Int(CPU_STATE_MAX)
            return ProcessorTicks(user: UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]),
                                  system: UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]),
                                  idle: UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]),
                                  nice: UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
        }
    }

    static func gpuFraction(_ statistics: [String: Any]) -> Double? {
        guard let number = statistics["Device Utilization %"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, (0...100).contains(value) else { return nil }
        return value / 100
    }

    static func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("AGXAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var usages: [Double] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                                kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let statistics = property as? [String: Any], let usage = gpuFraction(statistics) else { continue }
            usages.append(usage)
        }
        // On machines with multiple accelerators, show the busiest readable
        // device. This is aggregate GPU usage, never fabricated per-core data.
        return usages.max()
    }
}
