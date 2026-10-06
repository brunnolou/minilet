import AppKit

enum MiniletLinks {
    static let support = URL(string: "https://buymeacoffee.com/brunnolou")!
}

final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private static let hideOnLaunchKey = "hideWelcomeOnLaunch"
    private let defaults: UserDefaults
    private let dontShowAgain = NSButton(checkboxWithTitle: "Don't show this at startup", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Got it", target: nil, action: nil)
    private let supportButton = NSButton(title: "Buy me a coffee", target: nil, action: nil)

    static func shouldShowOnLaunch(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: hideOnLaunchKey)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Minilet"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        createContent()
    }

    required init?(coder: NSCoder) { fatalError("Use init(defaults:)") }

    private func createContent() {
        guard let content = window?.contentView else { return }
        let icon = NSImageView(frame: NSRect(x: 194, y: 246, width: 72, height: 72))
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let heading = NSTextField(labelWithString: "Minilet lives in your menu bar")
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        heading.alignment = .center
        heading.frame = NSRect(x: 24, y: 202, width: 412, height: 30)
        content.addSubview(heading)

        let instructions = NSTextField(wrappingLabelWithString:
            "Look for the fan icon near the clock.\nClick it for temperatures and fan controls.")
        instructions.font = .systemFont(ofSize: 13)
        instructions.textColor = .secondaryLabelColor
        instructions.alignment = .center
        instructions.frame = NSRect(x: 34, y: 147, width: 392, height: 50)
        content.addSubview(instructions)

        let note = NSTextField(labelWithString: "Closing this window keeps Minilet running.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.frame = NSRect(x: 34, y: 117, width: 392, height: 20)
        content.addSubview(note)

        dontShowAgain.font = .systemFont(ofSize: 12)
        dontShowAgain.frame = NSRect(x: 120, y: 80, width: 220, height: 22)
        dontShowAgain.state = defaults.bool(forKey: Self.hideOnLaunchKey) ? .on : .off
        content.addSubview(dontShowAgain)

        supportButton.target = self
        supportButton.action = #selector(openSupport)
        supportButton.isBordered = false
        supportButton.font = .systemFont(ofSize: 13)
        supportButton.contentTintColor = .linkColor
        supportButton.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        supportButton.image?.isTemplate = true
        supportButton.imagePosition = .imageLeading
        supportButton.toolTip = MiniletLinks.support.absoluteString
        supportButton.frame = NSRect(x: 24, y: 24, width: 172, height: 32)
        content.addSubview(supportButton)

        dismissButton.target = self
        dismissButton.action = #selector(dismissWelcome)
        dismissButton.bezelStyle = .rounded
        dismissButton.keyEquivalent = "\r"
        dismissButton.frame = NSRect(x: 330, y: 24, width: 106, height: 32)
        content.addSubview(dismissButton)
        window?.defaultButtonCell = dismissButton.cell as? NSButtonCell
    }

    func present() {
        dontShowAgain.state = defaults.bool(forKey: Self.hideOnLaunchKey) ? .on : .off
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        defaults.set(dontShowAgain.state == .on, forKey: Self.hideOnLaunchKey)
    }

    @objc private func dismissWelcome() { close() }
    @objc private func openSupport() { NSWorkspace.shared.open(MiniletLinks.support) }

    // Tests use an isolated preference domain, never the user's settings.
    static func runSelfTest() -> Int {
        let suite = "minilet-welcome-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        check(shouldShowOnLaunch(defaults: defaults), "Welcome appears on launch by default")
        defaults.set(true, forKey: hideOnLaunchKey)
        check(!shouldShowOnLaunch(defaults: defaults), "Startup suppression must persist")
        let controller = WelcomeWindowController(defaults: defaults)
        check(controller.dontShowAgain.state == .on, "Welcome reflects the saved preference")
        check(controller.window?.styleMask.contains(.closable) == true, "Welcome must have a close button")
        check(controller.dismissButton.action == #selector(dismissWelcome), "Got it must close only the welcome window")
        check(controller.supportButton.action == #selector(openSupport), "Welcome has a working support action")
        check(MiniletLinks.support.absoluteString == "https://buymeacoffee.com/brunnolou", "Support must use the requested URL")
        controller.dontShowAgain.state = .off
        controller.dismissButton.performClick(nil)
        check(shouldShowOnLaunch(defaults: defaults), "Closing saves the unchecked preference")
        controller.dontShowAgain.state = .on
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
        check(!shouldShowOnLaunch(defaults: defaults), "The window close button also saves the checkbox")
        check(controller.window != nil, "Closed welcome windows remain available for reopening")
        return checks
    }
}
