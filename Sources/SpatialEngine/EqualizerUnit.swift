// SpatialEngine/EqualizerUnit.swift — 10-band fixed-frequency EQ (eqMac "Advanced" class)
// hosted as an Apple AUNBandEQ, plus the automatic pre-amp that keeps boosts from clipping.
//
// Placement in the graph: the EQ runs on the STEREO capture (2 channels) before any
// spatialization/upmixing, so its cost is independent of how many virtual speakers the
// renderer ends up using. It pulls the ring itself (eqInputCallback) and is rendered once
// per cycle from whichever callback needs the post-EQ stereo.

import CoreAudio
import AudioToolbox
import Darwin
import Foundation

// MARK: - AUNBandEQ constants
//
// Declared numerically (like the AUSpatialMixer IDs in Audio.swift) so the build does not
// depend on how a given SDK surfaces these CF_ENUMs to Swift. Values from
// <AudioToolbox/AudioUnitParameters.h> / <AudioToolbox/AudioUnitProperties.h>.

let kEQPropertyNumberOfBands: AudioUnitPropertyID = 2200
let kEQParamGlobalGain:       AudioUnitParameterID = 0
let kEQParamBypassBand:       AudioUnitParameterID = 1000
let kEQParamFilterType:       AudioUnitParameterID = 2000
let kEQParamFrequency:        AudioUnitParameterID = 3000
let kEQParamGain:             AudioUnitParameterID = 4000
let kEQParamBandwidth:        AudioUnitParameterID = 5000
let kEQFilterTypeParametric:  AudioUnitParameterValue = 0

// MARK: - Config

public enum PreampMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, manual
    public var id: String { rawValue }
    public var label: String { self == .auto ? "Auto" : "Manual" }
}

/// The complete EQ state. Value type: this is what presets store and what the UI edits.
public struct EQConfig: Codable, Equatable, Sendable {
    /// Fixed 10-band layout (eqMac Advanced): one band per octave, 32 Hz … 16 kHz.
    public static let frequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    public static let bandCount = 10
    /// Parametric bandwidth in octaves (Q ≈ 1.41). Fixed — not exposed in the UI.
    public static let bandwidthOctaves: Float = 1.0
    public static let gainLimit: Float = 12          // ±12 dB
    public static let preampLimit: Float = 24        // manual pre-amp travel, and the auto floor

    public var enabled: Bool = true
    public var gains: [Float] = Array(repeating: 0, count: EQConfig.bandCount)
    public var preampMode: PreampMode = .auto
    public var manualPreamp: Float = 0

    public init() {}

    public init(enabled: Bool, gains: [Float], preampMode: PreampMode = .auto, manualPreamp: Float = 0) {
        self.enabled = enabled
        self.gains = gains
        self.preampMode = preampMode
        self.manualPreamp = manualPreamp
    }

    /// Always exactly `bandCount` values, each clamped to ±`gainLimit`.
    public var normalizedGains: [Float] {
        var g = gains
        if g.count < EQConfig.bandCount { g += Array(repeating: 0, count: EQConfig.bandCount - g.count) }
        if g.count > EQConfig.bandCount { g = Array(g.prefix(EQConfig.bandCount)) }
        return g.map { min(max($0.isFinite ? $0 : 0, -EQConfig.gainLimit), EQConfig.gainLimit) }
    }

    public var isFlat: Bool { normalizedGains.allSatisfy { abs($0) < 0.005 } }

    /// The gain actually pushed into AUNBandEQ's GlobalGain.
    public func effectivePreamp(sampleRate: Double = 48_000) -> Float {
        switch preampMode {
        case .manual:
            return min(max(manualPreamp, -EQConfig.preampLimit), EQConfig.gainLimit)
        case .auto:
            return EQConfig.autoPreamp(for: normalizedGains, sampleRate: sampleRate)
        }
    }

    // MARK: Composite response

