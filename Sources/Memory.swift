// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import Foundation
import Darwin

enum MemoryPressure: String, CaseIterable {
    case normal, warning, critical, unknown

    init(kernelLevel: Int32?) {
        switch kernelLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .unknown: return "Unavailable"
        }
    }
}

struct MemorySnapshot {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let compressedBytes: UInt64
    let swapUsedBytes: UInt64?
    let pressure: MemoryPressure
    let timestamp: Double

    var compactUsage: String { "\(MemoryFormat.gigabytes(usedBytes))/\(MemoryFormat.capacity(totalBytes)) GB" }
    var usageFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }
}

enum MemoryFormat {
    // macOS memory tools use binary gigabytes, unlike disk-capacity marketing.
    static let gib = Double(1 << 30)
    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(bytes) / gib)
    }
    static func capacity(_ bytes: UInt64) -> String {
        let value = Double(bytes) / gib
        if value.rounded() == value {
            return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        return gigabytes(bytes)
    }
    static func temperatureTitle(_ temperature: Double?) -> String {
        if let temperature = temperature, temperature.isFinite, temperature > 0, temperature < 125 {
            return "\(Int(temperature.rounded()))°"
        }
        return "--°"
    }
}

struct MemoryCounters {
    let active: UInt64
    let inactive: UInt64
    let speculative: UInt64
    let wired: UInt64
    let compressor: UInt64
    let purgeable: UInt64
    let fileBacked: UInt64

    func snapshot(totalBytes: UInt64, pageSize: UInt64, swapUsed: UInt64?,
                  pressure: MemoryPressure, timestamp: Double) throws -> MemorySnapshot {
        guard totalBytes > 0, totalBytes <= UInt64(Int64.max), pageSize > 0,
              pageSize <= 1 << 20, timestamp.isFinite else {
            throw MemoryReadError.unavailable("Invalid memory statistics")
        }
        // Physical app/wired/compressor usage, excluding reclaimable file-backed
        // and purgeable memory. Speculative pages are included in fileBacked.
        // Compressor pages are physical storage, not their uncompressed size.
        let resident = Double(active) + Double(inactive) + Double(speculative)
            + Double(wired) + Double(compressor)
        let occupied = max(0, resident - Double(fileBacked) - Double(purgeable)) * Double(pageSize)
        let used = min(totalBytes, UInt64(min(Double(totalBytes), occupied)))
        let product = compressor.multipliedReportingOverflow(by: pageSize)
        let compressed = product.overflow ? totalBytes : min(totalBytes, product.partialValue)
        return MemorySnapshot(totalBytes: totalBytes, usedBytes: used, compressedBytes: compressed,
                              swapUsedBytes: swapUsed, pressure: pressure, timestamp: timestamp)
    }
}

enum MemoryReadError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

struct LiveMemoryReader {
    // All reads are unprivileged. No fan worker, external command or Python.
    func read() throws -> MemorySnapshot {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else {
            throw MemoryReadError.unavailable("Cannot read memory page size")
        }
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        // Older kernels may return rev1 rather than the SDK's newer rev2.
        // Require only the fields we actually read, not swapped_count at the end.
        guard let lastField = MemoryLayout<vm_statistics64_data_t>.offset(of: \.external_page_count) else {
            throw MemoryReadError.unavailable("Unknown virtual-memory layout")
        }
        let required = mach_msg_type_number_t((lastField + MemoryLayout<natural_t>.size) / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count >= required else {
            throw MemoryReadError.unavailable("Cannot read virtual-memory statistics")
        }
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        let hasPressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0
            && levelSize == MemoryLayout<Int32>.size
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
            && swapSize == MemoryLayout<xsw_usage>.size
        let counters = MemoryCounters(active: UInt64(statistics.active_count), inactive: UInt64(statistics.inactive_count),
                                      speculative: UInt64(statistics.speculative_count), wired: UInt64(statistics.wire_count),
                                      compressor: UInt64(statistics.compressor_page_count), purgeable: UInt64(statistics.purgeable_count),
                                      fileBacked: UInt64(statistics.external_page_count))
        return try counters.snapshot(totalBytes: ProcessInfo.processInfo.physicalMemory, pageSize: UInt64(pageSize),
                                     swapUsed: hasSwap ? swap.xsu_used : nil,
                                     pressure: MemoryPressure(kernelLevel: hasPressure ? level : nil),
                                     timestamp: ProcessInfo.processInfo.systemUptime)
    }
}

struct PressureSample {
    let timestamp: Double
    let pressure: MemoryPressure
}

struct PressureSpan {
    let start: Double
    var end: Double
    let pressure: MemoryPressure
}

struct PressureHistory {
    static let duration = 300.0
    static let capacity = 151
    private(set) var samples: [PressureSample] = []

    mutating func record(_ pressure: MemoryPressure, at timestamp: Double) {
        guard timestamp.isFinite else { return }
        if let last = samples.last, timestamp < last.timestamp { samples.removeAll() }
        samples.removeAll { $0.timestamp < timestamp - Self.duration }
        if samples.last?.timestamp == timestamp { samples.removeLast() }
        samples.append(PressureSample(timestamp: timestamp, pressure: pressure))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    func spans(until now: Double) -> [PressureSpan] {
        guard now.isFinite else { return [] }
        var spans: [PressureSpan] = []
        let windowStart = now - Self.duration
        for (index, sample) in samples.enumerated() {
            let next = index + 1 < samples.count ? samples[index + 1].timestamp : now
            let beginning = max(windowStart, sample.timestamp)
            let end = min(now, min(next, sample.timestamp + 6))
            guard end > beginning else { continue }
            if let last = spans.last, last.pressure == sample.pressure, abs(last.end - beginning) < 0.0001 {
                spans[spans.count - 1].end = end
            } else {
                spans.append(PressureSpan(start: beginning, end: end, pressure: sample.pressure))
            }
        }
        return spans
    }

    mutating func clear() { samples.removeAll() }
}
