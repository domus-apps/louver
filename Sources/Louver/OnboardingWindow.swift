import AppKit
import CoreAudio

/* First-run onboarding: what Louver is, and the System Audio Recording
   permission gate — process taps are how per-app volume works. The window
   has no close button and refuses every close attempt; the only way out is
   granting access and clicking Start, and completion is persisted only at
   that click, so quitting mid-onboarding brings it back on the next launch.

   Unlike Accessibility there is no trusted-check API for audio capture:
   actually creating a tap is both the permission request (first time) and
   the status probe (afterwards). The probe tap is unmuted, private, and
   destroyed immediately — zero audible effect. */
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onComplete: () -> Void
    private var pollTimer: Timer?

    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var requestButton = NSButton(
        title: "Enable Per-App Volume", target: self,
        action: #selector(requestAccess))
    private lazy var settingsLink = NSButton(
        title: "Open Privacy & Security Settings…", target: self,
        action: #selector(openSystemSettings))
    private lazy var startButton = NSButton(
        title: "Start Using Louver", target: self, action: #selector(start))

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        /* No .closable: the traffic-light close button never appears. */
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 596),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()

        refreshPermissionState()
        /* Permission grants don't notify; polling once a second is the
           standard idiom (the System Settings toggle takes effect live). */
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            self?.refreshPermissionState()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /* The gate: no closing until onboarding is completed via start(). */
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }

    // MARK: - Content

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Welcome to Louver")
        title.font = .systemFont(ofSize: 30, weight: .bold)

        let intro = NSTextField(
            wrappingLabelWithString:
                "Louver gives every app its own volume. Open the menu bar icon "
                + "for a slider and mute button per app — apps at full volume "
                + "are untouched, and nothing is recorded or stored.")
        intro.font = .systemFont(ofSize: 14)
        intro.textColor = .secondaryLabelColor
        intro.alignment = .center
        intro.preferredMaxLayoutWidth = 470

        let illustration = OnboardingIllustrationView()
        illustration.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            illustration.widthAnchor.constraint(equalToConstant: 480),
            illustration.heightAnchor.constraint(equalToConstant: 190),
        ])

        let hint = NSTextField(
            labelWithString: "Turn an app down and it stays that way until you turn it back up")
        hint.font = .systemFont(ofSize: 14)
        hint.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 13)
        requestButton.bezelStyle = .rounded
        requestButton.keyEquivalent = "\r"
        settingsLink.isBordered = false
        settingsLink.contentTintColor = .linkColor
        settingsLink.font = .systemFont(ofSize: 12)

        let permissionBox = NSStackView(
            views: [statusLabel, requestButton, settingsLink])
        permissionBox.orientation = .vertical
        permissionBox.alignment = .centerX
        permissionBox.spacing = 8

        startButton.bezelStyle = .rounded
        startButton.controlSize = .large

        let stack = NSStackView(
            views: [title, intro, illustration, hint, permissionBox, startButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(10, after: title)
        stack.setCustomSpacing(22, after: intro)
        stack.setCustomSpacing(24, after: hint)
        stack.setCustomSpacing(20, after: permissionBox)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
        ])
        return container
    }

    // MARK: - Permission gate

    /* Creating (and immediately destroying) a harmless probe tap doubles as
       the TCC request and the status check. */
    static func probeAudioCaptureAccess() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Louver permission probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            return false
        }
        AudioHardwareDestroyProcessTap(tapID)
        return true
    }

    private func refreshPermissionState() {
        let granted = Self.probeAudioCaptureAccess()
        statusLabel.stringValue =
            granted
            ? "✓ System audio access granted"
            : "Louver needs System Audio Recording access to adjust each app's volume."
        statusLabel.textColor = granted ? .systemGreen : .labelColor
        requestButton.isHidden = granted
        settingsLink.isHidden = granted
        startButton.isEnabled = granted
        startButton.keyEquivalent = granted ? "\r" : ""
    }

    @objc private func requestAccess() {
        /* The system prompt appears only on the very first probe; afterwards
           macOS stays silent, so the settings link below is the fallback. */
        _ = Self.probeAudioCaptureAccess()
        refreshPermissionState()
    }

    @objc private func openSystemSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security"
                    + "?Privacy_AudioCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func start() {
        guard Self.probeAudioCaptureAccess() else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        window?.delegate = nil
        onComplete()
        close()
    }
}

/* A drawn "screenshot" of Louver in action: the menu bar with the speaker
   icon, and beneath it the open menu with two app rows — one at full
   volume, one pulled down. Drawn (not a bundled image) so it stays crisp
   at any backing scale and needs no resource plumbing. */
private final class OnboardingIllustrationView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let canvas = bounds

        // Backdrop in the app's warm slate
        let backdrop = NSBezierPath(roundedRect: canvas, xRadius: 12, yRadius: 12)
        NSGradient(
            starting: NSColor(srgbRed: 0.16, green: 0.14, blue: 0.11, alpha: 1),
            ending: NSColor(srgbRed: 0.08, green: 0.07, blue: 0.05, alpha: 1)
        )?.draw(in: backdrop, angle: -90)

        // Menu bar strip
        let bar = NSRect(x: 12, y: canvas.maxY - 34, width: canvas.width - 24, height: 24)
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()

        // Neighbor status icons (quiet dots) and the speaker
        for index in 0..<3 {
            let dot = NSRect(
                x: bar.maxX - 110 + CGFloat(index) * 26, y: bar.midY - 4,
                width: 8, height: 8)
            NSColor.white.withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        let speaker = NSImage(
            systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        speaker?.withSymbolConfiguration(
            .init(pointSize: 12, weight: .medium)
        )?.draw(
            in: NSRect(x: bar.maxX - 30, y: bar.midY - 7, width: 16, height: 14))

        // The open menu card with two app volume rows
        let menu = NSRect(x: bar.maxX - 240, y: bar.minY - 128, width: 230, height: 120)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        NSColor(srgbRed: 0.94, green: 0.94, blue: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: menu, xRadius: 9, yRadius: 9).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        func volumeRow(name: String, y: CGFloat, level: CGFloat) {
            let label = NSAttributedString(
                string: name,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.black.withAlphaComponent(0.85),
                ])
            label.draw(at: NSPoint(x: menu.minX + 14, y: y + 16))

            let track = NSRect(x: menu.minX + 14, y: y + 6, width: 176, height: 4)
            NSColor.black.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let fill = NSRect(
                x: track.minX, y: track.minY, width: track.width * level, height: 4)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            let knob = NSRect(
                x: track.minX + track.width * level - 5, y: track.midY - 5,
                width: 10, height: 10)
            NSColor.white.setFill()
            let knobPath = NSBezierPath(ovalIn: knob)
            knobPath.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            knobPath.stroke()

            let mute = NSImage(
                systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
            mute?.draw(
                in: NSRect(x: menu.maxX - 26, y: y + 2, width: 12, height: 11))
        }
        volumeRow(name: "Music", y: menu.maxY - 52, level: 0.85)
        volumeRow(name: "Brave Browser", y: menu.maxY - 104, level: 0.3)
    }
}
