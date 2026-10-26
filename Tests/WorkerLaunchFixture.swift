// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

if let command = CommandLine.arguments.dropFirst().first, command.hasPrefix("--launch-test-") {
    if command == "--launch-test-failure" {
        fputs("Fixture startup failed\n", stderr)
        exit(7)
    }
    if command == "--launch-test-launcher", let path = CommandLine.arguments.dropFirst(2).first {
        try WorkerLaunch.start(executable: CommandLine.arguments[0], arguments: ["--launch-test-ready", path], timeout: 3)
        exit(0)
    }
    if let path = CommandLine.arguments.dropFirst(2).first {
        try String(getpid()).write(toFile: path, atomically: true, encoding: .utf8)
    }
    if command == "--launch-test-ready" { try WorkerLaunch.notifyReady() }
    Thread.sleep(forTimeInterval: 30)
    exit(0)
}
