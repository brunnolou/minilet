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
    static let backgroundPadding: CGFloat = 0.5
    static let trackHeight = squareSize + backgroundPadding * 2
    static let gpuY = backgroundPadding
    static let cpuY = trackHeight + rowGap + backgroundPadding
    static let ramY = (trackHeight + rowGap) * 2
    static let height = ramY + 4
    static let insetX = (width - (CGFloat(ProcessorTiles.count) * (squareSize + gap) - gap)) / 2

    static func image(memory: MemorySnapshot?, processors: ProcessorSnapshot?, includeBackgrounds: Bool = true) -> NSImage {
        let ram = MemoryVisuals.usageBar(fraction: memory?.usageFraction, pressure: memory?.pressure ?? .unknown)
        let cpu = ProcessorTiles.opacities(processors?.cpu)
        let gpu = processors?.gpu
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            ram.draw(in: NSRect(x: 0, y: ramY, width: width, height: 4), from: .zero, operation: .sourceOver, fraction: 1)
            if includeBackgrounds {
                drawBackground(at: cpuY)
                drawBackground(at: gpuY)
            }
            drawSquares(cpu, at: cpuY)
            drawGPU(gpu)
            return true
        }
    }

    private static func drawBackground(at y: CGFloat) {
        let rect = NSRect(x: 0, y: y - backgroundPadding, width: width, height: trackHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = true
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = 0.5
        shadow.shadowColor = NSColor.labelColor.withAlphaComponent(0.12)
        shadow.set()
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        MemoryVisuals.capsule(rect).fill()
        NSGraphicsContext.restoreGraphicsState()
        let border = MemoryVisuals.capsule(rect.insetBy(dx: 0.25, dy: 0.25))
        border.lineWidth = 0.5
        NSColor.labelColor.withAlphaComponent(0.3).setStroke()
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawSquares(_ opacities: [Double], at y: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = true
        MemoryVisuals.capsule(NSRect(x: insetX, y: y, width: width - insetX * 2, height: squareSize)).addClip()
        NSGraphicsContext.current?.shouldAntialias = false
        for (index, opacity) in opacities.enumerated() {
            // Active squares retain their exact core-overlap alpha. Only unused
            // squares use the inverse theme color; no backing raises low loads.
            let color = opacity > 0 ? NSColor.labelColor.withAlphaComponent(opacity)
                                    : NSColor.textBackgroundColor.withAlphaComponent(0.45)
            color.setFill()
            NSRect(x: insetX + CGFloat(index) * (squareSize + gap), y: y, width: squareSize, height: squareSize).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawGPU(_ usage: Double?) {
        let rect = NSRect(x: insetX, y: gpuY, width: width - insetX * 2, height: squareSize)
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
        MemoryVisuals.capsule(rect).addClip()
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
        func bitmap(_ processors: ProcessorSnapshot, appearance: NSAppearance.Name, includeBackgrounds: Bool = false) -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                image(memory: nil, processors: processors, includeBackgrounds: includeBackgrounds).draw(in: NSRect(x: 0, y: 0, width: 64, height: 32),
                    from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        check(CGFloat(ProcessorTiles.count) * squareSize + CGFloat(ProcessorTiles.count - 1) * gap + insetX * 2 == width && insetX == 0.5,
              "Eight 3x3 squares and seven 1px gaps are centered within the 32px RAM width")
        check(image(memory: nil, processors: oneCore).size == NSSize(width: 32, height: 16),
              "Rounded backplates and two-point row gaps fit in a centered sixteen-point stack")
        check(gpuStrokeWidth == 2 && gpuStrokeGap == 1, "GPU uses two-point vector strokes with one-point perpendicular gaps")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let one = bitmap(oneCore, appearance: appearance)
            let empty = bitmap(noLoad, appearance: appearance)
            let full = bitmap(fullLoad, appearance: appearance)
            let lightlyActive = bitmap(ProcessorSnapshot(cpu: Array(repeating: 0.001, count: 12), gpu: 0), appearance: appearance)
            check((lightlyActive.colorAt(x: 2, y: 15)?.alphaComponent ?? 0) > 0.99,
                  "Light activity on every core renders the leading CPU square opaquely")
            check(abs((lightlyActive.colorAt(x: 10, y: 15)?.alphaComponent ?? 0) - 0.45) < 0.01,
                  "Light background activity does not extend CPU progress into later squares")
            let decorated = bitmap(oneCore, appearance: appearance, includeBackgrounds: true)
            let backgroundAlpha = decorated.colorAt(x: 7, y: 15)?.alphaComponent ?? 0
            check(backgroundPadding == 0.5 && trackHeight == 4, "Backplates extend half a point around three-point patterns")
            check(backgroundAlpha > 0.1 && backgroundAlpha < 0.4, "CPU square gaps reveal the soft rounded background")
            check((decorated.colorAt(x: 6, y: 27)?.alphaComponent ?? 0) > 0.1,
                  "GPU stripe gaps reveal the soft rounded background")
            let expectedAlpha = backgroundAlpha + (1 - backgroundAlpha) / 12
            check(abs((decorated.colorAt(x: 2, y: 15)?.alphaComponent ?? 0) - expectedAlpha) < 0.02,
                  "CPU core-overlap opacity is unchanged over its new background")
            check((decorated.colorAt(x: 20, y: 12)?.alphaComponent ?? 0) > 0.05 && (one.colorAt(x: 20, y: 12)?.alphaComponent ?? 1) == 0,
                  "Background padding is visible above the CPU pattern")
            check((decorated.colorAt(x: 20, y: 31)?.alphaComponent ?? 0) > 0.05 && (one.colorAt(x: 20, y: 31)?.alphaComponent ?? 1) == 0,
                  "Background padding is visible below the GPU pattern")
            check([(0, 12), (63, 12), (0, 19), (63, 19), (0, 24), (63, 24), (0, 31), (63, 31)].allSatisfy {
                (decorated.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) < 0.25
            }, "Backplates have rounded corners, not rectangular backgrounds")
            check([9, 21].allSatisfy { (decorated.colorAt(x: 20, y: $0)?.alphaComponent ?? 1) < 0.02 },
                  "Backgrounds remain separated with clear space between rows")
            check([(1, 13), (1, 18), (62, 13), (62, 18)].allSatisfy {
                (full.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) < 0.25
            }, "CPU track has rounded outer corners at both ends")
            check([(1, 25), (1, 30), (62, 25), (62, 30)].allSatisfy {
                (full.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) < 0.25
            }, "GPU diagonal track has rounded outer corners at both ends")
            for tile in 0..<ProcessorTiles.count {
                let x = tile * 8 + 2
                check(abs((one.colorAt(x: x, y: 15)?.alphaComponent ?? 0) - 1 / 12.0) < 0.01,
                      "One busy CPU core fills every square at exactly 1/12 opacity")
                check((full.colorAt(x: x, y: 15)?.alphaComponent ?? 0) > 0.99,
                      "All busy cores fill every CPU square opaquely")
                check((empty.colorAt(x: x, y: 15)?.alphaComponent ?? 0) > 0.4,
                      "Unused squares retain a visible full-width track")
                if tile < ProcessorTiles.count - 1 {
                    check((one.colorAt(x: x + 5, y: 15)?.alphaComponent ?? 1) == 0,
                          "One-point gaps remain transparent")
                }
            }
            check([8, 9, 10, 11, 20, 21, 22, 23].allSatisfy { (one.colorAt(x: 2, y: $0)?.alphaComponent ?? 1) == 0 },
                  "CPU, GPU and RAM rows have two-point vertical gaps")
            check((one.colorAt(x: 2, y: 27)?.alphaComponent ?? 0) > 0.99,
                  "GPU aggregate usage fills its diagonal row")
            check((full.colorAt(x: 6, y: 27)?.alphaComponent ?? 1) < 0.01,
                  "GPU diagonal strokes have transparent gaps even at full usage")
            check((full.colorAt(x: 2, y: 26)?.alphaComponent ?? 0) > (full.colorAt(x: 2, y: 30)?.alphaComponent ?? 1) + 0.4,
                  "GPU lines slope sideways across the row instead of forming square pixels")
            check(abs((empty.colorAt(x: 2, y: 27)?.alphaComponent ?? 0) - 0.45) < 0.01,
                  "An idle GPU retains the inverse-theme diagonal track")
            check((one.colorAt(x: 38, y: 27)?.alphaComponent ?? 0) < 0.5 && (full.colorAt(x: 38, y: 27)?.alphaComponent ?? 0) > 0.5,
                  "GPU progress clips at its measured utilization, leaving the rest as track")
        }
        let light = bitmap(noLoad, appearance: .aqua).colorAt(x: 2, y: 15)!.usingColorSpace(.deviceRGB)!
        let dark = bitmap(noLoad, appearance: .darkAqua).colorAt(x: 2, y: 15)!.usingColorSpace(.deviceRGB)!
        check(light.redComponent > dark.redComponent, "The unfilled track inverts between light and dark appearance")
        return checks
    }
}
