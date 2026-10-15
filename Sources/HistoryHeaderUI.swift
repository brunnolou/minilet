// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import AppKit

enum HistoryHeader {
    static let iconSize: CGFloat = 14
    static let textX: CGFloat = 37

    static func icon(_ name: String) -> NSImage? {
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) { return symbol }
        guard name == "gpu" else { return nil }
        // macOS does not ship a GPU SF Symbol on all supported versions.
        // A small graphics card keeps it distinct from the native CPU chip.
        let card = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            NSColor.black.setStroke()
            let board = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 4.5, width: 10, height: 7), xRadius: 1, yRadius: 1)
            board.lineWidth = 1
            board.stroke()
            let fan = NSBezierPath(ovalIn: NSRect(x: 5.25, y: 5.75, width: 4.5, height: 4.5))
            fan.lineWidth = 1
            fan.stroke()
            let details = NSBezierPath()
            details.lineWidth = 1
            details.move(to: NSPoint(x: 1, y: 2))
            details.line(to: NSPoint(x: 1, y: 12.5))
            details.line(to: NSPoint(x: 3.5, y: 12.5))
            for x in [5.0, 7.5, 10.0] {
                details.move(to: NSPoint(x: x, y: 4.5))
                details.line(to: NSPoint(x: x, y: 2.5))
            }
            details.stroke()
            return true
        }
        card.isTemplate = true
        return card
    }

    static func draw(title: String, icon name: String, in bounds: NSRect, highlighted: Bool = false) {
        let color: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        if let source = icon(name) {
            let tinted = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { rect in
                source.draw(in: rect)
                color.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: NSRect(x: 17, y: bounds.height - 18, width: iconSize, height: iconSize))
        }
        (title as NSString).draw(at: NSPoint(x: textX, y: bounds.height - 20), withAttributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: color])
        let caption = "last 5 minutes" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color]
        caption.draw(at: NSPoint(x: bounds.width - 17 - caption.size(withAttributes: attributes).width,
                                y: bounds.height - 19), withAttributes: attributes)
    }

    static func runSelfTest() -> Int {
        var checks = 0
        for name in ["cpu", "gpu", "memorychip"] {
            precondition(icon(name)?.tiffRepresentation != nil, "Every monitor header has a renderable icon")
            checks += 1
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 60,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    draw(title: "Monitor   50%", icon: name, in: NSRect(x: 0, y: 0, width: 320, height: 60))
                }
                NSGraphicsContext.restoreGraphicsState()
                let hasIcon = (17..<31).contains { x in
                    (4..<18).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
                }
                precondition(hasIcon, "Header icon is visible in light and dark appearances")
                checks += 1
            }
        }
        return checks
    }
}
