import AppKit
import Combine
import SwiftUI

/* The status-item menu: everything lives here — one native slider row per
   audio app, then the housekeeping items. A real NSMenu, so the chrome is
   the system's own; view-backed items receive full mouse events during
   tracking, so the sliders work in place. Known trade-off vs the system's
   Sound control (which is a private panel, not a menu): a knob drag that
   ends outside the menu also ends the tracking session. */
final class VolumeMenu: NSObject, NSMenuDelegate {
    private let engine: AudioEngine
    private let onOpenSettings: () -> Void
    private let makeUpdaterItem: () -> NSMenuItem
    /* The rows of the current tracking session, for live updates. */
    private var rowModels: [String: VolumeRowModel] = [:]

    /* An app stays listed while it's playing, while the user has it
       attenuated, or for a grace period after it last played — "I paused
       the video, now I want it quieter" must still find its row. */
    private static let recentlyPlayedWindow: TimeInterval = 5 * 60
    private static let maxRows = 8
    private static let rowWidth: CGFloat = 300

    init(
        engine: AudioEngine,
        onOpenSettings: @escaping () -> Void,
        makeUpdaterItem: @escaping () -> NSMenuItem
    ) {
        self.engine = engine
        self.onOpenSettings = onOpenSettings
        self.makeUpdaterItem = makeUpdaterItem
        super.init()
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
        rowModels = [:]

        let apps = listedApps()
        if apps.isEmpty {
            let empty = NSMenuItem(
                title: "No apps are playing audio", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for app in apps {
            let model = makeRow(for: app)
            rowModels[app.bundleID] = model

            let item = NSMenuItem()
            item.view = AppVolumeRowView(model: model, width: Self.rowWidth)
            menu.addItem(item)
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
    func refreshRows() {
        for (bundleID, model) in rowModels {
            guard let app = engine.monitor.apps[bundleID] else { continue }
            let setting = engine.store.setting(for: bundleID)
            model.name = app.name
            model.isPlaying = app.isPlaying
            /* Don't fight the user's drag with programmatic updates. */
            if !model.isDragging {
                model.position = setting.position
            }
            model.muted = setting.muted
        }
    }

    private func makeRow(for app: AudioApp) -> VolumeRowModel {
        let setting = engine.store.setting(for: app.bundleID)
        let row = VolumeRowModel(
            id: app.bundleID, name: app.name, icon: app.icon,
            position: setting.position, muted: setting.muted, isPlaying: app.isPlaying)
        row.onPosition = { [weak self, weak row] position in
            row?.position = position
            self?.engine.setPosition(position, for: app.bundleID)
        }
        row.onToggleMute = { [weak self] in
            guard let self else { return }
            self.engine.setMuted(
                !self.engine.store.setting(for: app.bundleID).muted, for: app.bundleID)
        }
        return row
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

// MARK: - Row model

/* The state one slider row shows, bridged to SwiftUI. External engine
   updates land here; user edits flow back through the callbacks. */
final class VolumeRowModel: ObservableObject, Identifiable {
    let id: String
    let icon: NSImage?
    @Published var name: String
    @Published var position: Double
    @Published var muted: Bool
    @Published var isPlaying: Bool
    var isDragging = false {
        didSet {
            if isDragging != oldValue {
                onDraggingChanged?(isDragging)
            }
        }
    }
    var onPosition: ((Double) -> Void)?
    var onToggleMute: (() -> Void)?
    var onDraggingChanged: ((Bool) -> Void)?

    init(
        id: String, name: String, icon: NSImage?,
        position: Double, muted: Bool, isPlaying: Bool
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.position = position
        self.muted = muted
        self.isPlaying = isPlaying
    }
}

// MARK: - Row view

/* The flanking speakers' tint. Not `labelColor.withAlphaComponent(_:)`:
   that resolves the dynamic label color against the appearance current at
   the call and returns a *static* color, so rows built under one
   appearance came out black-on-black once the system switched to dark
   (or vice versa). A dynamic provider re-resolves at draw time. */
private let speakerTint = NSColor(name: nil) { appearance in
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.65)
}

/* One app's row: icon + name + playing indicator over the native volume
   slider, with the system's flanking speakers (the quiet one doubles as
   the mute toggle). AppKit layout so the slider strip's exact frame is
   known to the drag-capturing host below. */
private final class AppVolumeRowView: NSView {
    private let model: VolumeRowModel
    private let nameLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton()

    init(model: VolumeRowModel, width: CGFloat) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 56))

        let iconView = NSImageView(image: model.icon ?? NSImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail

        muteButton.isBordered = false
        muteButton.bezelStyle = .regularSquare
        muteButton.target = self
        muteButton.action = #selector(toggleMute)

        let loudSpeaker = NSImageView()
        loudSpeaker.image = NSImage(
            systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        loudSpeaker.contentTintColor = speakerTint

        /* Plain hosting: the slider receives its events through normal
           dispatch (pressed-knob glass and all); LouverApplication's
           sendEvent reroute is what protects the menu from a drag ending
           outside it. */
        let sliderHost = NSHostingView(rootView: CapturedSlider(model: model))
        model.onDraggingChanged = { [weak sliderHost] dragging in
            LouverApplication.sliderDragTarget = dragging ? sliderHost : nil
        }

        let topRow = NSStackView(views: [iconView, nameLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        let bottomRow = NSStackView(views: [muteButton, sliderHost, loudSpeaker])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.alignment = .centerY
        /* Stretch the slider to whatever width the fixed speakers leave —
           without .fill the stack keeps it at its (small) intrinsic size. */
        bottomRow.distribution = .fill
        sliderHost.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let stack = NSStackView(views: [topRow, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            muteButton.widthAnchor.constraint(equalToConstant: 19),
            muteButton.heightAnchor.constraint(equalToConstant: 18),
            sliderHost.heightAnchor.constraint(equalToConstant: 22),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            /* Tighter than the top: the separator below carries its own
               spacing, and 7pt + that read as a hole under the slider. */
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])

        apply()
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.apply() }
        }
    }

    private var observation: AnyCancellable?

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func apply() {
        nameLabel.stringValue = model.name
        muteButton.image = NSImage(
            systemSymbolName: model.muted ? "speaker.slash.fill" : "speaker.fill",
            accessibilityDescription: model.muted ? "unmute" : "mute"
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        muteButton.contentTintColor =
            model.muted ? .controlAccentColor : speakerTint
    }

    @objc private func toggleMute() {
        model.onToggleMute?()
    }
}

private struct CapturedSlider: View {
    @ObservedObject var model: VolumeRowModel

    var body: some View {
        Slider(
            value: Binding(
                get: { model.position },
                set: { model.onPosition?($0) }),
            in: 0...1,
            onEditingChanged: { editing in
                model.isDragging = editing
            }
        )
        .controlSize(.regular)
        /* controlAccentColor IS the system slider's fill — it follows
           the accent the user picked in System Settings, so the track
           always matches the Sound menu's exactly. */
        .tint(
            model.muted
                ? Color(nsColor: .systemGray) : Color(nsColor: .controlAccentColor))
        /* A menu's window is never key, so controls in menu item views
           render in their inactive (gray) state by default — force the
           active appearance the Sound menu shows. */
        .environment(\.appearsActive, true)
    }
}
