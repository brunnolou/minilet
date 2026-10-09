// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

var processorChecks = 0
func processorCheck(_ condition: Bool, _ message: String) {
    processorChecks += 1
    precondition(condition, message)
}
let emptyTicks = ProcessorTicks(user: 0, system: 0, idle: 0, nice: 0)
let mixedTicks = ProcessorTicks(user: 20, system: 10, idle: 65, nice: 5)
processorCheck(mixedTicks.utilization(since: emptyTicks) == 0.35, "CPU busy time includes user, system and nice, not idle")
processorCheck(emptyTicks.utilization(since: emptyTicks) == nil, "Zero-length CPU samples are unavailable, not idle")
processorCheck(ProcessorTicks(user: 10, system: 0, idle: 80, nice: 0)
    .utilization(since: ProcessorTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)) == 0.2,
    "Unsigned CPU counters wrap safely")
processorCheck(emptyTicks.utilization(since: mixedTicks) == nil, "Counter resets do not produce fake high usage")
var processorSampler = ProcessorSampler()
processorCheck(processorSampler.sample([emptyTicks], at: 1) == nil, "The first CPU sample establishes a baseline")
processorCheck(processorSampler.sample([mixedTicks], at: 2) == [0.35], "CPU measures interval deltas")
processorCheck(processorSampler.sample([mixedTicks], at: 3) == nil, "Unchanged CPU counters are unavailable")
processorCheck(processorSampler.sample([mixedTicks, mixedTicks], at: 4) == nil, "CPU topology changes reset the baseline")
let laterTicks = ProcessorTicks(user: 40, system: 20, idle: 130, nice: 10)
processorCheck(processorSampler.sample([laterTicks, laterTicks], at: 5) == [0.35, 0.35], "Topology changes recover on the next sample")
processorCheck(processorSampler.sample([laterTicks, laterTicks], at: 12) == nil, "Gaps longer than six seconds reset CPU intervals")
processorCheck(processorSampler.sample([laterTicks, laterTicks], at: 11) == nil, "Backwards sample times reset the baseline")
processorSampler.reset()
processorCheck(processorSampler.sample([laterTicks], at: 13) == nil, "Sleep resets do not include sleeping time")
processorCheck(processorSampler.sample([], at: 14) == nil && processorSampler.sample([laterTicks], at: .nan) == nil,
               "Invalid CPU samples stay unavailable")
for load in [0.0, 0.1, 0.5, 1] {
    let row = ProcessorTiles.opacities(Array(repeating: load, count: 12))
    processorCheck(row.count == 8, "CPU has eight squares")
    processorCheck(abs(row.reduce(0, +) / Double(ProcessorTiles.count) - load) < 0.000001, "Fractional edge squares preserve the average area")
    processorCheck(zip(row, row.dropFirst()).allSatisfy { $0 >= $1 }, "Overlapped CPU prefixes never increase towards the right")
}
let tenPercentRow = ProcessorTiles.opacities(Array(repeating: 0.1, count: 12))
processorCheck(abs(tenPercentRow[0] - 0.8) < 0.000001 && tenPercentRow.dropFirst().allSatisfy { $0 == 0 },
               "Ten-percent CPU usage occupies only the first fractional square in an eight-square row")
let singleCoreRow = ProcessorTiles.opacities([1] + Array(repeating: 0, count: 11))
processorCheck(singleCoreRow.allSatisfy { abs($0 - 1 / 12.0) < 0.000001 }, "One fully busy core gives a full-width row at 1/12 alpha")
let splitRow = ProcessorTiles.opacities([1, 0.5, 0, 0])
processorCheck(splitRow[0] == 0.5 && splitRow[7] == 0.25, "Mixed cores create layered opacity, not an averaged progress bar")
for invalid: [Double]? in [nil, [], [.nan], [.infinity], [-0.1], [1.1]] {
    processorCheck(ProcessorTiles.opacities(invalid).allSatisfy { $0 == 0 }, "Invalid usage uses only the track")
}
processorCheck(ProcessorTiles.opacities([1], count: 0).isEmpty && ProcessorTiles.opacities([1], count: -1).isEmpty,
               "Invalid tile counts are safe")
processorCheck(LiveProcessorReader.gpuFraction(["Device Utilization %": 44]) == 0.44, "GPU uses the native aggregate device percentage")
processorCheck(LiveProcessorReader.gpuFraction(["Device Utilization %": 0]) == 0, "A measured idle GPU is zero")
processorCheck(LiveProcessorReader.gpuFraction(["Device Utilization %": 100]) == 1, "A measured fully busy GPU is one")
for invalid: Any in [-1, 101, Double.nan, Double.infinity, true, "44"] {
    processorCheck(LiveProcessorReader.gpuFraction(["Device Utilization %": invalid]) == nil, "Invalid GPU data remains unavailable")
}
processorCheck(LiveProcessorReader.gpuFraction([:]) == nil && LiveProcessorReader.gpuFraction(["Renderer Utilization %": 44]) == nil,
               "Missing device utilization is not invented from a different GPU metric")
processorCheck(ProcessorSnapshot(cpu: [1] + Array(repeating: 0, count: 11), gpu: nil).cpuDescription == "8% · 12 cores",
               "CPU tooltip reports the mean and real core count")
processorCheck(ProcessorSnapshot.percent(nil) == "Unavailable" && ProcessorSnapshot.percent(0) == "0%",
               "Unknown and idle processor usage are distinct")
let liveTicks = try LiveProcessorReader.cpuTicks()
processorCheck(!liveTicks.isEmpty, "Native CPU counters are available without fan authorization")
let liveProcessorReader = LiveProcessorReader()
processorCheck(liveProcessorReader.read().cpu == nil, "The live reader does not report boot-to-date CPU utilization")
Thread.sleep(forTimeInterval: 0.2)
let liveProcessors = liveProcessorReader.read()
processorCheck(liveProcessors.cpu?.count == liveTicks.count && liveProcessors.cpu!.allSatisfy { (0...1).contains($0) },
               "Native per-core interval readings stay bounded")
processorCheck(liveProcessors.gpu == nil || (0...1).contains(liveProcessors.gpu!), "GPU reads are valid or explicitly unavailable")
print("\(processorChecks) processor checks passed")
