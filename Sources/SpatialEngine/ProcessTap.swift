// SpatialEngine/ProcessTap.swift — Core Audio process tap + its private aggregate.
//
// Captures the whole system mix (optionally MUTING the original apps so we can
// re-render it) WITHOUT becoming the system default output. AirPods therefore stay
// the default, and Apple's personalized HRTF (AUSpatialMixer property 3116) keeps
// engaging — the thing the virtual-default-loopback path fundamentally blocks.
// macOS 14.2+ (this project targets 26+).
//
// P0 hardening (see spec §9.1):
//  1. kAudioHardwarePropertyTranslatePIDToProcessObject returns noErr with
//     kAudioObjectUnknown (0) for a process that has no HAL audio client yet. Passing
//     that 0 into the exclude list makes AudioHardwareCreateProcessTap fail with
//     '!obj' (560947818) — indistinguishable from a denied TCC grant. We now (a) prime
//     the HAL so our process object exists, (b) drop an unresolved object, and
//     (c) refuse to mute when we could not exclude ourselves (muting a tap that also
//     captures our own playback = permanent silence + a feedback path).
//  2. The aggregate topology is selectable. `.tapOnly` (default) is the shape this
//     project has been running; `.anchored` additionally pins a real output device as
//     the aggregate's main sub-device, which some machines need to get non-zero
//     samples. Whichever is chosen, the other is tried as a fallback when the created
//     aggregate exposes no input channels.
//     Override with `ATMOS_TAP_AGGREGATE=anchored|tapOnly`
//     or `defaults write dev.atmoscontrol.app tapAggregate -string anchored`.
//
//     NOTE on `.anchored`: if the anchored device also has INPUT streams (AirPods have
//     a microphone), the aggregate's input may present the device's mic channels ahead
//     of the tap's channels, and pulling the mic can drag the link down to HFP/24 kHz.
//     That is exactly why it is not the default here. `aggregateInputChannels` is
//     published so the caller can see when more than the tap's 2 channels showed up.

import CoreAudio
import AudioToolbox
import Darwin
import Foundation

// MARK: - Aggregate topology

public enum TapAggregateMode: String, Sendable {
    case tapOnly
    case anchored

    /// Environment variable wins over the user default; default is `.tapOnly`.
    public static func configured() -> TapAggregateMode {
        let raw = ProcessInfo.processInfo.environment["ATMOS_TAP_AGGREGATE"]
            ?? UserDefaults.standard.string(forKey: "tapAggregate")
        switch raw?.lowercased() {
        case "anchored":          return .anchored
        case "taponly", "tap-only": return .tapOnly
        default:                  return .tapOnly
        }
    }

    var other: TapAggregateMode { self == .tapOnly ? .anchored : .tapOnly }
}

// MARK: - Errors

public enum ProcessTapError: Error, CustomStringConvertible {
    case createTapFailed(OSStatus)
    case tapUIDUnavailable
    case createAggregateFailed(OSStatus)
    case aggregateHasNoInput

    public var description: String {
        switch self {
        case .createTapFailed(let s):
            return "AudioHardwareCreateProcessTap failed (\(s) \(fourCC(s))) — needs macOS 14.2+ and the "
                 + "System Audio Recording grant (NSAudioCaptureUsageDescription)"
        case .tapUIDUnavailable:
            return "process tap UID unavailable"
        case .createAggregateFailed(let s):
            return "AudioHardwareCreateAggregateDevice failed (\(s) \(fourCC(s)))"
        case .aggregateHasNoInput:
            return "the tap aggregate exposes no input channels (tried both aggregate topologies)"
        }
    }
}

/// Render an OSStatus as its four-char code when printable, e.g. 560947818 -> "'!obj'".
func fourCC(_ s: OSStatus) -> String {
    let v = UInt32(bitPattern: s)
    let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
    return "'" + String(bytes.map { Character(UnicodeScalar($0)) }) + "'"
}

// MARK: - Silent render callback (used only to prime the HAL process object)

nonisolated(unsafe) let tapPrimeSilenceCallback: AURenderCallback = { (
    _, ioActionFlags, _, _, _, ioData
) -> OSStatus in
    if let ioData {
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        var i = 0
        while i < abl.count {
            if let p = abl[i].mData { memset(p, 0, Int(abl[i].mDataByteSize)) }
            i += 1
        }
    }
    ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}

// MARK: - ProcessTap

