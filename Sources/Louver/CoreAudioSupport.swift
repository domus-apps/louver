import CoreAudio
import Foundation

/* Thin typed wrappers over the AudioObject property C API. Everything the
   engine reads or watches goes through here so the call sites stay legible. */
enum CoreAudioProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /* POD arrays only (AudioObjectID and friends) — never CF/ObjC types. */
    static func getArray<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, of _: T.Type
    ) -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        var value = [T](unsafeUninitializedCapacity: count) { _, initialized in
            initialized = count
        }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return [] }
        return value
    }

    /* POD values only. */
    static func getValue<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default fallback: T
    ) -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.stride)
        var value = fallback
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return fallback }
        return value
    }

    static func getString(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.stride)
        var value: CFString?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value as String?
    }

    static var defaultOutputDeviceID: AudioObjectID {
        getValue(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
            default: AudioObjectID(kAudioObjectUnknown))
    }

    static var defaultOutputDeviceUID: String? {
        let device = defaultOutputDeviceID
        guard device != kAudioObjectUnknown else { return nil }
        return getString(device, kAudioDevicePropertyDeviceUID)
    }
}

/* A property listener that removes itself when released, so owners can hold
   listeners as plain stored properties and let deinit clean up. */
final class AudioPropertyListener {
    private let object: AudioObjectID
    private var addr: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(
        object: AudioObjectID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        queue: DispatchQueue = .main, handler: @escaping () -> Void
    ) {
        self.object = object
        self.addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: element)
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr
        else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &addr, .main, block)
    }
}
