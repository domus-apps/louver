import AppKit

/* The status-item menu: one slider row per audio app, mimicking the system
   Sound menu. View-backed NSMenuItems receive full mouse events during menu
   tracking, so continuous sliders and mute buttons work in place — and
   clicks on them don't dismiss the menu, which is exactly right here. */
final class VolumeMenu: NSObject, NSMenuDelegate {
    private let engine: AudioEngine
    private let onOpenSettings: () -> Void
    private let makeUpdaterItem: () -> NSMenuItem

    private var rows: [AppVolumeRowView] = []

    /* An app stays listed while it's playing, while the user has it
       attenuated, or for a grace period after it last played — "I paused
       the video, now I want it quieter" must still find its row. */
    private static let recentlyPlayedWindow: TimeInterval = 5 * 60
    private static let maxRows = 8

    init(
        engine: AudioEngine,
        onOpenSettings: @escaping () -> Void,
        makeUpdaterItem: @escaping () -> NSMenuItem
    ) {
        self.engine = engine
        self.onOpenSettings = onOpenSettings
        self.makeUpdaterItem = makeUpdaterItem
        super.init()
        engine.onChange = { [weak self] in self?.refreshRows() }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /* Rebuilt fresh on every open, so the list is always current. */
    func menuNeedsUpdate(_ menu: NSMenu) {
        engine.monitor.refreshPlaybackStates()
        menu.removeAllItems()
        rows = []

        let apps = listedApps()
        if apps.isEmpty {
            let empty = NSMenuItem(
                title: "No apps are playing audio", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for app in apps {
            let row = AppVolumeRowView(app: app, engine: engine)
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
            rows.append(row)
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(makeUpdaterItem())
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Louver", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
    }

    /* Live updates while the menu is open (playback starting/stopping). */
    private func refreshRows() {
        for row in rows {
            if let app = engine.monitor.apps[row.bundleID] {
                row.update(app: app, setting: engine.store.setting(for: row.bundleID))
            }
        }
    }

    private func listedApps() -> [AudioApp] {
        engine.monitor.apps.values
            .filter { app in
                app.isPlaying
                    || !engine.store.setting(for: app.bundleID).isPassthrough
                    || app.lastPlayedAt.map {
                        Date().timeIntervalSince($0) < Self.recentlyPlayedWindow
                    } ?? false
            }
            .sorted {
                ($0.lastPlayedAt ?? .distantPast, $0.name)
                    > ($1.lastPlayedAt ?? .distantPast, $1.name)
            }
            .prefix(Self.maxRows)
            .map { $0 }
    }

    @objc private func openSettings() {
        onOpenSettings()
    }
}

/* One app's row: icon + name + playing indicator on the first line, the
   volume slider + mute toggle on the second. */
final class AppVolumeRowView: NSView {
    let bundleID: String
    private let engine: AudioEngine

    private let nameLabel = NSTextField(labelWithString: "")
    private let playingIndicator = NSImageView()
    private let slider = NSSlider()
    private let muteButton = NSButton()

    init(app: AudioApp, engine: AudioEngine) {
        self.bundleID = app.bundleID
        self.engine = engine
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 56))

        let iconView = NSImageView(image: app.icon ?? NSImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail

        playingIndicator.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "playing")
        playingIndicator.contentTintColor = .secondaryLabelColor

        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)

        muteButton.isBordered = false
        muteButton.bezelStyle = .regularSquare
        muteButton.target = self
        muteButton.action = #selector(toggleMute)

        let topRow = NSStackView(views: [iconView, nameLabel, playingIndicator])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        let bottomRow = NSStackView(views: [slider, muteButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 6

        let stack = NSStackView(views: [topRow, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            playingIndicator.widthAnchor.constraint(equalToConstant: 14),
            slider.widthAnchor.constraint(equalToConstant: 230),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])

        update(app: app, setting: engine.store.setting(for: app.bundleID))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(app: AudioApp, setting: AppVolumeSetting) {
        nameLabel.stringValue = app.name
        playingIndicator.isHidden = !app.isPlaying
        /* Don't fight the user's drag with programmatic updates. */
        if slider.window?.currentEvent?.type != .leftMouseDragged {
            slider.doubleValue = setting.position
        }
        slider.isEnabled = !setting.muted
        muteButton.image = NSImage(
            systemSymbolName: setting.muted ? "speaker.slash.fill" : "speaker.wave.2",
            accessibilityDescription: setting.muted ? "unmute" : "mute")
        muteButton.contentTintColor = setting.muted ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func sliderMoved() {
        engine.setPosition(slider.doubleValue, for: bundleID)
    }

    @objc private func toggleMute() {
        engine.setMuted(!engine.store.setting(for: bundleID).muted, for: bundleID)
    }
}
