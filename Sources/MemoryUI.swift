// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import AppKit

enum MemoryVisuals {
    static func color(_ pressure: MemoryPressure) -> NSColor {
        switch pressure {
        case .normal: return .systemGreen
        case .warning: return .systemYellow
        case .critical: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }

    static func badge(_ pressure: MemoryPressure) -> NSImage {
        NSImage(size: NSSize(width: 9, height: 9), flipped: false) { _ in
            let path: NSBezierPath
            switch pressure {
            case .warning:
                path = NSBezierPath()
                path.move(to: NSPoint(x: 4.5, y: 0.5))
                path.line(to: NSPoint(x: 8.5, y: 4.5))
                path.line(to: NSPoint(x: 4.5, y: 8.5))
                path.line(to: NSPoint(x: 0.5, y: 4.5))
                path.close()
            case .critical:
                path = NSBezierPath()
                path.move(to: NSPoint(x: 0.5, y: 1))
                path.line(to: NSPoint(x: 8.5, y: 1))
                path.line(to: NSPoint(x: 4.5, y: 8.5))
                path.close()
            case .normal, .unknown:
                path = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 7, height: 7))
            }
            color(pressure).setFill()
            if pressure != .unknown { path.fill() }
            NSColor.labelColor.withAlphaComponent(0.4).setStroke()
            path.lineWidth = 0.7
            path.stroke()
            return true
        }
    }

    static func statusTitle(temperature: Double?, memory: MemorySnapshot?) -> NSAttributedString {
        let text = MemoryFormat.statusTitle(temperature: temperature, memory: memory)
        let result = NSMutableAttributedString(string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: NSColor.labelColor])
        let attachment = NSTextAttachment()
        attachment.image = badge(memory?.pressure ?? .unknown)
        attachment.bounds = NSRect(x: 0, y: 1, width: 9, height: 9)
        let location = (text as NSString).range(of: "· ").location + 2
        result.insert(NSAttributedString(attachment: attachment), at: location)
        result.insert(NSAttributedString(string: " "), at: location + 1)
        return result
    }
}

final class PressureHistoryView: NSView {
    var history = PressureHistory() {
        didSet {
            needsDisplay = true
            setAccessibilityLabel("Memory pressure history, last five minutes. Latest state: \(history.samples.last?.pressure.title ?? "Unavailable").")
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
        toolTip = "Green: normal. Yellow: warning. Red: critical. Grey: unavailable. Only measured states are shown; gaps and time before launch are not invented."
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ("Pressure · last 5 minutes" as NSString).draw(at: NSPoint(x: 17, y: 23),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let track = NSRect(x: 17, y: 7, width: bounds.width - 34, height: 9)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let now = ProcessInfo.processInfo.systemUptime
        let start = now - PressureHistory.duration
        for (index, sample) in history.samples.enumerated() {
            let next = index + 1 < history.samples.count ? history.samples[index + 1].timestamp : now
            // Samples arrive every two seconds. Never bridge long sleep/read gaps.
            let end = min(now, min(next, sample.timestamp + 6))
            let beginning = max(start, sample.timestamp)
            guard end >= beginning else { continue }
            let x = track.minX + (beginning - start) / PressureHistory.duration * track.width
            let width = min(track.maxX - x, max(1, (end - beginning) / PressureHistory.duration * track.width))
            guard width > 0 else { continue }
            MemoryVisuals.color(sample.pressure).setFill()
            NSRect(x: x, y: track.minY, width: width, height: track.height).fill()
        }
    }
}
