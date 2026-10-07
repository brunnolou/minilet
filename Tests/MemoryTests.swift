// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

let memoryChecksStart = checks
let page = UInt64(16384)
let memoryCounters = MemoryCounters(active: 80, inactive: 20, speculative: 10, wired: 10,
                                   compressor: 10, purgeable: 5, fileBacked: 30)
let memorySnapshot = try memoryCounters.snapshot(totalBytes: 100 * page, pageSize: page,
                                                swapUsed: 16 * page, pressure: .normal, timestamp: 10)
check(memorySnapshot.usedBytes == 95 * page, "Used RAM must exclude file cache and purgeable pages")
check(memorySnapshot.compressedBytes == 10 * page, "Compressed RAM must count physical compressor pages")
check(memorySnapshot.swapUsedBytes == 16 * page, "Swap is separate from physical RAM")
check(memorySnapshot.pressure == .normal, "95% used must not invent warning pressure")
check(memorySnapshot.timestamp == 10, "Keep the sample's monotonic timestamp")
check(MemoryPressure(kernelLevel: 1) == .normal, "Kernel normal state")
check(MemoryPressure(kernelLevel: 2) == .warning, "Kernel warning state")
check(MemoryPressure(kernelLevel: 4) == .critical, "Kernel critical state")
for level: Int32 in [-1, 0, 3, 99] {
    check(MemoryPressure(kernelLevel: level) == .unknown, "Unknown kernel levels must not be guessed")
}
check(MemoryPressure(kernelLevel: nil) == .unknown, "Unavailable pressure must not be reported as normal")
let withoutSwap = try memoryCounters.snapshot(totalBytes: 100 * page, pageSize: page,
                                             swapUsed: nil, pressure: .unknown, timestamp: 10)
check(withoutSwap.swapUsedBytes == nil && withoutSwap.pressure == .unknown, "Optional APIs can fail without fabricating readings")
expectError("Reject missing physical memory") {
    _ = try memoryCounters.snapshot(totalBytes: 0, pageSize: page, swapUsed: nil, pressure: .normal, timestamp: 0)
}
expectError("Reject invalid page size") {
    _ = try memoryCounters.snapshot(totalBytes: 100 * page, pageSize: 0, swapUsed: nil, pressure: .normal, timestamp: 0)
}
expectError("Reject implausible page size") {
    _ = try memoryCounters.snapshot(totalBytes: 100 * page, pageSize: .max, swapUsed: nil, pressure: .normal, timestamp: 0)
}
expectError("Reject invalid sample time") {
    _ = try memoryCounters.snapshot(totalBytes: 100 * page, pageSize: page, swapUsed: nil, pressure: .normal, timestamp: .nan)
}
let allCache = MemoryCounters(active: 1, inactive: 0, speculative: 0, wired: 0, compressor: 0, purgeable: 100, fileBacked: 100)
check(try allCache.snapshot(totalBytes: page, pageSize: page, swapUsed: nil, pressure: .normal, timestamp: 0).usedBytes == 0,
      "Racing counters must not produce negative used RAM")
let enormous = MemoryCounters(active: .max, inactive: .max, speculative: .max, wired: .max, compressor: .max, purgeable: 0, fileBacked: 0)
let capped = try enormous.snapshot(totalBytes: 100 * page, pageSize: page, swapUsed: nil, pressure: .critical, timestamp: 0)
check(capped.usedBytes == 100 * page && capped.compressedBytes == 100 * page, "Overflowing counters must be safely bounded")
let gib = UInt64(1 << 30)
let displaySnapshot = MemorySnapshot(totalBytes: 24 * gib, usedBytes: 18 * gib + gib / 2,
                                     compressedBytes: gib, swapUsedBytes: nil, pressure: .warning, timestamp: 0)