/// Owns one process tap + its private aggregate device. Create on the main thread;
/// the returned aggregate id is used as a normal capture device.
public final class ProcessTap {
    public private(set) var aggregateID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    /// True when our own process object was resolved and excluded from the tap.
    /// False means the tap would capture (and, if muted, silence) our own playback —
    /// in that case `start()` refuses to mute.
    public private(set) var selfExcluded = false
    /// Whether `.mutedWhenTapped` was actually applied.
    public private(set) var muteApplied = false
    /// Which aggregate topology ended up being used.
    public private(set) var aggregateMode: TapAggregateMode = .tapOnly
    /// Input channel count the created aggregate exposes (2 = just the tap, as expected).
    public private(set) var aggregateInputChannels = 0
    /// Human-readable trace of what happened during the last `start()`.
    public private(set) var diagnostics: [String] = []

    public init() {}

    public var isActive: Bool { aggregateID != AudioDeviceID(kAudioObjectUnknown) }

    /// Create the tap + its private aggregate; returns the aggregate device id to capture from.
    /// - Parameters:
    ///   - muted: silence the tapped apps at the hardware (we re-render their audio ourselves).
    ///            Downgraded to `false` automatically when we cannot exclude ourselves.
    ///   - outputDeviceID: the real sink we will render to. Used as the anchor in
    ///            `.anchored` aggregate mode and to prime the HAL process object.
    @discardableResult
    public func start(muted: Bool = true, outputDeviceID: AudioDeviceID? = nil) throws -> AudioDeviceID {
        if isActive { destroy() }
        diagnostics = []

        // ── 1. Resolve our own process object so the tap can exclude us ──────────
        var selfObj = ProcessTap.translatePID(getpid())
        if selfObj == AudioObjectID(kAudioObjectUnknown) {
            note("own process object not registered yet — priming the HAL")
            ProcessTap.primeProcessObject(outputDeviceID: outputDeviceID)
            selfObj = ProcessTap.translatePID(getpid())
        }
        selfExcluded = (selfObj != AudioObjectID(kAudioObjectUnknown))
        let excluded: [AudioObjectID] = selfExcluded ? [selfObj] : []
        if selfExcluded {
            note("self excluded from tap (process object \(selfObj))")
        } else {
            note("WARNING: could not resolve our own process object — tap will NOT be muted "
               + "(a muting global tap would silence our own playback)")
        }

        // ── 2. Create the tap ────────────────────────────────────────────────────
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()
        desc.name = "atmos-control system tap"
        desc.isPrivate = true
        // IMPORTANT: `isExclusive` is a DIRECTION flag set by this initializer
        // ("everything except the listed processes"); never touch it here.
        muteApplied = muted && selfExcluded
        desc.muteBehavior = muteApplied ? CATapMuteBehavior.mutedWhenTapped : CATapMuteBehavior.unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let ts = AudioHardwareCreateProcessTap(desc, &tap)
        guard ts == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            note("AudioHardwareCreateProcessTap failed: \(ts) \(fourCC(ts))")
            throw ProcessTapError.createTapFailed(ts)
        }
        tapID = tap
        note("tap created (object \(tap), muted=\(muteApplied))")

        // Prefer the UID we set ourselves; fall back to reading it back from the object.
        let uid = ProcessTap.tapUID(tap) ?? desc.uuid.uuidString
        guard !uid.isEmpty else { destroy(); throw ProcessTapError.tapUIDUnavailable }

        // ── 3. Aggregate device (with automatic topology fallback) ───────────────
        let preferred = TapAggregateMode.configured()
        let anchorUID = outputDeviceID.map { deviceUID($0) }.flatMap { $0.isEmpty ? nil : $0 }

