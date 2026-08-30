import Foundation

/* What the user set for one app. `position` is the slider position (0…1),
   not the gain — the cubic curve maps between them. */
struct AppVolumeSetting: Codable, Equatable {
    var position: Double = 1
    var muted: Bool = false

    /* Full volume and unmuted — the state that needs no tap at all. */
    var isPassthrough: Bool { position >= 1 && !muted }
}

/* Slider position → linear gain. Cubic: perceived loudness is roughly
   logarithmic, and a linear-gain slider crams all audible change into the
   bottom fifth of its travel. Cubic spreads it out the way hardware volume
   controls (and macOS's own) do. */
enum VolumeCurve {
    static func gain(at position: Double) -> Float {
        let clamped = min(max(position, 0), 1)
        return Float(clamped * clamped * clamped)
    }
}

/* Per-app volume settings, persisted as one JSON dictionary in
   UserDefaults keyed by bundle ID. Passthrough entries are dropped, so the
   stored dictionary only ever contains apps the user actually attenuated. */
final class VolumeStore {
    private static let key = "volumes"
    private var settings: [String: AppVolumeSetting]

    init() {
        settings =
            UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: AppVolumeSetting].self, from: $0) }
            ?? [:]
    }

    func setting(for bundleID: String) -> AppVolumeSetting {
        settings[bundleID] ?? AppVolumeSetting()
    }

    var attenuatedBundleIDs: [String] { Array(settings.keys) }

    func set(_ setting: AppVolumeSetting, for bundleID: String) {
        if setting.isPassthrough {
            settings.removeValue(forKey: bundleID)
        } else {
            settings[bundleID] = setting
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.key)
    }
}