check(displaySnapshot.compactUsage == "18.5/24 GB", "Compact readout must include used and total memory")
check(MemoryFormat.gigabytes(gib) == "1.0", "Use the memory tools' binary gigabyte convention")
check(MemoryFormat.capacity(gib / 2) == "0.5", "Fractional capacities must not round to zero")
check(abs((displaySnapshot.usageFraction ?? -1) - 18.5 / 24) < 1e-10, "Usage-bar fill must reflect physical used/total RAM")
check(MemoryFormat.temperatureTitle(53) == "53°", "Temperature remains a compact readout")
check(MemoryFormat.temperatureTitle(nil) == "--°", "Missing temperature keeps its placeholder")
for temperature in [Double.nan, .infinity, 0, 125] {
    check(MemoryFormat.temperatureTitle(temperature) == "--°", "Invalid temperature must not crash display formatting")
}
let zeroTotal = MemorySnapshot(totalBytes: 0, usedBytes: 0, compressedBytes: 0, swapUsedBytes: nil, pressure: .unknown, timestamp: 0)
check(zeroTotal.usageFraction == nil, "Unknown capacity must not pretend to be zero-percent usage")
let overTotal = MemorySnapshot(totalBytes: gib, usedBytes: 2 * gib, compressedBytes: 0, swapUsedBytes: nil, pressure: .normal, timestamp: 0)
check(overTotal.usageFraction == 1, "Usage bars must never exceed 100 percent")
var pressureHistory = PressureHistory()
check(pressureHistory.samples.isEmpty, "No pressure samples may be invented on launch")
pressureHistory.record(.normal, at: 10)
pressureHistory.record(.warning, at: 200)
pressureHistory.record(.critical, at: 400)
check(pressureHistory.samples.count == 2 && pressureHistory.samples.first?.timestamp == 200, "History expires after five minutes")
pressureHistory.record(.normal, at: 400)
check(pressureHistory.samples.count == 2 && pressureHistory.samples.last?.pressure == .normal, "Duplicate times replace rather than grow history")
pressureHistory.record(.critical, at: .nan)
check(pressureHistory.samples.count == 2, "Invalid timestamps must be ignored")
pressureHistory.record(.unknown, at: 199)
check(pressureHistory.samples.count == 1 && pressureHistory.samples.last?.pressure == .unknown, "A backwards clock resets history")
pressureHistory.clear()
check(pressureHistory.samples.isEmpty, "Sleep clears the pressure timeline")
for index in 0...500 { pressureHistory.record(.normal, at: Double(index)) }
check(pressureHistory.samples.count == PressureHistory.capacity, "History must have a fixed memory bound")
check(pressureHistory.samples.last?.timestamp == 500, "History must retain the latest sample")
var spanHistory = PressureHistory()
for time in [0.0, 2, 4] { spanHistory.record(.normal, at: time) }
spanHistory.record(.warning, at: 6)
spanHistory.record(.critical, at: 20)
let spans = spanHistory.spans(until: 22)
check(spans.count == 3, "Consecutive matching states merge into clean history bands")
check(spans[0].start == 0 && spans[0].end == 6 && spans[0].pressure == .normal, "Normal samples must merge without seams")
check(spans[1].start == 6 && spans[1].end == 12, "Missing readings must not fill long gaps")
check(spans[2].start == 20 && spans[2].end == 22, "Retain the latest pressure state")
check(spanHistory.spans(until: .nan).isEmpty && spanHistory.spans(until: -1).isEmpty, "Invalid times and future samples must not paint history")
// Verify the native APIs without requesting privileges or touching fan control.
let liveMemory = try LiveMemoryReader().read()
check(liveMemory.totalBytes == ProcessInfo.processInfo.physicalMemory, "Live total must match physical RAM")
check(liveMemory.usedBytes <= liveMemory.totalBytes && liveMemory.compressedBytes <= liveMemory.totalBytes, "Live accounting must stay bounded")
print("\(checks - memoryChecksStart) memory checks passed")
