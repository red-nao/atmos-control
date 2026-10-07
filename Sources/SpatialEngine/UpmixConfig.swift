// SpatialEngine/UpmixConfig.swift — parameters for the STFT 2→N upmixer.
//
// Two kernels share one analysis engine (see STFTUpmixer.swift):
//
//   .classic — the first-generation kernel: 5.1, no heights, per-bin coherence with a
//              fitted L/C/R centre law. It is what Apple's own "Spatialize Stereo" does
//              in outline (frame 1024, MPEG_5_1_A), and what this project shipped before
//              the quality pass — kept so an A/B is one picker change away.
//   .natural — default. Adds: a diffuseness estimator that cannot mistake a hard-panned
//              source for ambience, power-exact masks, an energy-correct centre law, a
//              transient-preserving asymmetric mask, bass management on the sends, an
//              Auro-Matic-style reflection/height layer, a strength control and a slow
//              loudness trim. Every change is documented in docs/UPMIX-QUALITY.md, and
//              tools/upmix-lab/ reproduces the measurements offline.
//
// Room for more (see the doc): multi-resolution analysis (a second, shorter FFT for
// transients), per-band mask aggregation, a bias-corrected estimator per critical band,
// and a deterministic (non-random) decorrelator for the front pair.

import Foundation

public enum UpmixLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    case surround51, surround714
    public var id: String { rawValue }
    public var label: String { self == .surround51 ? "5.1" : "7.1.4" }
    /// Channel (= mixer input bus) count, in Atmos_7_1_4 order truncated to size.
    public var channels: Int { self == .surround51 ? 6 : kAtmos714Channels }
}

public enum LFEMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, lowpass150
    public var id: String { rawValue }
    public var label: String { self == .off ? "Off" : "150 Hz low-pass" }
}

/// Which kernel runs. `.natural` is the quality pass; `.classic` is the original.
public enum UpmixQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case classic, natural
    public var id: String { rawValue }
    public var label: String { self == .classic ? "Classic" : "Natural" }
    public var blurb: String {
        switch self {
        case .classic: return "Original kernel — direct/ambient split with a fitted centre law."
        case .natural: return "Current kernel — transient-aware, bass-managed, reflection heights."
        }
    }
}

public struct UpmixConfig: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var layout: UpmixLayout = .surround51
    /// 2048 (42.7 ms @48 kHz) or 1024. Changing it rebuilds the graph.
    public var fftSize: Int = 2048
    /// `.natural` (default) or `.classic`. Live — no rebuild, so it is a direct A/B.
    public var quality: UpmixQuality = .natural
    public var centerStrength: Float = 1.0      // 0…1.5
    public var surroundLevel: Float = 0         // dB, -24…+6
    public var heightLevel: Float = -6          // dB, -24…+6 (7.1.4 only)
    public var decorrelation: Float = 0.7       // 0…1
    public var ambientBias: Float = 0           // dB, -12…+12 (gain on the sends)
    public var lfeMode: LFEMode = .off
    public var surroundSpread: Float = 1.0      // 0.5…1.3 (scales the surround angles)

    // MARK: Natural-kernel controls (all live)

    /// Master effect amount, Auro-Matic style: 0 = the input passes through untouched,
    /// 1 = full upmix. Scales the diffuseness mask, the centre pull and the reflections.
    public var strength: Float = 1.0            // 0…1
    /// Share of the extracted ambience that leaves the front pair for the surrounds and
    /// heights. 0 keeps everything in front (subtle), 1 sends all of it (immersive).
    public var spread: Float = 0.6              // 0…1
    /// Transient preservation: 1 = the mask opens fast and onsets briefly mute the
    /// sends; 0 = symmetric smoothing (the classic behaviour).
    public var transients: Float = 1.0          // 0…1
    /// Early-reflection (height/rear) layer trim, on top of the -6 dB base level.
    public var reflectionsLevel: Float = 0      // dB, -24…+6
    /// High-pass the surround/height sends at 150 Hz so the low end stays in the front.
    public var bassManagement: Bool = true
    /// Slow (≈0.5 s) bed-domain trim so switching the upmixer on/off does not change
    /// loudness. It is a loudness trim, not a calibrated loudness model.
    public var autoLevel: Bool = true

    public init() {}

    /// Algorithmic latency added by the STFT (one full analysis window).
    public func latencyMS(sampleRate: Double) -> Double {
        sampleRate > 0 ? Double(fftSize) / sampleRate * 1000 : 0
    }

    enum CodingKeys: String, CodingKey {
        case enabled, layout, fftSize, quality, centerStrength, surroundLevel, heightLevel
        case decorrelation, ambientBias, lfeMode, surroundSpread
        case strength, spread, transients, reflectionsLevel, bassManagement, autoLevel
    }

    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        enabled          = lenient(c, .enabled, enabled)
        layout           = lenient(c, .layout, layout)
        fftSize          = lenient(c, .fftSize, fftSize)
        quality          = lenient(c, .quality, quality)
        centerStrength   = clampFinite(lenient(c, .centerStrength, centerStrength), 0, 1.5, 1)
        surroundLevel    = clampFinite(lenient(c, .surroundLevel, surroundLevel), -24, 6, 0)
        heightLevel      = clampFinite(lenient(c, .heightLevel, heightLevel), -24, 6, -6)
        decorrelation    = clampFinite(lenient(c, .decorrelation, decorrelation), 0, 1, 0.7)
        ambientBias      = clampFinite(lenient(c, .ambientBias, ambientBias), -12, 12, 0)
        lfeMode          = lenient(c, .lfeMode, lfeMode)
        surroundSpread   = clampFinite(lenient(c, .surroundSpread, surroundSpread), 0.5, 1.3, 1)
        strength         = clampFinite(lenient(c, .strength, strength), 0, 1, 1)
        spread           = clampFinite(lenient(c, .spread, spread), 0, 1, 0.6)
        transients       = clampFinite(lenient(c, .transients, transients), 0, 1, 1)
        reflectionsLevel = clampFinite(lenient(c, .reflectionsLevel, reflectionsLevel), -24, 6, 0)
        bassManagement   = lenient(c, .bassManagement, bassManagement)
        autoLevel        = lenient(c, .autoLevel, autoLevel)
        if fftSize != 1024 && fftSize != 2048 { fftSize = 2048 }
    }
}
