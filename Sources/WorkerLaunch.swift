// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import Foundation
import Darwin

// AppleScript's privileged shell waits by polling WindowServer hundreds of
// times per second. Keep it alive only for startup, never for the fan session.
enum WorkerLaunch {
    static let ready = "MINILET_READY\n"

    static func start(executable: String, arguments: [String], timeout: TimeInterval = 15) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Process.run closes the parent's copy of its child's output end.
        let fd = output.fileHandleForReading.fileDescriptor
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var complete = false
        defer {
            output.fileHandleForReading.closeFile()
            if !complete && process.isRunning { process.terminate() }
        }
        while data.count < 8192 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw "Controller startup timed out" }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 15_000).rounded(.up)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw "Controller startup timed out or failed" }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw "Cannot read controller startup response" }
            if count == 0 {
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw message.flatMap { $0.isEmpty ? nil : $0 } ?? "Controller stopped before becoming ready"
            }
            data.append(contentsOf: buffer.prefix(count))
            if data.range(of: Data(ready.utf8)) != nil {
                complete = true
                return
            }
        }
        throw "Invalid controller startup response"
    }

    static func notifyReady() throws {
        // Do not leave AppleScript's pipes open in the session child. The
        // parent is allowed to exit while this watchdog-bound worker runs.
        signal(SIGPIPE, SIG_IGN)
        let sink = open("/dev/null", O_WRONLY)
        guard sink >= 0 else { throw "Cannot detach controller output" }
        defer { close(sink) }
        try Data(ready.utf8).withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let result = Darwin.write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw "Controller launcher disconnected" }
                sent += result
            }
        }
        guard dup2(sink, STDOUT_FILENO) >= 0, dup2(sink, STDERR_FILENO) >= 0 else {
            throw "Cannot detach controller output"
        }
    }
}

func launchSessionWorker(session: String, uid: uid_t, parent: pid_t) throws {
    guard getuid() == 0, uid > 0, parent > 1, UUID(uuidString: session) != nil,
          kill(parent, 0) == 0, let executable = Bundle.main.executablePath else {
        throw "Invalid controller identity"
    }
    try WorkerLaunch.start(executable: executable,
        arguments: ["--session-worker", session, String(uid), String(parent)])
}
