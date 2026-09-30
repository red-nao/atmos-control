// AtmosControlApp/Profiles.swift — spatial presets and per-output-device profiles.
//
// A profile answers one question: "when audio is going to THIS device, what should
// atmos-control do?" — including "nothing at all" (bypass), which is the whole point of
// F7: an HDMI receiver that already decodes 5.1 should never see our stereo render.

import Foundation
import SpatialEngine

// MARK: - Spatial preset

/// A named snapshot of everything under Soundstage / Personalization / Rendering / Reverb.
/// The EQ is deliberately NOT part of it — EQ has its own presets, and the two axes
/// (tone vs. staging) are chosen independently.
struct SpatialPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var spatial: SpatialConfig
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let builtInDefault = SpatialPreset(id: defaultID, name: "Default", spatial: SpatialConfig())
    var isBuiltIn: Bool { id == SpatialPreset.defaultID }

    /// Compare the staging fields only (EQ and the on/off switch are not ours).
    func matches(_ c: SpatialConfig) -> Bool { SpatialPreset.staging(of: spatial) == SpatialPreset.staging(of: c) }

    /// This preset applied on top of the live config, preserving EQ and the master
    /// spatialize switch (those are owned by the profile / the user's toggle).
    func applied(to c: SpatialConfig) -> SpatialConfig {
        var out = spatial
        out.eq = c.eq
        out.spatialize = c.spatialize
        out.sourceMode = c.sourceMode        // capture-choice territory, not a preset's
        return out
    }

    /// The comparable subset: everything except eq / spatialize / sourceMode.
    static func staging(of c: SpatialConfig) -> SpatialConfig {
        var s = c
        s.eq = EQConfig()
        s.spatialize = true
        s.sourceMode = .dualPointStereo
        return s
    }

    static func capture(from c: SpatialConfig, name: String) -> SpatialPreset {
        SpatialPreset(name: name, spatial: staging(of: c))
    }
}

// MARK: - Device profile

enum DeviceMode: String, Codable, CaseIterable, Identifiable {
    case process    // run the engine (EQ / spatial / upmix as configured)
    case bypass     // don't touch this device at all — no tap, no render
    var id: String { rawValue }
    var label: String { self == .process ? "Process" : "Bypass" }
}

struct DeviceProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    /// kAudioDevicePropertyDeviceUID — the primary key. Empty for the fallback profile.
    var deviceUID: String = ""
    /// Display name, and the secondary match when a Bluetooth device's UID changes.
    var deviceName: String = ""
    var mode: DeviceMode = .process
    var eqEnabled: Bool = true
    var eqPresetID: UUID? = EQPreset.flatID
    var spatialEnabled: Bool = true
    var spatialPresetID: UUID? = SpatialPreset.defaultID
    /// Reserved for P4 (the STFT upmixer); stored now so profiles don't need a migration.
    var upmixEnabled: Bool = false
    /// false = "remember this device but never auto-apply" (leave whatever is set).
    var autoSwitch: Bool = true

    static let fallbackID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    static var fallback: DeviceProfile {
        DeviceProfile(id: fallbackID, deviceUID: "", deviceName: "Any other device")
    }
    var isFallback: Bool { id == DeviceProfile.fallbackID }

    /// New profiles for devices that are almost certainly already doing their own
    /// multichannel decoding default to bypass (§5.3).
    static func suggested(forName name: String, uid: String, transportIsDisplay: Bool) -> DeviceProfile {
        var p = DeviceProfile(deviceUID: uid, deviceName: name)
        if transportIsDisplay { p.mode = .bypass }
        return p
    }

    /// Does this profile already describe the given live state?
    func matches(eqEnabled: Bool, eqPreset: UUID?, spatialEnabled: Bool, spatialPreset: UUID?,
                 upmixEnabled: Bool, bypassed: Bool) -> Bool {
        mode == (bypassed ? .bypass : .process)
            && self.eqEnabled == eqEnabled && self.eqPresetID == eqPreset
            && self.spatialEnabled == spatialEnabled && self.spatialPresetID == spatialPreset
            && self.upmixEnabled == upmixEnabled
    }
}
