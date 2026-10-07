// SpatialEngine/Devices.swift — CoreAudio device enumeration + default-output
// routing (no entitlement required).

import CoreAudio

let kAtmosControlUID = "atmos-control:loopback:0"

func allDeviceIDs() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
          dataSize > 0 else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr
        else { return [] }
    return ids
}

func deviceUID(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cfStr: Unmanaged<CFString>? = nil
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &dataSize, &cfStr) == noErr, let s = cfStr else { return "" }
    return s.takeRetainedValue() as String
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cfStr: Unmanaged<CFString>? = nil
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &dataSize, &cfStr) == noErr, let s = cfStr else { return "" }
    return s.takeRetainedValue() as String
}

func deviceHasChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
    deviceChannelCount(id, scope: scope) > 0
}

/// Total channel count across all streams on `scope` (0 = none / unreadable). Used to tell
/// the 12-channel surround loopback driver apart from the legacy stereo one.
func deviceChannelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    var sz = dataSize
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
    var total = 0
    for buf in abl { total += Int(buf.mNumberChannels) }
    return total
}

func findAtmosControlDevice() -> AudioDeviceID? {
    for id in allDeviceIDs() where deviceUID(id) == kAtmosControlUID { return id }
    for id in allDeviceIDs() where deviceName(id).lowercased().contains("atmos-control") { return id }
    return nil
}

/// BlackHole 16ch (Existential Audio) loopback, usable as an alternative
/// multichannel capture device for the 7.1.4 path (Issue #1 §4).
/// Advantage over the bundled HAL driver: SIP can remain enabled.
/// Channel mapping: 1–12 = canonical 7.1.4 (FL FR C LFE SL SR RL RR TFL TFR TRL TRR),
/// 13–16 unused/reserved.
func findBlackHole16chDevice() -> AudioDeviceID? {
    for id in allDeviceIDs() {
        let name = deviceName(id).lowercased()
        guard name.contains("blackhole") else { continue }
        let chans = max(deviceChannelCount(id, scope: kAudioObjectPropertyScopeOutput),
                        deviceChannelCount(id, scope: kAudioObjectPropertyScopeInput))
        if chans >= 12 { return id }
    }
    return nil
}

/// Which device backs the surround (7.1.4) loopback capture.
/// Prefers the bundled atmos-control driver (exact 12ch) when present,
/// falls back to BlackHole 16ch (first 12ch used, 13–16 ignored).
func findSurroundCaptureDevice() -> AudioDeviceID? {
    if let atmos = findAtmosControlDevice() {
        let chans = max(deviceChannelCount(atmos, scope: kAudioObjectPropertyScopeOutput),
                        deviceChannelCount(atmos, scope: kAudioObjectPropertyScopeInput))
        if chans >= 12 { return atmos }
        // Legacy stereo atmos driver present but not surround-capable: still
        // allow BlackHole to back the surround path.
        if findBlackHole16chDevice() != nil { return findBlackHole16chDevice() }
        return nil
    }
    return findBlackHole16chDevice()
}

/// Channel width of the surround capture device (0 = none installed).
func surroundCaptureChannelCount() -> Int {
    guard let dev = findSurroundCaptureDevice() else { return 0 }
    return max(deviceChannelCount(dev, scope: kAudioObjectPropertyScopeOutput),
               deviceChannelCount(dev, scope: kAudioObjectPropertyScopeInput))
}

/// Human-readable name of the active surround capture device ("—" when none).
func surroundCaptureDeviceName() -> String {
    guard let dev = findSurroundCaptureDevice() else { return "—" }
    return deviceName(dev)
}

/// True for any virtual loopback device we capture from (bundled driver or
/// BlackHole). Such devices must never be offered as render sinks, set as the
/// restored default, or treated as "followed" system output.
func isVirtualLoopbackDevice(_ id: AudioDeviceID) -> Bool {
    if id == AudioDeviceID(kAudioObjectUnknown) { return false }
    if let atmos = findAtmosControlDevice(), id == atmos { return true }
    if let bh = findBlackHole16chDevice(), id == bh { return true }
    // Name-based fallback: AudioDeviceIDs are reassigned across boots, so if
    // enumeration raced, still recognise the loopbacks by name.
    let n = deviceName(id).lowercased()
    if n.contains("atmos-control") { return true }
    if n.contains("blackhole") {
        let chans = max(deviceChannelCount(id, scope: kAudioObjectPropertyScopeOutput),
                        deviceChannelCount(id, scope: kAudioObjectPropertyScopeInput))
        return chans >= 12
    }
    return false
}

/// HDMI / DisplayPort sinks are usually an AV receiver or a TV that decodes multichannel
/// itself — the natural default for those is "leave it alone" (bypass).
func deviceTransportType(_ id: AudioDeviceID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
    return value
}

func deviceIsDisplayTransport(_ id: AudioDeviceID) -> Bool {
    let t = deviceTransportType(id)
    return t == kAudioDeviceTransportTypeHDMI || t == kAudioDeviceTransportTypeDisplayPort
}

func deviceNominalSampleRate(_ id: AudioDeviceID) -> Double? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var sz = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &rate) == noErr, rate > 0 else { return nil }
    return rate
}

func deviceBufferFrameSize(_ id: AudioDeviceID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var frames: UInt32 = 512
    var sz = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &frames) == noErr, frames > 0 else { return 512 }
    return frames
}

func defaultOutputDeviceID(system: Bool = false) -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(
        mSelector: system ? kAudioHardwarePropertyDefaultSystemOutputDevice
                          : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(kAudioObjectUnknown)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev)
    return dev
}

@discardableResult
func setDefaultOutputDeviceID(_ id: AudioDeviceID, system: Bool) -> OSStatus {
    var dev = id
    var addr = AudioObjectPropertyAddress(
        mSelector: system ? kAudioHardwarePropertyDefaultSystemOutputDevice
                          : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}
