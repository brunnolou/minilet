// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import AppKit

enum StatusMeters {
    static let width: CGFloat = 32
    static let squareSize: CGFloat = 3
    static let gap: CGFloat = 1
    static let gpuStrokeWidth: CGFloat = 2
    static let gpuStrokeGap: CGFloat = 1
    static let rowGap: CGFloat = 2
    static let cpuY = squareSize + rowGap
    static let ramY = cpuY + squareSize + rowGap
    static let height = ramY + 4
    static let insetX = (width - (CGFloat(ProcessorTiles.count) * (squareSize + gap) - gap)) / 2

    static func image(memory: MemorySnapshot?, processors: ProcessorSnapshot?) -> NSImage {
        let ram = MemoryVisuals.usageBar(fraction: memory?.usageFraction, pressure: memory?.pressure ?? .unknown)
        let cpu = ProcessorTiles.opacities(processors?.cpu)
        let gpu = processors?.gpu
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            ram.draw(in: NSRect(x: 0, y: ramY, width: width, height: 4), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            drawSquares(cpu, at: cpuY)
            NSGraphicsContext.restoreGraphicsState()
            drawGPU(gpu)
            return true
        }
    }

    private static func drawSquares(_ opacities: [Double], at y: CGFloat) {
        for (index, opacity) in opacities.enumerated() {
            // Active squares retain their exact core-overlap alpha. Only unused
            // squares use the inverse theme color; no backing raises low loads.
            let color = opacity > 0 ? NSColor.labelColor.withAlphaComponent(opacity)
                                    : NSColor.textBackgroundColor.withAlphaComponent(0.45)
            color.setFill()
            NSRect(x: insetX + CGFloat(index) * (squareSize + gap), y: y, width: squareSize, height: squareSize).fill()
        }
    }

    private static func drawGPU(_ usage: Double?) {
        let rect = NSRect(x: insetX, y: 0, width: width - insetX * 2, height: squareSize)
        let fraction = usage.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil } ?? 0
        let fillX = rect.minX + rect.width * CGFloat(fraction)
        // Stroke width and gaps are measured perpendicular to the 45-degree
        // lines. Horizontal spacing is therefore sqrt(2) times their sum.
        let period = (gpuStrokeWidth + gpuStrokeGap) * sqrt(2)
        let phase = rect.minX + gpuStrokeWidth / 2 - rect.height / 2
        let lines = NSBezierPath()
        lines.lineWidth = gpuStrokeWidth
        lines.lineCapStyle = .butt
        for x in stride(from: phase - period * 2, through: rect.maxX + period, by: period) {
            lines.move(to: NSPoint(x: x - rect.height, y: rect.maxY + rect.height))
            lines.line(to: NSPoint(x: x + rect.height * 2, y: rect.minY - rect.height))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = true
        rect.clip()
        func stroke(in region: NSRect, color: NSColor) {
            guard region.width > 0 else { return }
            NSGraphicsContext.saveGraphicsState()
            region.clip()
            color.setStroke()
            lines.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        stroke(in: NSRect(x: rect.minX, y: rect.minY, width: fillX - rect.minX, height: rect.height),
               color: NSColor.labelColor.withAlphaComponent(1))
        stroke(in: NSRect(x: fillX, y: rect.minY, width: rect.maxX - fillX, height: rect.height),
               color: NSColor.textBackgroundColor.withAlphaComponent(0.45))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func runSelfTest() -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        let oneCore = ProcessorSnapshot(cpu: [1] + Array(repeating: 0, count: 11), gpu: 0.5)
        let noLoad = ProcessorSnapshot(cpu: Array(repeating: 0, count: 12), gpu: 0)
        let fullLoad = ProcessorSnapshot(cpu: Array(repeating: 1, count: 12), gpu: 1)
        func bitmap(_ processors: ProcessorSnapshot, appearance: NSAppearance.Name) -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 28,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                image(memory: nil, processors: processors).draw(in: NSRect(x: 0, y: 0, width: 64, height: 28),
                    from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        check(CGFloat(ProcessorTiles.count) * squareSize + CGFloat(ProcessorTiles.count - 1) * gap + insetX * 2 == width && insetX == 0.5,
              "Eight 3x3 squares and seven 1px gaps are centered within the 32px RAM width")
        check(image(memory: nil, processors: oneCore).size == NSSize(width: 32, height: 14),
              "All three meters fit in a fourteen-point stack with wider vertical gaps")
        check(gpuStrokeWidth == 2 && gpuStrokeGap == 1, "GPU uses two-point vector strokes with one-point perpendicular gaps")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let one = bitmap(oneCore, appearance: appearance)
            let empty = bitmap(noLoad, appearance: appearance)
            let full = bitmap(fullLoad, appearance: appearance)
            for tile in 0..<ProcessorTiles.count {
                let x = tile * 8 + 2
                check(abs((one.colorAt(x: x, y: 14)?.alphaComponent ?? 0) - 1 / 12.0) < 0.01,
                      "One busy CPU core fills every square at exactly 1/12 opacity")
                check((full.colorAt(x: x, y: 14)?.alphaComponent ?? 0) > 0.99,
                      "All busy cores fill every CPU square opaquely")
                check((empty.colorAt(x: x, y: 14)?.alphaComponent ?? 0) > 0.4,
                      "Unused squares retain a visible full-width track")
                if tile < ProcessorTiles.count - 1 {
                    check((one.colorAt(x: x + 5, y: 14)?.alphaComponent ?? 1) == 0,
                          "One-point gaps remain transparent")
                }
            }
            check([8, 9, 10, 11, 18, 19, 20, 21].allSatisfy { (one.colorAt(x: 2, y: $0)?.alphaComponent ?? 1) == 0 },
                  "CPU, GPU and RAM rows have two-point vertical gaps")
            check((one.colorAt(x: 2, y: 24)?.alphaComponent ?? 0) > 0.99,
                  "GPU aggregate usage fills its diagonal row")
            check((full.colorAt(x: 6, y: 24)?.alphaComponent ?? 1) < 0.01,
                  "GPU diagonal strokes have transparent gaps even at full usage")
            check((full.colorAt(x: 2, y: 23)?.alphaComponent ?? 0) > (full.colorAt(x: 2, y: 27)?.alphaComponent ?? 1) + 0.4,
                  "GPU lines slope sideways across the row instead of forming square pixels")
            check(abs((empty.colorAt(x: 2, y: 24)?.alphaComponent ?? 0) - 0.45) < 0.01,
                  "An idle GPU retains the inverse-theme diagonal track")
            check((one.colorAt(x: 38, y: 24)?.alphaComponent ?? 0) < 0.5 && (full.colorAt(x: 38, y: 24)?.alphaComponent ?? 0) > 0.5,
                  "GPU progress clips at its measured utilization, leaving the rest as track")
        }
        let light = bitmap(noLoad, appearance: .aqua).colorAt(x: 2, y: 14)!.usingColorSpace(.deviceRGB)!
        let dark = bitmap(noLoad, appearance: .darkAqua).colorAt(x: 2, y: 14)!.usingColorSpace(.deviceRGB)!
        check(light.redComponent > dark.redComponent, "The unfilled track inverts between light and dark appearance")
        return checks
    }
}
