// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

var processorHistoryChecks = 0
func historyCheck(_ condition: Bool, _ message: String) {
    processorHistoryChecks += 1
    precondition(condition, message)
}
var usageHistory = ProcessorHistory()
func usageSnapshot(_ cpu: Double?, _ gpu: Double?) -> ProcessorSnapshot {
    ProcessorSnapshot(cpu: cpu.map { [$0] }, gpu: gpu)
}
historyCheck(usageHistory.columns(count: 60, until: 300).allSatisfy { $0.cpu == nil && $0.gpu == nil },
             "No processor history is fabricated before launch")
usageHistory.record(ProcessorSnapshot(cpu: [0.25, 0.75], gpu: 0.7), at: 0)
usageHistory.record(usageSnapshot(0.8, 0.2), at: 2)
let peaks = usageHistory.columns(count: 60, until: 300)
historyCheck(peaks[0].cpu == 0.8 && peaks[0].gpu == 0.7, "History bins retain actual mean CPU and GPU peaks independently")
historyCheck(peaks[1].cpu == 0.8 && peaks[1].gpu == 0.2 && peaks[2].cpu == nil,
             "Last samples cover at most six seconds, leaving long gaps empty")
usageHistory.record(usageSnapshot(nil, nil), at: 4)
let interrupted = usageHistory.columns(count: 150, until: 300)
historyCheck(interrupted[0].cpu == 0.5 && interrupted[1].cpu == 0.8 && interrupted[2].cpu == nil,
             "Unavailable samples immediately stop previous values rather than appearing as idle")
usageHistory.record(usageSnapshot(nil, 0.9), at: 4)
historyCheck(usageHistory.samples.count == 3 && usageHistory.samples.last?.value.gpu == 0.9,
             "Repeated timestamps replace their sample")
usageHistory.record(usageSnapshot(0, nil), at: 6)
let independent = usageHistory.columns(count: 150, until: 300)
historyCheck(independent[2].cpu == nil && independent[2].gpu == 0.9 && independent[3].cpu == 0 && independent[3].gpu == nil,
             "CPU and GPU availability remain independent, and zero is a measured value")
let beforeInvalidTime = usageHistory.samples.count
usageHistory.record(usageSnapshot(1, 1), at: .nan)
historyCheck(usageHistory.samples.count == beforeInvalidTime, "Invalid timestamps do not corrupt history")
usageHistory.record(ProcessorSnapshot(cpu: [.nan, 0.5], gpu: .infinity), at: 8)
historyCheck(usageHistory.samples.last?.value.cpu == nil && usageHistory.samples.last?.value.gpu == nil,
             "Invalid CPU/GPU readings produce gaps, not fake peaks")
usageHistory.record(usageSnapshot(0.3, 0.4), at: 1)
historyCheck(usageHistory.samples.count == 1, "Backwards timestamps reset history")
usageHistory.clear()
historyCheck(usageHistory.samples.isEmpty, "Sleep clears processor history")
for time in 0..<1000 { usageHistory.record(usageSnapshot(0.5, 0.5), at: Double(time)) }
historyCheck(usageHistory.samples.count == ProcessorHistory.capacity, "History has bounded storage")
historyCheck(usageHistory.samples.allSatisfy { $0.timestamp >= 699 }, "Samples outside the five-minute window are pruned")
historyCheck(usageHistory.columns(count: 0, until: 1000).isEmpty
             && usageHistory.columns(count: 5000, until: 1000).isEmpty
             && usageHistory.columns(count: 10, until: .infinity).isEmpty, "Invalid graph dimensions and clocks are safe")
var clippingHistory = ProcessorHistory()
clippingHistory.record(usageSnapshot(1, 1), at: 0)
historyCheck(clippingHistory.columns(count: 60, until: 400).allSatisfy { $0.cpu == nil && $0.gpu == nil },
             "History does not stretch old samples across the current window")
clippingHistory.record(usageSnapshot(0.5, 0.5), at: 405)
historyCheck(clippingHistory.columns(count: 60, until: 400).allSatisfy { $0.cpu == nil && $0.gpu == nil },
             "Future samples do not leak into the visible history")
print("\(processorHistoryChecks) processor-history checks passed")
