// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import Foundation

struct ProcessorHistoryValue {
    var cpu: Double?
    var gpu: Double?
}

struct ProcessorHistorySample {
    let timestamp: Double
    let value: ProcessorHistoryValue
}

struct ProcessorHistory {
    static let duration = 300.0
    static let capacity = 151
    static let maximumCoverage = 6.0
    private(set) var samples: [ProcessorHistorySample] = []

    mutating func record(_ snapshot: ProcessorSnapshot, at timestamp: Double) {
        guard timestamp.isFinite else { return }
        if let last = samples.last, timestamp < last.timestamp { clear() }
        samples.removeAll { $0.timestamp < timestamp - Self.duration }
        if samples.last?.timestamp == timestamp { samples.removeLast() }
        func valid(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        }
        let validCPU = snapshot.cpu.flatMap { cores -> Double? in
            guard !cores.isEmpty, cores.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
            return snapshot.cpuMean
        }
        samples.append(ProcessorHistorySample(timestamp: timestamp,
            value: ProcessorHistoryValue(cpu: valid(validCPU), gpu: valid(snapshot.gpu))))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    // Each narrow column retains the highest sampled utilization in its time
    // interval, so downsampling does not erase a brief two-second spike.
    func columns(count: Int, until now: Double) -> [ProcessorHistoryValue] {
        guard count > 0, count <= 4096, now.isFinite else { return [] }
        var columns = Array(repeating: ProcessorHistoryValue(cpu: nil, gpu: nil), count: count)
        let start = now - Self.duration
        for (index, sample) in samples.enumerated() {
            let next = index + 1 < samples.count ? samples[index + 1].timestamp : now
            let low = max(start, sample.timestamp)
            let high = min(now, min(next, sample.timestamp + Self.maximumCoverage))
            guard high > low else { continue }
            let first = min(count - 1, max(0, Int(floor((low - start) / Self.duration * Double(count)))))
            let last = min(count - 1, max(0, Int(ceil((high - start) / Self.duration * Double(count))) - 1))
            guard last >= first else { continue }
            for column in first...last {
                if let cpu = sample.value.cpu { columns[column].cpu = max(columns[column].cpu ?? 0, cpu) }
                if let gpu = sample.value.gpu { columns[column].gpu = max(columns[column].gpu ?? 0, gpu) }
            }
        }
        return columns
    }

    mutating func clear() { samples.removeAll() }
}
