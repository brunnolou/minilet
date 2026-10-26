// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import Foundation
import Darwin

final class LiveFanDevice: FanDevice {
    private let smc: SMC
    private let thermal = ThermalReader()

    init() throws { smc = try SMC() }

    func temperature() throws -> Double {
        let samples = thermal.samples(nameMatching: { $0.lowercased().contains("tdie") })
        guard let temp = samples.map({ $0.celsius }).max() else {
            throw "No Apple Silicon die temperature sensors. Guard stopped."
        }
        return temp
    }

    private func count() throws -> Int {
        let value = try smc.number("FNum")
        guard value.isFinite, value >= 1, value <= 4 else { throw "Invalid fan count" }
        return Int(value)
    }

    func speeds() throws -> [Double] {
        try (0..<count()).map { fan in
            let value = try smc.number("F\(fan)Ac")
            guard value.isFinite, value >= 0, value < 20000 else { throw "Invalid fan speed" }
            return value
        }
    }

    private func limits(_ fan: Int) throws -> (Double, Double) {
        let low = try smc.number("F\(fan)Mn")
        let high = try smc.number("F\(fan)Mx")
        guard low.isFinite, high.isFinite, low >= 0, high >= 3200,
              low < high, high < 20000 else { throw "Invalid fan limits" }
        return (low, high)
    }

    func minimumRPM() throws -> Double {
        // One shared request must be above both fans' individual minimums.
        let minimums = try (0..<count()).map { try limits($0).0 }
        guard let minimum = minimums.max() else { throw "No fans found" }
        return minimum
    }

    func maximumRPM() throws -> Double {
        // The shared cap must be within every fan's hardware maximum.
        let maximums = try (0..<count()).map { try limits($0).1 }
        guard let maximum = maximums.min() else { throw "No fans found" }
        return maximum
    }

    func automatic() throws { try smc.auto(verbose: false) }

    func setRPM(_ rpm: Double) throws {
        guard rpm.isFinite, rpm >= 0 else { throw "Invalid RPM" }
        for fan in 0..<(try count()) {
            let (low, high) = try limits(fan)
            try smc.setFan(fan, rpm: min(high, max(low, rpm)))
        }
    }

    func full() throws {
        for fan in 0..<(try count()) {
            let (_, high) = try limits(fan)
            try smc.setFan(fan, rpm: high)
        }
    }
}

// Confined to the UI's serial hardware queue. Reuse read-only connections,
// discarding them after errors, wake, or transfer to the session controller.
final class LiveFanMonitor {
    private var device: FanDevice?
    private let makeDevice: () throws -> FanDevice

    init(makeDevice: @escaping () throws -> FanDevice = { try LiveFanDevice() }) {
        self.makeDevice = makeDevice
    }

    func read() throws -> Reply {
        do {
            let reader = try device ?? makeDevice()
            device = reader
            return Reply(temperature: try reader.temperature(), rpms: try reader.speeds())
        } catch {
            reset()
            throw error
        }
    }

    func reset() { device = nil }
}

func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw "Socket path too long"
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes)
    }
    return address
}

func configureTimeout(_ fd: Int32, seconds: Int = 2) {
    // On macOS, accept() inherits O_NONBLOCK from the listening socket. Reads
    // must wait for the request, not treat a scheduling race as a timeout.
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

func sendData(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let sent = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if sent < 0 && errno == EINTR { continue }
            guard sent > 0 else { throw "Controller connection closed" }
            offset += sent
        }
    }
}

func receiveData(fd: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count < 8192 {
        let readCount = Darwin.read(fd, &buffer, buffer.count)
        if readCount < 0 && errno == EINTR { continue }
        if readCount == 0 { throw "Controller stopped before replying" }
        if readCount < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw "Controller response timed out"
            }
            throw "Controller read failed: \(String(cString: strerror(errno)))"
        }
        data.append(contentsOf: buffer.prefix(readCount))
        if let end = data.firstIndex(of: 10) { return data.prefix(upTo: end) }
    }
    throw "Controller message too large"
}

