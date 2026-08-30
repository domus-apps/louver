import CoreAudio
import Foundation

/* The coordinator. Main thread only. Enforces one invariant: a controller
   exists for an app ⇔ the user attenuated it (volume < 100% or muted) AND
   it has live audio processes. Everything else — passthrough apps, quit
   apps — has no runtime objects at all. */
final class AudioEngine {
    let monitor = AudioProcessMonitor()
    let store = VolumeStore()

    /* UI refresh hook (menu rows, status icon). */
    var onChange: (() -> Void)?
    /* Tap creation failed where it previously worked — almost certainly the
       System Audio Recording permission. The engine has already failed
       AUDIBLE (all controllers torn down, apps back at full volume). */
    var onPermissionFailure: (() -> Void)?

    private(set) var controllers: [String: AppVolumeController] = [:]
    private var defaultDeviceListener: AudioPropertyListener?
    private var sampleRateListener: AudioPropertyListener?
    private var watchedOutputDevice = AudioObjectID(kAudioObjectUnknown)

    /* Apps the user adjusted in THIS session. Once a controller exists it
       stays for the app's lifetime, even back at 100%: the direct-route ↔
       tap-route switch is an audible seam (the two paths have different
       latencies, and no mute mode hides the waveform jump), so it may only
       happen once — on the first touch — and never on slider moves. A
       lingering controller at gain 1.0 is audibly identical to passthrough
       and costs ~0 CPU. Settings persist passthrough as "no entry", so the
       next launch starts clean. */
    private var touchedThisSession: Set<String> = []

    /* For the status icon: a touched-but-back-at-100% controller doesn't
       count as attenuation. */
    var isAttenuatingAnything: Bool {
        controllers.keys.contains { !store.setting(for: $0).isPassthrough }
    }

    func start() {
        monitor.onChange = { [weak self] in
            self?.reconcileAll()
            self?.onChange?()
        }
        defaultDeviceListener = AudioPropertyListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] in
            self?.outputDeviceChanged()
        }
        watchOutputSampleRate()
        monitor.start()
    }

    // MARK: - User actions

    func setPosition(_ position: Double, for bundleID: String) {
        var setting = store.setting(for: bundleID)
        setting.position = position
        store.set(setting, for: bundleID)
        touchedThisSession.insert(bundleID)
        controllers[bundleID]?.setGain(VolumeCurve.gain(at: position))
        reconcile(bundleID)
        onChange?()
    }

    func setMuted(_ muted: Bool, for bundleID: String) {
        var setting = store.setting(for: bundleID)
        setting.muted = muted
        store.set(setting, for: bundleID)
        touchedThisSession.insert(bundleID)
        controllers[bundleID]?.setMuted(muted)
        reconcile(bundleID)
        onChange?()
    }

    // MARK: - Reconciliation

    private func reconcileAll() {
        for bundleID in Set(store.attenuatedBundleIDs).union(controllers.keys) {
            reconcile(bundleID)
        }
    }

    private func reconcile(_ bundleID: String) {
        let setting = store.setting(for: bundleID)
        let processes = monitor.apps[bundleID]?.processObjectIDs ?? []
        let wantsController =
            !processes.isEmpty
            && (!setting.isPassthrough || touchedThisSession.contains(bundleID))

        if let controller = controllers[bundleID] {
            if processes.isEmpty {
                /* The app quit — nothing is audible, tear down now. */
                controllers.removeValue(forKey: bundleID)?.teardown()
            } else if controller.processObjectIDs != processes {
                /* Membership changed (a helper appeared or died): recreate.
                   The gap is silence for this one app — the right failure
                   direction, and only on rare process churn. */
                controllers.removeValue(forKey: bundleID)?.teardown()
                createController(for: bundleID, setting: setting, processes: processes)
            }
        } else if wantsController {
            createController(for: bundleID, setting: setting, processes: processes)
        }
    }

    private func createController(
        for bundleID: String, setting: AppVolumeSetting, processes: [AudioObjectID]
    ) {
        guard let outputUID = CoreAudioProperty.defaultOutputDeviceUID else { return }
        do {
            controllers[bundleID] = try AppVolumeController(
                bundleID: bundleID,
                processObjectIDs: processes,
                outputDeviceUID: outputUID,
                gain: VolumeCurve.gain(at: setting.position),
                muted: setting.muted)
        } catch AudioControlError.tapCreationFailed(let status) {
            /* Permission trouble: fail audible — every app back to normal
               passthrough is better than silently muted forever. */
            NSLog("Louver: tap creation for \(bundleID) failed (\(status)); releasing all taps")
            for (_, controller) in controllers { controller.teardown() }
            controllers.removeAll()
            onPermissionFailure?()
        } catch {
            NSLog("Louver: controller for \(bundleID) failed: \(error)")
        }
    }

    // MARK: - Output device changes

    private func outputDeviceChanged() {
        watchOutputSampleRate()
        guard let outputUID = CoreAudioProperty.defaultOutputDeviceUID else { return }
        for (bundleID, controller) in controllers {
            do {
                try controller.rebuild(outputDeviceUID: outputUID)
            } catch {
                /* Device vanished mid-swap; drop to passthrough for this app
                   and let the next change (or user action) recreate it. */
                NSLog("Louver: rebuild for \(bundleID) failed: \(error)")
                controllers.removeValue(forKey: bundleID)?.teardown()
            }
        }
        onChange?()
    }

    /* A sample-rate change on the current output device needs the same
       rebuild as a device swap. */
    private func watchOutputSampleRate() {
        let device = CoreAudioProperty.defaultOutputDeviceID
        guard device != watchedOutputDevice else { return }
        watchedOutputDevice = device
        sampleRateListener =
            device == kAudioObjectUnknown
            ? nil
            : AudioPropertyListener(
                object: device, selector: kAudioDevicePropertyNominalSampleRate
            ) { [weak self] in
                self?.outputDeviceChanged()
            }
    }
}