        if let agg = try? buildAggregate(mode: preferred, tapUID: uid, anchorUID: anchorUID) {
            aggregateID = agg
            aggregateMode = preferred
            return agg
        }
        note("falling back to the \(preferred.other.rawValue) aggregate topology")
        do {
            let agg = try buildAggregate(mode: preferred.other, tapUID: uid, anchorUID: anchorUID)
            aggregateID = agg
            aggregateMode = preferred.other
            return agg
        } catch {
            destroy()
            throw error
        }
    }

    public func stop() { destroy() }

    // MARK: Aggregate construction

    /// Create + validate one aggregate topology. Destroys it again (and throws) when it
    /// comes up with no input channels, so the caller can try the other topology.
    private func buildAggregate(mode: TapAggregateMode, tapUID: String, anchorUID: String?) throws -> AudioDeviceID {
        let useAnchor = (mode == .anchored) && (anchorUID != nil)
        if mode == .anchored && anchorUID == nil {
            note("anchored mode requested but no output device UID available")
            throw ProcessTapError.createAggregateFailed(kAudioHardwareIllegalOperationError)
        }

        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String:         "atmos-control-tap",
            kAudioAggregateDeviceUIDKey as String:          "dev.atmoscontrol.tap." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String:    true,
            kAudioAggregateDeviceIsStackedKey as String:    false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String:               tapUID,
                kAudioSubTapDriftCompensationKey as String: true,
            ]],
        ]
        if useAnchor, let anchorUID {
            dict[kAudioAggregateDeviceMainSubDeviceKey as String]  = anchorUID
            dict[kAudioAggregateDeviceSubDeviceListKey as String]  = [[kAudioSubDeviceUIDKey as String: anchorUID]]
        } else {
            dict[kAudioAggregateDeviceSubDeviceListKey as String]  = []
        }

        var agg = AudioDeviceID(kAudioObjectUnknown)
        let st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard st == noErr, agg != AudioDeviceID(kAudioObjectUnknown) else {
            note("aggregate (\(mode.rawValue)) creation failed: \(st) \(fourCC(st))")
            throw ProcessTapError.createAggregateFailed(st)
        }

        let inputs = deviceChannelCount(agg, scope: kAudioObjectPropertyScopeInput)
        aggregateInputChannels = inputs
        note("aggregate (\(mode.rawValue)) created: device \(agg), \(inputs) input channel(s)")
        guard inputs >= 2 else {
            note("aggregate (\(mode.rawValue)) has no usable input — discarding it")
            AudioHardwareDestroyAggregateDevice(agg)
            aggregateInputChannels = 0
            throw ProcessTapError.aggregateHasNoInput
        }
        if inputs > 2 {
            note("WARNING: aggregate input has \(inputs) channels; the tap is expected to be the "
               + "first 2. An anchored device with a microphone can shift the tap's channels.")
        }
        return agg
    }

    private func destroy() {
        if aggregateID != AudioDeviceID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        aggregateInputChannels = 0
        muteApplied = false
    }

    private func note(_ s: String) {
        diagnostics.append(s)
        selog("  tap: \(s)")
    }

    // MARK: helpers

    private static func translatePID(_ pid: pid_t) -> AudioObjectID {
        var p = pid
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var obj = AudioObjectID(kAudioObjectUnknown)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &p, &sz, &obj)
        // noErr + kAudioObjectUnknown is a real, documented outcome: the process has no
        // HAL audio client yet. Report it as "unknown" rather than passing 0 around.
        return st == noErr ? obj : AudioObjectID(kAudioObjectUnknown)
    }

    /// Give the HAL a reason to create a process object for us: run a silent output IO
    /// for a moment, polling until the translation succeeds (max ~500 ms).
    private static func primeProcessObject(outputDeviceID: AudioDeviceID?) {
        let dev = outputDeviceID ?? defaultOutputDeviceID()
        guard dev != AudioDeviceID(kAudioObjectUnknown), let unit = makeHALOutputUnit() else { return }
        defer { AudioComponentInstanceDispose(unit) }

        setEnableIO(unit, enable: 1, scope: kAudioUnitScope_Output, element: 0, label: "prime")
        setEnableIO(unit, enable: 0, scope: kAudioUnitScope_Input,  element: 1, label: "prime")
        setCurrentDevice(unit, deviceID: dev, label: "prime")
        var fmt = stereoFloat32Format(sampleRate: deviceNominalSampleRate(dev) ?? 48_000)
        _ = setStreamFormat(unit, fmt: &fmt, scope: kAudioUnitScope_Input, element: 0, label: "prime")

        var cb = AURenderCallbackStruct(inputProc: tapPrimeSilenceCallback, inputProcRefCon: nil)
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                             &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        guard AudioUnitInitialize(unit) == noErr else { return }
        defer { AudioUnitUninitialize(unit) }
        guard AudioOutputUnitStart(unit) == noErr else { return }
        defer { AudioOutputUnitStop(unit) }

        var waitedMS = 0
        while waitedMS < 500 {
            if translatePID(getpid()) != AudioObjectID(kAudioObjectUnknown) { return }
            usleep(25_000)
            waitedMS += 25
        }
    }

    private static func tapUID(_ id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>? = nil
        var sz = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &cf) == noErr, let s = cf else { return nil }
        return s.takeRetainedValue() as String
    }
}
