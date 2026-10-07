// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import AppKit

enum MemoryVisuals {
    static func color(_ pressure: MemoryPressure) -> NSColor {
        switch pressure {
        case .normal: return NSColor.labelColor.withAlphaComponent(1)
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

    static func capsule(_ rect: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    }

    static func usageBar(fraction: Double?, pressure: MemoryPressure) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 12), flipped: false) { _ in
            let track = NSRect(x: 0.5, y: 0.5, width: 31, height: 11)
            let outline = capsule(track)
            NSColor.labelColor.withAlphaComponent(0.16).setFill()
            outline.fill()
            if let fraction = fraction, fraction.isFinite {
                NSGraphicsContext.saveGraphicsState()
                outline.addClip()
                color(pressure).setFill()
                NSRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, fraction)), height: track.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            return true
        }
    }

    static func statusTitle(temperature: Double?, memory: MemorySnapshot?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: " \(MemoryFormat.temperatureTitle(temperature))  ",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: NSColor.labelColor])
        let attachment = NSTextAttachment()
        attachment.image = usageBar(fraction: memory?.usageFraction, pressure: memory?.pressure ?? .unknown)
        attachment.bounds = NSRect(x: 0, y: -1, width: 32, height: 12)
        result.append(NSAttributedString(attachment: attachment))
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
        toolTip = "Memory pressure over the last five minutes."
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ("Pressure · last 5 minutes" as NSString).draw(at: NSPoint(x: 17, y: 23),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let track = NSRect(x: 17, y: 7, width: bounds.width - 34, height: 9)
        let outline = MemoryVisuals.capsule(track)
        NSColor.quaternaryLabelColor.setFill()
        outline.fill()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        let now = ProcessInfo.processInfo.systemUptime
        let start = now - PressureHistory.duration
        for span in history.spans(until: now) {
            let x = track.minX + (span.start - start) / PressureHistory.duration * track.width
            let width = (span.end - span.start) / PressureHistory.duration * track.width
            MemoryVisuals.color(span.pressure).setFill()
            NSRect(x: x, y: track.minY, width: width, height: track.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
