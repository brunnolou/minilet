// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import Foundation
import IOKit
import Darwin
import Dispatch

// Private IOHID thermal APIs. This is how Apple's own HID thermal sensors expose
// Apple Silicon die temperatures without shelling out to powermetrics.
typealias IOHIDEventSystemClient = CFTypeRef
typealias IOHIDServiceClient = CFTypeRef
typealias IOHIDEvent = CFTypeRef

@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClient

@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClient, _ matching: CFTypeRef)

@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: IOHIDEventSystemClient) -> CFArray

@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: IOHIDServiceClient, _ key: CFString) -> CFTypeRef?

@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: IOHIDServiceClient, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> IOHIDEvent?

@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: IOHIDEvent, _ field: Int32) -> Double

typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

struct SMCKeyData {
    struct Vers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Vers()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = zeroBytes()
}

struct SMCValue {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes: [UInt8] = Array(repeating: 0, count: 32)
}

func zeroBytes() -> SMCBytes {
    return (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

extension UInt32 {
    init(fourCC string: String) {
        precondition(string.utf8.count == 4, "SMC keys must be 4 chars")
        self = string.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    func fourCCString() -> String {
        return String(UnicodeScalar((self >> 24) & 0xff)!) +
               String(UnicodeScalar((self >> 16) & 0xff)!) +
               String(UnicodeScalar((self >> 8) & 0xff)!) +
               String(UnicodeScalar(self & 0xff)!)
    }
}

func arrayToBytes(_ a: [UInt8]) -> SMCBytes {
    return (a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],a[9],a[10],a[11],a[12],a[13],a[14],a[15],
            a[16],a[17],a[18],a[19],a[20],a[21],a[22],a[23],a[24],a[25],a[26],a[27],a[28],a[29],a[30],a[31])
}

func bytesToArray(_ b: SMCBytes) -> [UInt8] {
    return [b.0,b.1,b.2,b.3,b.4,b.5,b.6,b.7,b.8,b.9,b.10,b.11,b.12,b.13,b.14,b.15,
            b.16,b.17,b.18,b.19,b.20,b.21,b.22,b.23,b.24,b.25,b.26,b.27,b.28,b.29,b.30,b.31]
}

func kr(_ code: kern_return_t) -> String {
    String(cString: mach_error_string(code), encoding: .ascii) ?? "0x\(String(code, radix: 16))"
}

struct ThermalSample {
    let name: String
    let celsius: Double
}

final class ThermalReader {
    private static let temperatureEventType: Int64 = 15
    private static let temperatureLevelField = Int32(15 << 16)

    private let client: IOHIDEventSystemClient

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        let match: [String: Any] = ["PrimaryUsagePage": 65280, "PrimaryUsage": 5]
        IOHIDEventSystemClientSetMatching(client, match as CFDictionary)
    }

    func samples() -> [ThermalSample] {
        let services = IOHIDEventSystemClientCopyServices(client) as [AnyObject]
        return services.compactMap { serviceObject in
            let service = serviceObject as IOHIDServiceClient
            guard let event = IOHIDServiceClientCopyEvent(service, Self.temperatureEventType, 0, 0) else { return nil }
            let temp = IOHIDEventGetFloatValue(event, Self.temperatureLevelField)
            guard temp.isFinite, temp > 0, temp < 125 else { return nil }
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString).map { String(describing: $0) } ?? "unknown"
            return ThermalSample(name: name, celsius: temp)
        }
    }

    func controlTemperature() throws -> ThermalSample {
        let all = samples()
        let die = all.filter { $0.name.lowercased().contains("tdie") }
        let pool = die.isEmpty
            ? all.filter {
                let n = $0.name.lowercased()
                return !n.contains("battery") && !n.contains("nand")
            }
            : die
        guard let hottest = pool.max(by: { $0.celsius < $1.celsius }) else {
            throw "No usable thermal sensors found"
        }
        return hottest
    }

    func printTemperatures() throws {
        let all = samples().sorted { $0.celsius > $1.celsius }
        guard !all.isEmpty else { throw "No thermal sensors found" }
        let hottest = try controlTemperature()
        print("control: \(String(format: "%.1f", hottest.celsius)) C (\(hottest.name))")
        for sample in all.prefix(20) {
            print("\(String(format: "%5.1f", sample.celsius)) C  \(sample.name)")
        }
    }
}

final class SMC {
    private var conn: io_connect_t = 0
    private var lowerModeKey: Bool?

    init() throws {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleSMC")
        var result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == kIOReturnSuccess else { throw "IOServiceGetMatchingServices: \(kr(result))" }
        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { throw "AppleSMC service not found" }
        result = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        guard result == kIOReturnSuccess else { throw "IOServiceOpen: \(kr(result))" }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ index: UInt8, input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(conn, UInt32(index), &input, MemoryLayout<SMCKeyData>.stride, &output, &outputSize)
    }

