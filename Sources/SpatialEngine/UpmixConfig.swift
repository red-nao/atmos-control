// SpatialEngine/UpmixConfig.swift — parameters for the STFT 2→N upmixer.
//
// Defaults follow what Apple's own "Spatialize Stereo" does (ScottySTFTUpmixer, frame
// size 1024, output MPEG_5_1_A): 5.1, no heights, LFE off — the low end is already in
// L/R and the spatial mixer bypasses the LFE bus anyway.

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

public struct UpmixConfig: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var layout: UpmixLayout = .surround51
    /// 2048 (42.7 ms @48 kHz) or 1024. Changing it rebuilds the graph.
    public var fftSize: Int = 2048
    public var centerStrength: Float = 1.0      // 0…1.5
    public var surroundLevel: Float = 0         // dB, -24…+6
    public var heightLevel: Float = -6          // dB, -24…+6 (7.1.4 only)
    public var decorrelation: Float = 0.7       // 0…1
    public var ambientBias: Float = 0           // dB, -12…+12
    public var lfeMode: LFEMode = .off
    public var surroundSpread: Float = 1.0      // 0.5…1.3 (scales the surround angles)

    public init() {}

    /// Algorithmic latency added by the STFT (one full analysis window).
    public func latencyMS(sampleRate: Double) -> Double {
        sampleRate > 0 ? Double(fftSize) / sampleRate * 1000 : 0
    }

    enum CodingKeys: String, CodingKey {
        case enabled, layout, fftSize, centerStrength, surroundLevel, heightLevel
        case decorrelation, ambientBias, lfeMode, surroundSpread
    }

    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        enabled        = lenient(c, .enabled, enabled)
        layout         = lenient(c, .layout, layout)
        fftSize        = lenient(c, .fftSize, fftSize)
        centerStrength = clampFinite(lenient(c, .centerStrength, centerStrength), 0, 1.5, 1)
        surroundLevel  = clampFinite(lenient(c, .surroundLevel, surroundLevel), -24, 6, 0)
        heightLevel    = clampFinite(lenient(c, .heightLevel, heightLevel), -24, 6, -6)
        decorrelation  = clampFinite(lenient(c, .decorrelation, decorrelation), 0, 1, 0.7)
        ambientBias    = clampFinite(lenient(c, .ambientBias, ambientBias), -12, 12, 0)
        lfeMode        = lenient(c, .lfeMode, lfeMode)
        surroundSpread = clampFinite(lenient(c, .surroundSpread, surroundSpread), 0.5, 1.3, 1)
        if fftSize != 1024 && fftSize != 2048 { fftSize = 2048 }
    }
}
