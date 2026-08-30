import CoreAudio
import Foundation
import Synchronization

enum AudioControlError: Error {
    case tapCreationFailed(OSStatus)
    case noOutputDevice
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case startFailed(OSStatus)
}

/* Everything one attenuated app needs: a muted process tap (the HAL stops
   sending the app's audio to hardware), a private aggregate device pairing
   that tap with the real output device, and an IOProc that copies tap input
   to the output with a gain. One instance per controlled app — complete
   lifecycle isolation, and apps at passthrough have no instance at all.

   Mutation happens on the main thread; the IOProc (the only realtime code
   in Louver) reads the gain and mute through atomics. Membership changes
   (a helper process appearing) recreate the whole controller — rare, and
   the brief gap is silence, never full volume. */
final class AppVolumeController {
    let bundleID: String
    let processObjectIDs: [AudioObjectID]

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private let tapUUID: UUID
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /* The atomics live in a reference-type box: Atomic is noncopyable, and
       the IOProc block needs to capture something copyable that outlives
       every callback. Float has no atomic conformance; store its bits. */
    private final class ControlState: @unchecked Sendable {
        let gainBits: Atomic<UInt32>
        let muted: Atomic<Bool>

        init(gain: Float, muted: Bool) {
            self.gainBits = Atomic(gain.bitPattern)
            self.muted = Atomic(muted)
        }
    }

    private let state: ControlState

    init(
        bundleID: String, processObjectIDs: [AudioObjectID],
        outputDeviceUID: String, gain: Float, muted: Bool
    ) throws {
        self.bundleID = bundleID
        self.processObjectIDs = processObjectIDs
        self.state = ControlState(gain: gain, muted: muted)

        /* ① The tap: private, fixed stereo mixdown so the IOProc's input
           format never depends on where the app renders. mutedWhenTapped
           (not muted): the HAL silences the app's direct route only while
           our IOProc is actually reading the tap, so the handoff at
           creation and teardown is synchronized — a hard .muted opened an
           audible gap between tap creation and the first IOProc callback. */
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "Louver tap — \(bundleID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        description.isProcessRestoreEnabled = false
        tapUUID = description.uuid

        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else {
            throw AudioControlError.tapCreationFailed(tapStatus)
        }

        do {
            try buildAggregate(outputDeviceUID: outputDeviceUID)
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    deinit {
        teardown()
    }

    func setGain(_ gain: Float) {
        state.gainBits.store(gain.bitPattern, ordering: .relaxed)
    }

    func setMuted(_ isMuted: Bool) {
        state.muted.store(isMuted, ordering: .relaxed)
    }

    /* The default output device changed (or its sample rate did): recreate
       the aggregate + IOProc against the new device. The tap stays alive, so
       the app remains silent — never full-blast — during the gap. */
    func rebuild(outputDeviceUID: String) throws {
        tearDownAggregate()
        try buildAggregate(outputDeviceUID: outputDeviceUID)
    }

    func teardown() {
        tearDownAggregate()
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Aggregate + IOProc

    private func buildAggregate(outputDeviceUID: String) throws {
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Louver — \(bundleID)",
            kAudioAggregateDeviceUIDKey: "com.jhaemin.louver.\(tapUUID.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            /* Private: never appears in Sound settings or other apps. */
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else {
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            throw AudioControlError.aggregateCreationFailed(aggregateStatus)
        }

        let state = self.state
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            _, inputData, _, outputData, _ in
            let inBuffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            let outBuffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard let inBuffer = inBuffers.first(where: { $0.mData != nil }),
                let inData = inBuffer.mData?.assumingMemoryBound(to: Float.self)
            else { return }

            /* Output buffers arrive silent; leaving them untouched IS mute. */
            guard !state.muted.load(ordering: .relaxed) else { return }
            let gain = Float(bitPattern: state.gainBits.load(ordering: .relaxed))

            let inChannels = Int(inBuffer.mNumberChannels)
            let inFrames = Int(inBuffer.mDataByteSize) / (4 * max(inChannels, 1))
            for outBuffer in outBuffers {
                guard let outData = outBuffer.mData?.assumingMemoryBound(to: Float.self)
                else { continue }
                let outChannels = Int(outBuffer.mNumberChannels)
                let outFrames = Int(outBuffer.mDataByteSize) / (4 * max(outChannels, 1))
                let frames = min(inFrames, outFrames)
                for frame in 0..<frames {
                    for channel in 0..<outChannels {
                        /* Stereo tap → N-channel out: L/R first, duplicate
                           into any extra channels. */
                        let inChannel = min(channel, inChannels - 1)
                        outData[frame * outChannels + channel] =
                            inData[frame * inChannels + inChannel] * gain
                    }
                }
            }
        }
        guard ioStatus == noErr, ioProcID != nil else {
            tearDownAggregate()
            throw AudioControlError.ioProcCreationFailed(ioStatus)
        }

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            tearDownAggregate()
            throw AudioControlError.startFailed(startStatus)
        }
    }

    private func tearDownAggregate() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