    /// Automatic pre-amp: the negative of the composite response peak, so the loudest
    /// point of the curve lands back at 0 dB. Cuts are never compensated upward
    /// (that would re-introduce clipping headroom loss for no benefit).
    public static func autoPreamp(for gains: [Float], sampleRate: Double = 48_000) -> Float {
        let peak = peakResponseDB(gains: gains, sampleRate: sampleRate)
        if peak <= 0 { return 0 }
        return -min(peak, preampLimit)
    }

    /// Max |H(f)| over 20 Hz … 20 kHz, in dB. ~512 log-spaced probes; a few tens of µs.
    public static func peakResponseDB(gains: [Float], sampleRate: Double = 48_000) -> Float {
        let points = 512
        let fLo = 20.0, fHi = min(20_000.0, sampleRate * 0.49)
        guard fHi > fLo else { return 0 }
        let ratio = log(fHi / fLo)
        var peak: Float = 0
        var i = 0
        while i < points {
            let f = fLo * exp(ratio * Double(i) / Double(points - 1))
            let db = responseDB(gains: gains, sampleRate: sampleRate, frequency: Float(f))
            if db > peak { peak = db }
            i += 1
        }
        return peak
    }

    /// Composite magnitude response (dB) of the 10 peaking sections at one frequency.
    public static func responseDB(gains: [Float], sampleRate: Double = 48_000, frequency: Float) -> Float {
        var total: Double = 1
        for (i, gRaw) in gains.enumerated() where i < frequencies.count {
            let g = Double(gRaw)
            if abs(g) < 0.01 { continue }
            let f0 = Double(frequencies[i])
            guard f0 < sampleRate * 0.49 else { continue }
            total *= biquadMagnitude(f: Double(frequency), f0: f0, gainDB: g,
                                     bw: Double(bandwidthOctaves), sampleRate: sampleRate)
        }
        return Float(20 * log10(max(total, 1e-9)))
    }

    /// Linear magnitude of one RBJ peaking-EQ section (the shape AUNBandEQ's
    /// "Parametric" filter implements) at frequency `f`.
    private static func biquadMagnitude(f: Double, f0: Double, gainDB: Double,
                                        bw: Double, sampleRate: Double) -> Double {
        let A  = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let sw = sin(w0), cw = cos(w0)
        guard sw > 1e-9 else { return 1 }
        let alpha = sw / 2 * sinh(log(2.0) / 2 * bw * w0 / sw)

        let b0 = 1 + alpha * A, b1 = -2 * cw, b2 = 1 - alpha * A
        let a0 = 1 + alpha / A, a1 = -2 * cw, a2 = 1 - alpha / A

        let w = 2 * Double.pi * f / sampleRate
        let c1 = cos(w), s1 = sin(w)
        let c2 = cos(2 * w), s2 = sin(2 * w)

        let numRe = b0 + b1 * c1 + b2 * c2, numIm = -(b1 * s1 + b2 * s2)
        let denRe = a0 + a1 * c1 + a2 * c2, denIm = -(a1 * s1 + a2 * s2)
        let num = sqrt(numRe * numRe + numIm * numIm)
        let den = sqrt(denRe * denRe + denIm * denIm)
        return den > 1e-12 ? num / den : 1
    }
}

// MARK: - The hosted AudioUnit

/// Wraps one initialized AUNBandEQ configured for 10 fixed parametric bands on a stereo
/// float stream. Created on the setup thread; `apply()` is safe to call while running
/// (AUNBandEQ ramps its coefficients internally, so there is no zipper noise).
final class EqualizerUnit {
    private(set) var unit: AudioUnit?
    private let sampleRate: Double

    init?(ctxPtr: UnsafeMutableRawPointer, sampleRate: Double, maxFrames: UInt32) {
        self.sampleRate = sampleRate
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_NBandEQ,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            selog("  ERR AUNBandEQ component not found")
            return nil
        }
        var u: AudioUnit? = nil
        guard check(AudioComponentInstanceNew(comp, &u), "eq AudioComponentInstanceNew"), let eq = u else { return nil }