    func read(_ key: String) throws -> SMCValue {
        var value = SMCValue(key: key)
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = UInt32(fourCC: key)
        input.data8 = 9 // readKeyInfo
        var result = call(2, input: &input, output: &output)
        guard result == kIOReturnSuccess else { throw "read \(key) info: \(kr(result))" }
        guard output.result == 0, output.keyInfo.dataSize > 0,
              output.keyInfo.dataSize <= 32 else { throw "SMC key \(key) unavailable" }

        value.dataSize = UInt32(output.keyInfo.dataSize)
        value.dataType = output.keyInfo.dataType.fourCCString()
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5 // readBytes
        result = call(2, input: &input, output: &output)
        guard result == kIOReturnSuccess else { throw "read \(key): \(kr(result))" }
        guard output.result == 0 else { throw "SMC rejected read \(key)" }
        value.bytes = bytesToArray(output.bytes)
        return value
    }

    @discardableResult
    func write(_ value: SMCValue) throws -> kern_return_t {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = UInt32(fourCC: value.key)
        input.data8 = 6 // writeBytes
        input.keyInfo.dataSize = IOByteCount32(value.dataSize)
        input.bytes = arrayToBytes(value.bytes)
        let result = call(2, input: &input, output: &output)
        guard result == kIOReturnSuccess else { throw "write \(value.key): \(kr(result))" }
        guard output.result == 0 else { throw "write \(value.key): SMC rejected command 0x\(String(output.result, radix: 16))" }
        return result
    }

    func number(_ key: String) throws -> Double {
        let v = try read(key)
        switch v.dataType {
        case "ui8 ": return Double(v.bytes[0])
        case "ui16": return Double((UInt16(v.bytes[0]) << 8) | UInt16(v.bytes[1]))
        case "ui32": return Double((UInt32(v.bytes[0]) << 24) | (UInt32(v.bytes[1]) << 16) | (UInt32(v.bytes[2]) << 8) | UInt32(v.bytes[3]))
        case "flt ":
            let raw = UInt32(v.bytes[0]) | (UInt32(v.bytes[1]) << 8) | (UInt32(v.bytes[2]) << 16) | (UInt32(v.bytes[3]) << 24)
            return Double(Float(bitPattern: raw))
        case "fpe2":
            let raw = (UInt16(v.bytes[0]) << 8) | UInt16(v.bytes[1])
            return Double(raw) / 4.0
        default:
            // Many RPM keys are either flt or fpe2. Try fpe2-ish fallback.
            let raw = (UInt16(v.bytes[0]) << 8) | UInt16(v.bytes[1])
            return Double(raw) / 4.0
        }
    }

    func fanCount() throws -> Int { Int(try number("FNum")) }

    func modeKey(_ fan: Int) -> String {
        if lowerModeKey == nil {
            lowerModeKey = (try? read("F0md")).map { $0.dataSize > 0 } ?? false
        }
        return lowerModeKey! ? "F\(fan)md" : "F\(fan)Md"
    }

    func writeByte(_ key: String, _ byte: UInt8) throws {
        var v = try read(key)
        v.bytes[0] = byte
        try write(v)
    }

    func writeRPM(_ key: String, _ rpm: Double) throws {
        var v = try read(key)
        if v.dataType == "flt " {
            let raw = Float(rpm).bitPattern
            v.bytes[0] = UInt8(raw & 0xff)
            v.bytes[1] = UInt8((raw >> 8) & 0xff)
            v.bytes[2] = UInt8((raw >> 16) & 0xff)
            v.bytes[3] = UInt8((raw >> 24) & 0xff)
        } else {
            let raw = UInt16(max(0, rpm) * 4.0)
            v.bytes[0] = UInt8((raw >> 8) & 0xff)
            v.bytes[1] = UInt8(raw & 0xff)
        }
        try write(v)
    }

    private func trySetManual(_ fan: Int) -> Bool {
        do { try writeByte(modeKey(fan), 1); return true } catch { return false }
    }

    func unlockFan(_ fan: Int) throws {
        if trySetManual(fan) { return }

        guard var ftst = try? read("Ftst"), ftst.dataSize > 0 else {
            throw "Could not enable manual mode for fan \(fan). Ftst unlock key not available."
        }

        if ftst.bytes[0] != 1 {
            ftst.bytes[0] = 1
            try write(ftst)
            usleep(3_000_000)
        }

        for _ in 0..<300 {
            if trySetManual(fan) { return }
            usleep(100_000)
        }
        throw "Could not enable manual mode for fan \(fan); thermal manager refused to yield."
    }

