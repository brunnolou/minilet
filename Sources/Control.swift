// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import Foundation

enum FanMode: String, Codable, CaseIterable {
    case auto, medium, high, xhigh, full, guardMode = "guard"

    static let sliderModes: [FanMode] = [.auto, .medium, .high, .xhigh, .full]

    var sliderIndex: Int? { Self.sliderModes.firstIndex(of: self) }

    static func sliderMode(value: Double) -> FanMode {
        let value = value.isFinite ? value : 0
        let index = Int(min(4, max(0, value.rounded())))
        return sliderModes[index]
    }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .medium: return "Medium · 4000 RPM"
        case .high: return "High · 5000 RPM"
        case .xhigh: return "Extra high · 6000 RPM"
        case .full: return "Full speed"
        case .guardMode: return "Temperature guard"
        }
    }
}

enum CurveType: String, Codable, CaseIterable {
    case linear, exponential, logarithmic, smoothstep

    var title: String {
        switch self {
        case .linear: return "Linear"
        case .exponential: return "Exponential"
        case .logarithmic: return "Logarithmic"
        case .smoothstep: return "Smoothstep"
        }
    }

    var description: String {
        switch self {
        case .linear: return "Steady ramp"
        case .exponential: return "Quieter near target"
        case .logarithmic: return "Stronger cooling near target"
        case .smoothstep: return "Gentle start and finish"
        }
    }

    func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        switch self {
        case .linear: return t
        case .exponential: return expm1(3 * t) / expm1(3)
        case .logarithmic: return log1p(expm1(3) * t) / 3
        case .smoothstep: return t * t * (3 - 2 * t)
        }
    }
}

struct Settings: Codable, Equatable {
    var target: Double
    var maxRPM: Double
    var curve: CurveType
    var speedCap: FanMode?

    init(target: Double = 80, maxRPM: Double = 5500, curve: CurveType = .exponential, speedCap: FanMode? = nil) {
        self.target = target
        self.maxRPM = maxRPM
        self.curve = curve
        self.speedCap = speedCap
    }

    private enum CodingKeys: String, CodingKey { case target, maxRPM, curve, speedCap }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decode(Double.self, forKey: .target)
        maxRPM = try values.decode(Double.self, forKey: .maxRPM)
        // Preserve existing slider values when loading pre-curve settings.
        curve = try values.decodeIfPresent(CurveType.self, forKey: .curve) ?? .exponential
        speedCap = try values.decodeIfPresent(FanMode.self, forKey: .speedCap)
    }

    var rampEndTemperature: Double { min(target + 10, 92) }

    func validate() throws {
        guard target.isFinite, (30...85).contains(target),
              maxRPM.isFinite,
              (speedCap == nil ? (3200...8000).contains(maxRPM) : (0..<20000).contains(maxRPM)),
              speedCap == nil || FanMode.sliderModes.contains(speedCap!) else {
            throw "Invalid guard settings"
        }
    }

    func resolvingSpeedCap(minimumRPM: Double, maximumRPM: Double) throws -> Settings {
        guard let cap = speedCap else { return self }
        try validate()
        guard minimumRPM.isFinite, maximumRPM.isFinite, minimumRPM >= 0,
              maximumRPM >= minimumRPM, maximumRPM > 0, maximumRPM < 20000 else { throw "Invalid fan limits" }
        let rpm: Double
        switch cap {
        case .full: rpm = maximumRPM
        case .medium: rpm = 4000
        case .high: rpm = 5000
        case .xhigh: rpm = 6000
        case .auto, .guardMode: throw "Invalid speed cap"
        }
        var resolved = self
        resolved.maxRPM = min(maximumRPM, max(minimumRPM, rpm))
        return resolved
    }
}

// Session-only control selection. Temperature 0 is Off; the remaining slider
// positions map to 30...85 C without an unusable 1...29 C range.
struct FanControlSelection {
    var speed: FanMode = .auto
    var temperature: Double?
    var mode: FanMode { temperature == nil ? speed : .guardMode }

    static func temperature(value: Double) -> Double? {
        guard value.isFinite else { return nil }
        let step = min(56, max(0, value.rounded()))
        return step == 0 ? nil : step + 29
    }
}

struct Request: Codable {
    var command: String = "status"
    var settings: Settings?
}

struct Reply: Codable {
    var mode: FanMode = .auto
    var temperature: Double?
    var smoothedTemperature: Double?
    var rpms: [Double] = []
    var output = "Monitoring only"
    var error: String?
}

enum FanOutput: Equatable {
    case automatic, rpm(Double), full
}

// Continuous speed control. Below target - 5 C, hold hardware minimum RPM,
// not macOS automatic mode. Reach the selected cap at target + 10 C.
struct GuardCurve {
    func output(temperature: Double, settings: Settings, minimumRPM: Double = 2400) throws -> FanOutput {
        try settings.validate()
        guard temperature.isFinite, temperature > 0, temperature < 125 else {
            throw "Invalid temperature"
        }
        guard minimumRPM.isFinite, minimumRPM >= 0, minimumRPM <= settings.maxRPM else {
            throw "Speed cap must be at least the hardware minimum"
        }
        if temperature >= 92 { return .full }
        let start = settings.target - 5
        let t = min(1, max(0, (temperature - start) / (settings.rampEndTemperature - start)))
        let rpm = minimumRPM + (settings.maxRPM - minimumRPM) * settings.curve.ease(t)
        return .rpm(min(settings.maxRPM, max(minimumRPM, (rpm / 100).rounded() * 100)))
    }
}

