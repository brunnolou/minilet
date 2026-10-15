// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import AppKit

enum ProcessorHistoryKind {
    case cpu, gpu
    var title: String { self == .cpu ? "CPU" : "GPU" }
    var iconName: String { self == .cpu ? "cpu" : "gpu" }
}

final class ProcessorHistoryView: NSView {
    let kind: ProcessorHistoryKind
    private(set) var history = ProcessorHistory()
    private(set) var currentUsage: Double?
    var title: String { "\(kind.title)   \(ProcessorSnapshot.percent(currentUsage))" }

    init(kind: ProcessorHistoryKind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 60))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        update(history: history, snapshot: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(kind:)") }

    func update(history: ProcessorHistory, snapshot: ProcessorSnapshot?) {
        self.history = history
        currentUsage = kind == .cpu ? snapshot?.cpuMean : snapshot?.gpu
        setAccessibilityLabel("\(kind.title) \(ProcessorSnapshot.percent(currentUsage)). History, last five minutes.")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        HistoryHeader.draw(title: title, icon: kind.iconName, in: bounds)
        let track = NSRect(x: 17, y: 8, width: bounds.width - 34, height: 23)
        Self.drawHistory(history, kind: kind, in: track, until: ProcessInfo.processInfo.systemUptime)
    }

    static func drawHistory(_ history: ProcessorHistory, kind: ProcessorHistoryKind, in rect: NSRect, until now: Double) {
        guard rect.width > 0, rect.height > 0 else { return }
        let count = max(1, Int((rect.width + 1) / 4))
        let columns = history.columns(count: count, until: now)
        NSGraphicsContext.saveGraphicsState()
        let outline = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        outline.fill()
        outline.addClip()
        if kind == .cpu {
            NSGraphicsContext.current?.shouldAntialias = false
            let rows = max(1, Int((rect.height + 1) / 4))
            let left = rect.minX + (rect.width - CGFloat(count * 4 - 1)) / 2
            for (index, column) in columns.enumerated() {
                guard let usage = column.cpu else { continue }
                for row in 0..<rows {
                    let alpha = min(1, max(0, usage * Double(rows) - Double(row)))
                    let color = alpha > 0 ? NSColor.labelColor.withAlphaComponent(alpha)
                                          : NSColor.textBackgroundColor.withAlphaComponent(0.35)
                    color.setFill()
                    NSRect(x: left + CGFloat(index * 4), y: rect.minY + CGFloat(row * 4), width: 3, height: 3).fill()
                }
            }
        } else {
            NSGraphicsContext.current?.shouldAntialias = true
            let step = rect.width / CGFloat(count)
            let known = NSBezierPath()
            let filled = NSBezierPath()
            for (index, column) in columns.enumerated() {
                guard let usage = column.gpu else { continue }
                let columnRect = NSRect(x: rect.minX + CGFloat(index) * step, y: rect.minY, width: step, height: rect.height)
                known.appendRect(columnRect)
                if usage > 0 {
                    filled.appendRect(NSRect(x: columnRect.minX, y: rect.minY, width: step, height: rect.height * usage))
                }
            }
            let lines = NSBezierPath()
            lines.lineWidth = StatusMeters.gpuStrokeWidth
            lines.lineCapStyle = .butt
            let period = (StatusMeters.gpuStrokeWidth + StatusMeters.gpuStrokeGap) * sqrt(2)
            for x in stride(from: rect.minX - rect.height - period, through: rect.maxX + period, by: period) {
                lines.move(to: NSPoint(x: x - rect.height, y: rect.maxY + rect.height))
                lines.line(to: NSPoint(x: x + rect.height * 2, y: rect.minY - rect.height))
            }
            func stroke(_ mask: NSBezierPath, color: NSColor) {
                guard mask.elementCount > 0 else { return }
                NSGraphicsContext.saveGraphicsState()
                mask.addClip()
                color.setStroke()
                lines.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            stroke(known, color: NSColor.textBackgroundColor.withAlphaComponent(0.35))
            stroke(filled, color: NSColor.labelColor.withAlphaComponent(1))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func runSelfTest() -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
        let cpu = ProcessorHistoryView(kind: .cpu)
        let gpu = ProcessorHistoryView(kind: .gpu)
        var history = ProcessorHistory()
        for time in stride(from: 0.0, through: 298, by: 2) {
            let value = time < 150 ? 0.25 : 0.75
            history.record(ProcessorSnapshot(cpu: [value], gpu: value), at: time)
        }
        cpu.update(history: history, snapshot: ProcessorSnapshot(cpu: [0.25, 0.75], gpu: 0.75))
        gpu.update(history: history, snapshot: ProcessorSnapshot(cpu: [0.25, 0.75], gpu: 0.75))
        check(cpu.kind.iconName == "cpu" && gpu.kind.iconName == "gpu", "CPU and GPU use distinct monitor icons")
        check(cpu.title == "CPU   50%" && gpu.title == "GPU   75%",  "History headers show actual current usage, not boosted top-bar opacity")
        check(cpu.history.samples.count == 150 && gpu.history.samples.count == 150, "Both views retain five-minute history")
        for kind in [ProcessorHistoryKind.cpu, .gpu] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 286, pixelsHigh: 23,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    drawHistory(history, kind: kind, in: NSRect(x: 0, y: 0, width: 286, height: 23), until: 300)
                }
                NSGraphicsContext.restoreGraphicsState()
                var left: CGFloat = 0, right: CGFloat = 0
                for x in 12..<132 {
                    for y in 0..<23 {
                        left += bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                        right += bitmap.colorAt(x: x + 142, y: y)?.alphaComponent ?? 0
                    }
                }
                check(right > left, "\(kind.title) history shows higher sampled usage with a taller filled pattern")
                check((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.1, "History plots have rounded outer corners")
            }
        }
        cpu.update(history: ProcessorHistory(), snapshot: nil)
        check(cpu.title == "CPU   Unavailable" && cpu.history.samples.isEmpty, "Reset history does not invent idle samples")
        return checks
    }
}
