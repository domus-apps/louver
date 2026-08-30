import AppKit
import CoreAudio

/* One user-facing app that is (or recently was) producing audio — possibly
   backed by several HAL client processes (Chrome-style helpers). */
struct AudioApp {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var processObjectIDs: [AudioObjectID]
    var isPlaying: Bool
    var lastPlayedAt: Date?
}

/* Watches the HAL's client-process list and groups processes into apps.
   All state and callbacks live on the main thread. */
final class AudioProcessMonitor {
    /* Fired on any change: processes appearing/dying, playback starting or
       stopping. The engine reconciles controllers; the menu refreshes. */
    var onChange: (() -> Void)?

    private(set) var apps: [String: AudioApp] = [:]

    private var processListListener: AudioPropertyListener?
    private var runningOutputListeners: [AudioObjectID: AudioPropertyListener] = [:]
    /* lastPlayedAt survives rebuilds (a paused app should stay in the menu
       for a while), keyed by bundle ID. */
    private var lastPlayed: [String: Date] = [:]

    func start() {
        processListListener = AudioPropertyListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        ) { [weak self] in
            self?.rebuild()
        }
        rebuild()
    }

    /* Re-derives the whole app map from the HAL. Cheap (tens of processes)
       and self-healing, so incremental bookkeeping isn't worth its bugs. */
    private func rebuild() {
        let processObjects = CoreAudioProperty.getArray(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
            of: AudioObjectID.self)

        var next: [String: AudioApp] = [:]
        var seenObjects: Set<AudioObjectID> = []

        for object in processObjects {
            let pid = CoreAudioProperty.getValue(
                object, kAudioProcessPropertyPID, default: pid_t(-1))
            guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
                let owner = Self.owningApplication(of: pid)
            else { continue }

            seenObjects.insert(object)
            let playing =
                CoreAudioProperty.getValue(
                    object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0

            if var app = next[owner.bundleID] {
                app.processObjectIDs.append(object)
                app.isPlaying = app.isPlaying || playing
                next[owner.bundleID] = app
            } else {
                next[owner.bundleID] = AudioApp(
                    bundleID: owner.bundleID,
                    name: owner.name,
                    icon: owner.icon,
                    processObjectIDs: [object],
                    isPlaying: playing,
                    lastPlayedAt: lastPlayed[owner.bundleID])
            }

            if runningOutputListeners[object] == nil {
                /* Fully wildcarded on purpose: the HAL does NOT deliver
                   process-object notifications to a listener registered for
                   (IsRunningOutput, global, main) — nor for that selector
                   under wildcard scope/element. Only a wildcard-selector
                   registration receives them (verified empirically). The
                   handler just re-reads playback states, so over-delivery
                   is harmless. */
                runningOutputListeners[object] = AudioPropertyListener(
                    object: object, selector: kAudioObjectPropertySelectorWildcard,
                    scope: kAudioObjectPropertyScopeWildcard,
                    element: kAudioObjectPropertyElementWildcard
                ) { [weak self] in
                    self?.playbackStateChanged()
                }
            }
        }

        runningOutputListeners = runningOutputListeners.filter { seenObjects.contains($0.key) }
        for (bundleID, app) in next where app.isPlaying {
            lastPlayed[bundleID] = Date()
            next[bundleID]?.lastPlayedAt = lastPlayed[bundleID]
        }
        apps = next
        onChange?()
    }

    /* Re-reads every process's playback flag. Also called when the menu
       opens, as insurance against a missed notification. */
    func refreshPlaybackStates() {
        playbackStateChanged()
    }

    private func playbackStateChanged() {
        for (bundleID, var app) in apps {
            let playing = app.processObjectIDs.contains { object in
                CoreAudioProperty.getValue(
                    object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            }
            if playing || app.isPlaying {
                /* Stamp while playing and on the falling edge, so "recently
                   played" starts counting from when the audio stopped. */
                lastPlayed[bundleID] = Date()
                app.lastPlayedAt = lastPlayed[bundleID]
            }
            app.isPlaying = playing
            apps[bundleID] = app
        }
        onChange?()
    }

    // MARK: - Process → app grouping

    private struct Owner {
        let bundleID: String
        let name: String
        let icon: NSImage?
    }

    /* Resolves a HAL client PID to the app the user would recognize:
       ① the PID itself, if it's a visible app (Music, Safari, VLC);
       ② the nearest visible-app ancestor (Chrome/Electron helpers are
         children of their main app) via the public sysctl parent chain;
       ③ nothing — system daemons and bare CLI players stay out of the menu. */
    private static func owningApplication(of pid: pid_t) -> Owner? {
        var current = pid
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: current),
                app.activationPolicy != .prohibited,
                let bundleID = app.bundleIdentifier
            {
                return Owner(
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    icon: app.icon)
            }
            let parent = parentPID(of: current)
            guard parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}
