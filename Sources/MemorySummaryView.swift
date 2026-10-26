// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 brunnolou
// Distributed without warranty. See LICENSE.md and NOTICE.

import AppKit

final class MemorySummaryView: NSView {
    let labels = (0..<3).map { _ in NSTextField(labelWithString: "") }
    private let pressureIcon = NSImageView()
    private let arrow = NSImageView()
    let history: PressureHistoryView
    private var hoverArea: NSTrackingArea?
    private var hoverTimer: Timer?
    private var pointerInside = false
    private var menuTracking = false
    var isHoverPolling: Bool { hoverTimer?.isValid == true }

    init(history: PressureHistoryView) {
        self.history = history
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 138))
        autoresizingMask = [.width]
        for (index, label) in labels.enumerated() {
            label.font = .menuFont(ofSize: 0)
            label.textColor = .secondaryLabelColor
            label.autoresizingMask = [.width]
            label.frame = NSRect(x: 36, y: CGFloat(56 - index * 24), width: 260, height: 20)
            addSubview(label)
        }
        pressureIcon.frame = NSRect(x: 19, y: 60, width: 9, height: 9)
        addSubview(pressureIcon)
        arrow.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        arrow.image?.isTemplate = true
        arrow.frame = NSRect(x: 302, y: 63, width: 7, height: 12)
        arrow.autoresizingMask = [.minXMargin]
        addSubview(arrow)
        history.frame.origin = NSPoint(x: 0, y: 78)
        history.autoresizingMask = [.width]
        // The parent block owns the hit area, including the history graphic.
        history.toolTip = nil
        addSubview(history)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
    }

    required init?(coder: NSCoder) { fatalError("Use init(history:)") }

    func update(titles: [String], pressure: NSImage?, usage: String?) {
        history.usage = usage ?? "Unavailable"
        for (label, title) in zip(labels, titles.dropFirst()) { label.stringValue = title }
        pressureIcon.image = pressure
        setAccessibilityLabel(titles.joined(separator: ". "))
        needsDisplay = true
    }

    // Let AppKit treat the full custom view as one native submenu item rather
    // than separate text/history hit areas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview == nil ? point : convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        if let area = hoverArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setMenuTracking(menuTracking)
    }

    func setMenuTracking(_ tracking: Bool) {
        menuTracking = tracking
        hoverTimer?.invalidate()
        hoverTimer = nil
        pointerInside = false
        guard tracking, window != nil else { return }
        // Menu windows can retain their views after closing. Poll only during
        // an actual root-menu session, not merely while attached to a window.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkHover() }
        timer.tolerance = 0.01
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    deinit { hoverTimer?.invalidate() }

    private func checkHover() {
        guard let window = window, window.isVisible else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let inside = bounds.contains(point)
        let entered = inside && !pointerInside
        pointerInside = inside
        if entered { openSubmenu() }
    }

    private func openSubmenu() {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        menu.performActionForItem(at: menu.index(of: item))
    }

    override func mouseEntered(with event: NSEvent) { openSubmenu() }
    override func mouseDown(with event: NSEvent) { openSubmenu() }
    override func accessibilityPerformPress() -> Bool { openSubmenu(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted == true
        history.menuHighlighted = highlighted
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
        let color: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        labels.forEach { $0.textColor = color }
        arrow.contentTintColor = color
    }
}
