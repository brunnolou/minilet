// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import AppKit

enum StatusMeters {
    static let width: CGFloat = 32
    static let height: CGFloat = 14
    static let squareSize: CGFloat = 2
    static let gap: CGFloat = 1

    static func image(memory: MemorySnapshot?, processors: ProcessorSnapshot?) -> NSImage {
        let ram = MemoryVisuals.usageBar(fraction: memory?.usageFraction, pressure: memory?.pressure ?? .unknown)
        let cpu = ProcessorTiles.opacities(processors?.cpu)
        let gpu = ProcessorTiles.opacities(processors?.gpu.map { [$0] })
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            ram.draw(in: NSRect(x: 0, y: 6, width: width, height: 8), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            drawSquares(cpu, at: 3)
            drawSquares(gpu, at: 0)
            NSGraphicsContext.restoreGraphicsState()
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
            NSRect(x: CGFloat(index) * (squareSize + gap), y: y, width: squareSize, height: squareSize).fill()
        }
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
        check(CGFloat(ProcessorTiles.count) * squareSize + CGFloat(ProcessorTiles.count - 1) * gap == width,
              "Eleven 2x2 squares and ten 1px gaps match the 32px RAM width")
        check(image(memory: nil, processors: oneCore).size == NSSize(width: 32, height: 14),
              "All three meters fit in a fourteen-point stack")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let one = bitmap(oneCore, appearance: appearance)
            let empty = bitmap(noLoad, appearance: appearance)
            let full = bitmap(fullLoad, appearance: appearance)
            for tile in 0..<11 {
                let x = tile * 6 + 1
                check(abs((one.colorAt(x: x, y: 19)?.alphaComponent ?? 0) - 1 / 12.0) < 0.01,
                      "One busy CPU core fills every square at exactly 1/12 opacity")
                check((full.colorAt(x: x, y: 19)?.alphaComponent ?? 0) > 0.99,
                      "All busy cores fill every CPU square opaquely")
                check((empty.colorAt(x: x, y: 19)?.alphaComponent ?? 0) > 0.4,
                      "Unused squares retain a visible full-width track")
                if tile < 10 {
                    check((one.colorAt(x: x + 3, y: 19)?.alphaComponent ?? 1) == 0,
                          "One-point gaps remain transparent")
                }
            }
            check((one.colorAt(x: 1, y: 23)?.alphaComponent ?? 1) == 0 && (one.colorAt(x: 1, y: 17)?.alphaComponent ?? 1) == 0,
                  "CPU, GPU and RAM rows have one-point vertical gaps")
            check((one.colorAt(x: 1, y: 26)?.alphaComponent ?? 0) > 0.99,
                  "GPU aggregate usage fills its own row")
        }
        let light = bitmap(noLoad, appearance: .aqua).colorAt(x: 1, y: 19)!.usingColorSpace(.deviceRGB)!
        let dark = bitmap(noLoad, appearance: .darkAqua).colorAt(x: 1, y: 19)!.usingColorSpace(.deviceRGB)!
        check(light.redComponent > dark.redComponent, "The unfilled track inverts between light and dark appearance")
        return checks
    }
}