    func setFan(_ fan: Int, rpm: Double) throws {
        try unlockFan(fan)
        try writeRPM("F\(fan)Tg", rpm)
    }

    func setAll(percent: Double) throws {
        let count = try fanCount()
        guard count > 0 else { throw "No fans found" }
        for fan in 0..<count {
            let maxRPM = try number("F\(fan)Mx")
            let target = maxRPM * percent
            try setFan(fan, rpm: target)
            print("fan \(fan): \(Int(target.rounded())) RPM")
        }
    }

    func setAllRPM(_ rpm: Double, label: String? = nil, verbose: Bool = true) throws {
        let count = try fanCount()
        guard count > 0 else { throw "No fans found" }
        for fan in 0..<count {
            let maxRPM = try number("F\(fan)Mx")
            let minRPM = (try? number("F\(fan)Mn")) ?? 0
            let target = min(max(rpm, minRPM), maxRPM)
            try setFan(fan, rpm: target)
            if verbose {
                print("fan \(fan): \(Int(target.rounded())) RPM\(label.map { " (\($0))" } ?? "")")
            }
        }
    }

    func setAllFull(verbose: Bool = true) throws {
        let count = try fanCount()
        guard count > 0 else { throw "No fans found" }
        for fan in 0..<count {
            let maxRPM = try number("F\(fan)Mx")
            try setFan(fan, rpm: maxRPM)
            if verbose { print("fan \(fan): \(Int(maxRPM.rounded())) RPM (max)") }
        }
    }

    func auto(verbose: Bool = true) throws {
        let count = try fanCount()
        guard (1...4).contains(count) else { throw "Invalid fan count" }
        var writeErrors: [String] = []
        for fan in 0..<count {
            // Both the manual-mode flag and held RPM target must be released.
            // Attempt every release even if an earlier write fails.
            do { try writeByte(modeKey(fan), 0) }
            catch { writeErrors.append(String(describing: error)) }
            do { try writeRPM("F\(fan)Tg", 0) }
            catch { writeErrors.append(String(describing: error)) }
        }
        if let ftst = try? read("Ftst"), ftst.bytes[0] != 0 {
            do { try writeByte("Ftst", 0) }
            catch { writeErrors.append(String(describing: error)) }
        }
        // Firmware state can lag successful writes. Wait for the release to
        // settle, then require a full second of consecutive auto-mode samples.
        usleep(500_000)
        var pending: [String] = []
        var stableSamples = 0
        for attempt in 0..<51 {
            pending = []
            for fan in 0..<count {
                do {
                    let mode = try number(modeKey(fan))
                    // Apple Silicon also uses 3 for system automatic mode.
                    if mode != 0 && mode != 3 { pending.append("Fan \(fan) did not return to auto") }
                } catch { pending.append(String(describing: error)) }
            }
            if let ftst = try? read("Ftst"), ftst.bytes[0] != 0 { pending.append("Ftst is still enabled") }
            if pending.isEmpty {
                stableSamples += 1
                if stableSamples >= 11 {
                    if verbose { for fan in 0..<count { print("fan \(fan): auto") } }
                    return
                }
            } else {
                stableSamples = 0
                // Retry release if firmware or another controller retained a
                // manual target. Every fan still gets a cleanup attempt.
                if attempt % 10 == 0 {
                    for fan in 0..<count {
                        do { try writeByte(modeKey(fan), 0) }
                        catch { writeErrors.append(String(describing: error)) }
                        do { try writeRPM("F\(fan)Tg", 0) }
                        catch { writeErrors.append(String(describing: error)) }
                    }
                }
            }
            if attempt < 50 { usleep(100_000) }
        }
        if pending.isEmpty { pending.append("Automatic mode did not remain stable") }
        throw (pending + writeErrors).joined(separator: "; ")
    }

    func status() throws {
        let count = try fanCount()
        print("fans: \(count)")
        for fan in 0..<count {
            let actual = (try? number("F\(fan)Ac")) ?? 0
            let target = (try? number("F\(fan)Tg")) ?? 0
            let minRPM = (try? number("F\(fan)Mn")) ?? 0
            let maxRPM = (try? number("F\(fan)Mx")) ?? 0
            let modeVal = (try? number(modeKey(fan))).map { Int($0) } ?? -1
            let mode = modeVal == 1 ? "manual" : ([0, 3].contains(modeVal) ? "auto" : "system(\(modeVal))")
            print("fan \(fan): actual \(Int(actual.rounded())) RPM, target \(Int(target.rounded())), min \(Int(minRPM.rounded())), max \(Int(maxRPM.rounded())), \(mode)")
        }
        if let ftst = try? read("Ftst") { print("Ftst: \(ftst.bytes[0])") }
    }
}

extension String: @retroactive Error {}
