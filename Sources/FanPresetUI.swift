// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import AppKit

final class FanPresetView: NSView {
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 4, target: nil, action: nil)
    let label = NSTextField(labelWithString: "Automatic")
    let icon = NSImageView()
    var onChange: ((FanMode) -> Void)?
    var onGaugeImageChanged: ((NSImage) -> Void)?
    private(set) var selection: FanMode = .auto
    private(set) var gaugeValue = 0.0
    private var animation: Timer?
    private var animationStart = 0.0
    private var animationFrom = 0.0
    private var animationTarget = 0.0
    private(set) var capMode = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 66))
        autoresizingMask = [.width]
        icon.frame = NSRect(x: 17, y: 36, width: 22, height: 22)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .labelColor
        addSubview(icon)
        label.frame = NSRect(x: 47, y: 37, width: 256, height: 20)
        label.font = .menuFont(ofSize: 0)
        label.autoresizingMask = [.width]
        addSubview(label)
        slider.minValue = 0
        slider.maxValue = 4
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed(_:))
        slider.frame = NSRect(x: 17, y: 7, width: 286, height: 24)
        slider.autoresizingMask = [.width]
        slider.setAccessibilityLabel("Fan speed")
        addSubview(slider)
        update(.auto, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
    deinit { animation?.invalidate() }

    @objc private func changed(_ sender: NSSlider) {
        let mode = FanMode.sliderMode(value: sender.doubleValue)
        update(mode, capMode: capMode)
        onChange?(mode)
    }

    func update(_ mode: FanMode, capMode: Bool = false, animated: Bool = true) {
        precondition(mode.sliderIndex != nil && (!capMode || mode != .auto))
        selection = mode
        self.capMode = capMode
        slider.minValue = capMode ? 1 : 0
        slider.numberOfTickMarks = capMode ? 4 : 5
        label.stringValue = "\(capMode ? "Max speed" : "Speed") · \(mode.title)"
        slider.doubleValue = Double(mode.sliderIndex!)
        slider.setAccessibilityLabel(capMode ? "Max fan speed" : "Fan speed")
        slider.setAccessibilityValueDescription(mode.title)
        slider.needsDisplay = true
        let value = mode.sliderIndex.map { Double($0) / 4 } ?? 0
        animateGauge(to: value, animated: animated)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            animation?.invalidate()
            animation = nil
            setGauge(animationTarget)
        }
    }

    private func animateGauge(to value: Double, animated: Bool) {
        guard value != animationTarget || icon.image == nil else { return }
        animation?.invalidate()
        animation = nil
        animationTarget = value
        guard animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setGauge(value)
            return
        }
        animationStart = ProcessInfo.processInfo.systemUptime
        animationFrom = gaugeValue
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.animateFrame() }
        animation = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func animateFrame() {
        let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - animationStart) / 0.2))
        let eased = progress * progress * (3 - 2 * progress)
        setGauge(animationFrom + (animationTarget - animationFrom) * eased)
        if progress >= 1 {
            animation?.invalidate()
            animation = nil
        }
    }

    private func setGauge(_ value: Double) {
        gaugeValue = value
        let image = Self.gaugeImage(value: value)
        icon.image = image
        onGaugeImageChanged?(image)
    }

    static func gaugeImage(value: Double, native: Bool = true) -> NSImage {
        let value = value.isFinite ? min(1, max(0, value)) : 0
        if value == 0,
           let automatic = NSImage(systemSymbolName: "fan.badge.automatic", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil) {
            automatic.isTemplate = true
            return automatic
        }
        if native, #available(macOS 26.0, *),
           let symbol = NSImage(systemSymbolName: "fan.gauge.open", variableValue: value, accessibilityDescription: nil),
           let image = symbol.withSymbolConfiguration(.init(variableValueMode: .draw)) {
            image.isTemplate = true
            return image
        }
        // Older macOS releases do not have this symbol or variable drawing.
        let fan = NSImage(systemSymbolName: "fanblades", accessibilityDescription: nil)
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            fan?.draw(in: NSRect(x: 5, y: 4, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1)
            let track = NSBezierPath()
            track.appendArc(withCenter: NSPoint(x: 11, y: 11), radius: 10, startAngle: 225, endAngle: -45, clockwise: true)
            track.lineWidth = 1.5
            track.lineCapStyle = .round
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            track.stroke()
            if value > 0 {
                let line = NSBezierPath()
                line.appendArc(withCenter: NSPoint(x: 11, y: 11), radius: 10, startAngle: 225,
                               endAngle: CGFloat(225 - value * 270), clockwise: true)
                line.lineWidth = 1.5
                line.lineCapStyle = .round
                NSColor.labelColor.setStroke()
                line.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func runSelfTest() -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        let view = FanPresetView()
        check(view.slider.numberOfTickMarks == 5 && view.slider.allowsTickMarkValuesOnly, "Fan speed has five discrete stops")
        var requests: [FanMode] = []
        view.onChange = { requests.append($0) }
        for (index, mode) in FanMode.sliderModes.enumerated() {
            view.slider.doubleValue = Double(index)
            view.changed(view.slider)
            check(requests.last == mode && view.selection == mode, "Each slider stop requests the correct preset")
            check(view.gaugeValue == Double(index) / 4, "The gauge line follows the selected stop")
            check(view.label.stringValue == "Speed · \(mode.title)", "The selected speed label retains RPM or percentage")
        }
        for mode in FanMode.sliderModes.dropFirst() {
            view.update(mode, capMode: true)
            check(view.label.stringValue == "Max speed · \(mode.title)" && view.slider.isEnabled, "The same slider shows the selected speed cap")
        }
        view.slider.doubleValue = 0
        view.changed(view.slider)
        check(requests.last == .medium && view.capMode && view.slider.minValue == 1,
              "Automatic is unavailable in cap mode, even through accessibility input")
        view.update(.auto, capMode: false)
        check(view.slider.minValue == 0 && view.slider.numberOfTickMarks == 5,
              "Automatic becomes available again with temperature control Off")
        func pixels(_ image: NSImage) -> [UInt8] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return Array(UnsafeBufferPointer(start: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
        }
        for native in [false, true] {
            var previous: [UInt8]?
            for index in 0...4 {
                let image = gaugeImage(value: Double(index) / 4, native: native)
                let rendered = pixels(image)
                check(image.isTemplate && rendered.contains { $0 > 0 }, "Gauge icons render in the system appearance")
                if let previous = previous { check(rendered != previous, "Gauge line length must change at every stop") }
                previous = rendered
            }
        }
        if let automatic = NSImage(systemSymbolName: "fan.badge.automatic", accessibilityDescription: nil) {
            check(pixels(gaugeImage(value: 0)) == pixels(automatic), "Zero uses fan.badge.automatic")
        }
        check(pixels(gaugeImage(value: -.infinity)) == pixels(gaugeImage(value: 0)), "Invalid gauge values are safe")
        check(pixels(gaugeImage(value: 2)) == pixels(gaugeImage(value: 1)), "Gauge values are bounded")
        return checks
    }
}

final class TemperatureControlView: NSView {
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 56, target: nil, action: nil)
    let label = NSTextField(labelWithString: "Cool to · Off")
    var onChange: ((Double?) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 66))
        autoresizingMask = [.width]
        let icon = NSImageView(frame: NSRect(x: 17, y: 36, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: "thermometer", accessibilityDescription: nil)
        icon.contentTintColor = .labelColor
        addSubview(icon)
        label.frame = NSRect(x: 47, y: 37, width: 256, height: 20)
        label.font = .menuFont(ofSize: 0)
        label.autoresizingMask = [.width]
        addSubview(label)
        slider.frame = NSRect(x: 17, y: 7, width: 286, height: 24)
        slider.autoresizingMask = [.width]
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed(_:))
        slider.setAccessibilityLabel("Cool to")
        addSubview(slider)
        update(nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    @objc private func changed(_ sender: NSSlider) {
        let temperature = FanControlSelection.temperature(value: sender.doubleValue)
        update(temperature)
        onChange?(temperature)
    }

    func update(_ temperature: Double?) {
        slider.doubleValue = temperature.map { $0 - 29 } ?? 0
        let value = temperature.map { "\(Int($0))°C" } ?? "Off"
        label.stringValue = "Cool to · \(value)"
        slider.setAccessibilityValueDescription(value)
    }

    static func runSelfTest() -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        let view = TemperatureControlView()
        check(view.slider.doubleValue == 0 && view.label.stringValue == "Cool to · Off", "Temperature control starts Off")
        var requested: Double?
        view.onChange = { requested = $0 }
        for step in 1...56 {
            view.slider.doubleValue = Double(step)
            view.changed(view.slider)
            check(requested == Double(step + 29), "Temperature slider maps every active stop to 30...85 C")
        }
        view.slider.doubleValue = 0
        view.changed(view.slider)
        check(requested == nil && view.label.stringValue == "Cool to · Off", "Zero turns temperature control Off")
        return checks
    }
}
