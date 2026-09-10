import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = AudioEngine()
    private let updater = UpdaterController()
    private var volumeMenu: VolumeMenu?
    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?

    private static let onboardingCompletedKey = "onboarding.completed"

    func applicationDidFinishLaunching(_ notification: Notification) {
        /* A translocated launch relaunches itself from the real bundle —
           nothing else must start in this doomed instance. */
        if TranslocationHealer.healIfNeeded() { return }

        volumeMenu = VolumeMenu(
            engine: engine,
            onOpenSettings: { [weak self] in self?.openSettings() },
            makeUpdaterItem: { [weak self] in
                self?.updater.makeMenuItem() ?? NSMenuItem()
            })

        setUpMainMenu()
        observePreferenceChanges()
        updateStatusItemVisibility()

        engine.start()
        /* The permission was lost mid-run (the engine has already failed
           audible); bring the onboarding gate back. */
        engine.onPermissionFailure = { [weak self] in
            self?.showOnboarding()
        }
        engine.onChange = { [weak self] in
            self?.volumeMenu?.refreshRows()
            self?.updateStatusIcon()
        }

        /* Completion is only recorded when onboarding is finished properly,
           so an interrupted (or force-quit) run shows it again. */
        if !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
            || CommandLine.arguments.contains("--onboarding")
        {
            showOnboarding()
        }
        if CommandLine.arguments.contains("--settings") {
            openSettings()
        }
    }

    private func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
                self?.onboardingController = nil
            }
            observeClose(of: onboardingController?.window)
        }
        comeForward()
        onboardingController?.window?.makeKeyAndOrderFront(nil)
    }

    /* Launching the app again while it's already running sends "reopen" to
       the live instance. With the menu bar icon hidden this is the only way
       back into the UI, so surface Settings (which also puts the app in the
       Dock via updateActivationPolicy). */
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if AppPreferences.isMenuBarIconHidden {
            openSettings()
        }
        return false
    }

    // MARK: - Status item

    private func updateStatusItemVisibility() {
        if AppPreferences.isMenuBarIconHidden {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
        } else if statusItem == nil {
            setUpStatusItem()
        }
        updateActivationPolicy()
    }

    private func setUpStatusItem() {
        /* A fixed length instead of squareLength: square items are as wide
           as the menu bar is tall, which pads a ~18pt symbol with a lot of
           dead space. 20pt hugs the icon while keeping its natural size. */
        let item = NSStatusBar.system.statusItem(withLength: 20)
        /* The menu IS the app (sliders live in it), so both mouse buttons
           open it — a permanently assigned menu does exactly that. */
        item.menu = volumeMenu?.makeMenu()
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let attenuating = engine.isAttenuatingAnything
        statusItem?.button?.image = NSImage(
            systemSymbolName: attenuating ? "speaker.wave.1.fill" : "speaker.wave.2",
            accessibilityDescription: attenuating
                ? L("Louver — adjusting app volumes") : "Louver")
    }

    // MARK: - Menus & windows

    /* An accessory app has no visible menu bar, but ⌘-key equivalents are
       still dispatched through the main menu — without one, ⌘W/⌘Q do
       nothing in the settings window. The menu also becomes visible for
       real whenever the app temporarily joins the Dock (regular policy). */
    private func setUpMainMenu() {
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: L("Settings…"), action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(updater.makeMenuItem())
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: L("Quit Louver"),
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(
            NSMenuItem(
                title: L("Close Window"),
                action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(
            NSMenuItem(
                title: L("Minimize"),
                action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))

        let mainMenu = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    private func observePreferenceChanges() {
        NotificationCenter.default.addObserver(
            forName: AppPreferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateStatusItemVisibility()
        }
    }

    private var isSettingsWindowVisible: Bool {
        settingsWindowController?.window?.isVisible == true
    }

    /* Activation hand-back. An accessory app that activates itself to show
       a window stays the active app after that window closes — macOS never
       moves activation on window close — so a windowless Louver would be left
       frontmost until the user clicked elsewhere. Anything keyed off the
       frontmost app then misbehaves (Atrium's Option+` lists the front app's
       windows and finds none; plain keys beep). Remember who was active
       before we came forward and give activation back once our last window
       is gone. */
    private var previouslyActiveApp: NSRunningApplication?

    private func comeForward() {
        if !NSApp.isActive,
            let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            previouslyActiveApp = front
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handBackActivationIfWindowless() {
        guard NSApp.isActive, settingsWindowController?.window?.isVisible != true,
            onboardingController?.window?.isVisible != true
        else { return }
        let previous = previouslyActiveApp
        previouslyActiveApp = nil
        if let previous, !previous.isTerminated,
            previous.activate(from: .current, options: [])
        {
            return
        }
        /* No one to hand back to (quit meanwhile): hiding yields activation
           to whatever the system picks next. */
        NSApp.hide(nil)
    }

    private func observeClose(of window: NSWindow?) {
        guard let window else { return }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            /* isVisible is still true inside willClose; re-evaluate (leave the Dock, hand
               activation back) on the next runloop cycle. */
            DispatchQueue.main.async {
                self?.updateActivationPolicy()
                self?.handBackActivationIfWindowless()
            }
        }
    }

    /* Dock presence: the app normally stays invisible (accessory policy),
       but while the menu bar icon is hidden AND Settings is open there would
       be no sign the app is running — so it joins the Dock for the duration
       and leaves again when the settings window closes. */
    private func updateActivationPolicy() {
        let wantsDock = AppPreferences.isMenuBarIconHidden && isSettingsWindowVisible
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        /* Flipping the policy can drop activation; keep Settings in front. */
        if isSettingsWindowVisible {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(updater: updater)
            observeClose(of: settingsWindowController?.window)
        }
        /* Accessory apps don't come forward on their own — activate first or
           the window opens behind the current app. */
        comeForward()
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
    }
}