func queryWorker(path: String, request: Request) throws -> Reply {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw "Cannot create socket" }
    defer { close(fd) }
    // SMC unlock can take up to 33 seconds per fan, and guard ticks can
    // perform these writes too. Keep the UI responsive on its background queue
    // while allowing enough time for up to four fans and auto verification.
    configureTimeout(fd, seconds: 150)
    var address = try socketAddress(path)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { throw "Controller is not connected" }
    var data = try JSONEncoder().encode(request)
    data.append(10)
    try sendData(data, fd: fd)
    return try JSONDecoder().decode(Reply.self, from: receiveData(fd: fd))
}

func runWorker(session: String, uid: uid_t, parent: pid_t, ready: () throws -> Void = {}) throws {
    guard getuid() == 0, uid > 0, parent > 1, UUID(uuidString: session) != nil else {
        throw "Invalid controller identity"
    }
    guard kill(parent, 0) == 0 else { return }
    // One controller at a time. /var/run is root-owned, and O_NOFOLLOW rejects
    // symlinks. There is no launch daemon or permanent privileged install.
    // Keep the legacy lock path so older Fan Menu workers cannot compete.
    let lock = open("/var/run/com.brunnolou.fan-menu.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw "Cannot open controller lock" }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw "Another Minilet or Fan Menu controller is already running" }

    let device = try LiveFanDevice()
    let controller = FanController(device: device)
    defer {
        do { try controller.stop() }
        catch { fputs("Minilet: could not restore auto: \(error)\n", stderr) }
    }

    // The containing directory is root-owned. The UI can connect to this
    // user-owned socket, but cannot replace its path or race privileged cleanup.
    let path = "/var/run/minilet-\(session).sock"
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw "Cannot create controller socket" }
    defer { close(listener) }
    var address = try socketAddress(path)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0 else { throw "Cannot bind controller socket" }
    defer { unlink(path) }
    guard chown(path, uid, gid_t.max) == 0, chmod(path, 0o600) == 0,
          listen(listener, 4) == 0 else { throw "Cannot prepare controller socket" }
    _ = fcntl(listener, F_SETFL, O_NONBLOCK)

    var stopping = false
    var signals: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { stopping = true }
        source.resume()
        signals.append(source)
    }
    defer { for source in signals { source.cancel() } }
    try ready() // Socket, identity checks, cleanup and signal handlers are ready.
    var lastContact = ProcessInfo.processInfo.systemUptime
    var nextTick = 0.0
    controller.tick() // Read only until an explicit selection.

    while !stopping {
        let now = ProcessInfo.processInfo.systemUptime
        if kill(parent, 0) != 0 || now - lastContact > 20 { break }
        let client = accept(listener, nil, nil)
        if client >= 0 {
            configureTimeout(client)
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            if getpeereid(client, &peerUID, &peerGID) == 0 && peerUID == uid {
                var receivedRequest = false
                do {
                    let request = try JSONDecoder().decode(Request.self, from: receiveData(fd: client))
                    receivedRequest = true
                    lastContact = ProcessInfo.processInfo.systemUptime
                    if request.command == "quit" {
                        try controller.stop()
                        controller.ownsFans = false
                        controller.mode = .auto
                        controller.reply.mode = .auto
                        controller.reply.output = "macOS automatic control"
                        controller.reply.error = nil // Successful cleanup supersedes an earlier error.
                        stopping = true
                    } else if request.command != "status" {
                        guard let mode = FanMode(rawValue: request.command) else { throw "Unknown preset" }
                        try controller.select(mode, settings: request.settings ?? controller.settings)
                        nextTick = 0
                    }
                    if now >= nextTick && !stopping {
                        controller.tick()
                        nextTick = ProcessInfo.processInfo.systemUptime + 5
                    }
                } catch { controller.fail(error) }
                // Time spent servicing an authenticated request is not lost UI
                // contact. Otherwise a slow SMC unlock trips the 20-second watchdog.
                if receivedRequest { lastContact = ProcessInfo.processInfo.systemUptime }
                var response = try JSONEncoder().encode(controller.reply)
                response.append(10)
                try? sendData(response, fd: client)
            }
            close(client)
        }
        if now >= nextTick && !stopping {
            let started = ProcessInfo.processInfo.systemUptime
            controller.tick()
            let completed = ProcessInfo.processInfo.systemUptime
            // The single-threaded worker cannot receive heartbeats during SMC
            // writes. Pause the idle watchdog for its own hardware work.
            lastContact += completed - started
            nextTick = completed + 5
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}