        var bands = UInt32(EQConfig.bandCount)
        check(AudioUnitSetProperty(eq, kEQPropertyNumberOfBands, kAudioUnitScope_Global, 0,
                                   &bands, UInt32(MemoryLayout<UInt32>.size)),
              "eq NumberOfBands=\(EQConfig.bandCount)")

        var fmt = stereoFloat32Format(sampleRate: sampleRate)
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard check(AudioUnitSetProperty(eq, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, asbdSize),
                    "eq StreamFormat Input/0 = stereo@\(Int(sampleRate))"),
              check(AudioUnitSetProperty(eq, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, asbdSize),
                    "eq StreamFormat Output/0 = stereo@\(Int(sampleRate))") else {
            AudioComponentInstanceDispose(eq); return nil
        }

        var maxF = maxFrames
        check(AudioUnitSetProperty(eq, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                   &maxF, UInt32(MemoryLayout<UInt32>.size)), "eq MaximumFramesPerSlice=\(maxFrames)")

        var cb = AURenderCallbackStruct(inputProc: eqInputCallback, inputProcRefCon: ctxPtr)
        check(AudioUnitSetProperty(eq, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                   &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "eq SetRenderCallback")

        // Fixed band layout: parametric, one octave wide, at the canonical frequencies.
        for i in 0..<EQConfig.bandCount {
            let e = AudioUnitElement(0)
            let idx = AudioUnitParameterID(i)
            AudioUnitSetParameter(eq, kEQParamFilterType + idx, kAudioUnitScope_Global, e, kEQFilterTypeParametric, 0)
            AudioUnitSetParameter(eq, kEQParamFrequency + idx, kAudioUnitScope_Global, e,
                                  AudioUnitParameterValue(EQConfig.frequencies[i]), 0)
            AudioUnitSetParameter(eq, kEQParamBandwidth + idx, kAudioUnitScope_Global, e,
                                  AudioUnitParameterValue(EQConfig.bandwidthOctaves), 0)
            AudioUnitSetParameter(eq, kEQParamGain + idx, kAudioUnitScope_Global, e, 0, 0)
            AudioUnitSetParameter(eq, kEQParamBypassBand + idx, kAudioUnitScope_Global, e, 0, 0)
        }

        guard check(AudioUnitInitialize(eq), "eq AudioUnitInitialize") else {
            AudioComponentInstanceDispose(eq); return nil
        }
        unit = eq
    }

    /// Push gains + pre-amp + the global bypass. Safe while the graph is running.
    func apply(_ config: EQConfig, sampleRate: Double? = nil) {
        guard let eq = unit else { return }
        let sr = sampleRate ?? self.sampleRate
        let gains = config.normalizedGains
        for i in 0..<EQConfig.bandCount {
            AudioUnitSetParameter(eq, kEQParamGain + AudioUnitParameterID(i), kAudioUnitScope_Global, 0,
                                  AudioUnitParameterValue(gains[i]), 0)
        }
        AudioUnitSetParameter(eq, kEQParamGlobalGain, kAudioUnitScope_Global, 0,
                              AudioUnitParameterValue(config.effectivePreamp(sampleRate: sr)), 0)
        // Global bypass: keeps the unit (and therefore the graph) intact, so toggling the
        // EQ on and off never rebuilds anything and never drops audio.
        var bypass: UInt32 = config.enabled ? 0 : 1
        AudioUnitSetProperty(eq, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0,
                             &bypass, UInt32(MemoryLayout<UInt32>.size))
    }

    func dispose() {
        guard let eq = unit else { return }
        AudioUnitUninitialize(eq)
        AudioComponentInstanceDispose(eq)
        unit = nil
    }
}