struct GuardRegulator {
    private(set) var smoothedTemperature: Double?
    private var previousRPM: Double?
    private var previousTime: Double?
    private var emergency = false

    mutating func output(temperature: Double, settings: Settings, minimumRPM: Double,
                         actualRPM: Double, now: Double) throws -> FanOutput {
        // Validate raw readings before filtering. Never smooth away an error.
        _ = try GuardCurve().output(temperature: temperature, settings: settings, minimumRPM: minimumRPM)
        guard actualRPM.isFinite, actualRPM >= 0, now.isFinite else { throw "Invalid regulator input" }
        let dt = previousTime.map { min(5, max(0, now - $0)) } ?? 5
        previousTime = now
        let alpha = 1 - exp(-dt / 10) // Ten-second temperature filter.
        smoothedTemperature = smoothedTemperature.map { $0 + alpha * (temperature - $0) } ?? temperature

        if temperature >= 92 { emergency = true }
        if emergency && temperature <= 88 { emergency = false }
        if emergency {
            smoothedTemperature = temperature
            previousRPM = nil
            return .full // Raw-temperature override bypasses filtering and speed limits.
        }

        let desired = try GuardCurve().output(temperature: smoothedTemperature!, settings: settings, minimumRPM: minimumRPM)
        guard case .rpm(let target) = desired else { return desired }
        let previous = previousRPM ?? max(minimumRPM, actualRPM)
        // No instant jumps or repeated bursts near a temperature threshold.
        // Clamping dt prevents frequent option changes from accelerating the ramp.
        let limited = min(previous + 160 * dt, max(previous - 60 * dt, target))
        let rpm = min(settings.maxRPM, max(minimumRPM, limited))
        previousRPM = rpm
        return .rpm(rpm)
    }
}

protocol FanDevice {
    func temperature() throws -> Double
    func speeds() throws -> [Double]
    func minimumRPM() throws -> Double
    func maximumRPM() throws -> Double
    func automatic() throws
    func setRPM(_ rpm: Double) throws
    func full() throws
}

final class FanController {
    let device: FanDevice
    var mode: FanMode = .auto
    var settings = Settings()
    var regulator = GuardRegulator()
    var output: FanOutput?
    var reply = Reply()
    var ownsFans = false

    init(device: FanDevice) { self.device = device }

    func select(_ mode: FanMode, settings: Settings) throws {
        try settings.validate()
        guard mode != .guardMode || settings.speedCap != .auto else { throw "Automatic is not a speed cap" }
        self.settings = settings
        if self.mode != mode { regulator = GuardRegulator() }
        self.mode = mode
        output = nil
        reply.error = nil
        // Mark ownership before a write, so partial writes also get cleaned up.
        ownsFans = true
        switch mode {
        case .auto: try apply(.automatic)
        case .medium: try apply(.rpm(4000))
        case .high: try apply(.rpm(5000))
        case .xhigh: try apply(.rpm(6000))
        case .full: try apply(.full)
        case .guardMode: break // tick reads a sensor before changing fan speed.
        }
    }

    private func apply(_ next: FanOutput) throws {
        // Always reassert hardware state on a five-second guard tick. Another
        // fan app or sleep/wake can change SMC mode without telling us.
        switch next {
        case .automatic:
            try device.automatic()
            reply.output = "macOS automatic control"
        case .rpm(let rpm):
            try device.setRPM(rpm)
            reply.output = "\(Int(rpm)) RPM requested"
        case .full:
            try device.full()
            reply.output = "Full speed"
        }
        output = next
    }

    func tick(now: Double = ProcessInfo.processInfo.systemUptime) {
        do {
            let temp = try device.temperature()
            let speeds = try device.speeds()
            reply.temperature = temp
            reply.rpms = speeds
            if mode == .guardMode {
                ownsFans = true
                let minimum = try device.minimumRPM()
                let resolved = try settings.resolvingSpeedCap(minimumRPM: minimum,
                    maximumRPM: settings.speedCap == nil ? settings.maxRPM : device.maximumRPM())
                let next = try regulator.output(temperature: temp, settings: resolved,
                                                minimumRPM: minimum,
                                                actualRPM: speeds.max() ?? 0, now: now)
                try apply(next)
                reply.smoothedTemperature = regulator.smoothedTemperature
            } else { reply.smoothedTemperature = nil }
            reply.mode = mode
        } catch {
            fail(error)
        }
    }

    func fail(_ error: Error) {
        let message = String(describing: error)
        mode = .auto
        regulator = GuardRegulator()
        reply.smoothedTemperature = nil
        do {
            if ownsFans { try device.automatic() }
            reply.output = "macOS automatic control"
            reply.error = message
        } catch {
            reply.error = "\(message). Restoring auto FAILED: \(error). Run fan auto."
        }
        reply.mode = .auto
    }

    func stop() throws {
        if ownsFans { try device.automatic() }
    }
}
