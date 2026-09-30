// SpatialEngine/Decorrelator.swift — fixed random-phase tables for the ambience channels.
//
// Flat white-noise phase decorrelates beautifully and smears every transient into a
// "shhh". The fix is to bound the GROUP delay instead of the phase: pick a slowly varying
// τ(f) in ±2.5 ms and integrate it into a phase curve. Percussive material then arrives
// within a couple of milliseconds of itself across the spectrum, while steady-state
// reverb still gets fully decorrelated.
//
// The tables are deterministic (fixed seed): the same build always sounds the same, and
// nothing has to be persisted.

import Foundation

enum Decorrelator {
    /// Maximum group delay excursion. 2.5 ms is well inside the ~5 ms fusion window.
    static let tauMaxSeconds: Float = 0.0025
    /// τ is drawn every `segment` bins and linearly interpolated between draws, so the
    /// delay varies smoothly with frequency rather than bin-to-bin.
    static let segment = 8

    /// Fill `phi[ch][0...bins-1]` with the phase curves. Channel 0/1/2/3 (L/R/C/LFE) get
    /// zero phase — only the ambience channels are decorrelated.
    static func fill(phi: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
                     channels: Int, bins: Int, sampleRate: Double, fftSize: Int) {
        var rng = SplitMix64(seed: 0x5EED_A7_C0FFEE)
        let df = Float(sampleRate / Double(fftSize))       // Hz per bin
        let twoPiDf = 2 * Float.pi * df

        for ch in 0..<channels {
            let out = phi[ch]
            // Front channels stay phase-coherent.
            if ch <= 3 {
                for k in 0..<bins { out[k] = 0 }
                continue
            }
            // Draw the control points for τ(f).
            let points = bins / segment + 2
            var taus = [Float](repeating: 0, count: points)
            for i in 0..<points { taus[i] = (rng.nextUnit() * 2 - 1) * tauMaxSeconds }

            var acc: Float = 0
            for k in 0..<bins {
                let pos = Float(k) / Float(segment)
                let i = Int(pos)
                let frac = pos - Float(i)
                let tau = taus[i] + (taus[min(i + 1, points - 1)] - taus[i]) * frac
                // φ(k) = -2π · Σ τ · Δf  (discrete integral of the group delay)
                acc -= twoPiDf * tau
                // Below ~300 Hz phase games destroy the image — fade the curve to zero.
                let f = Float(k) * df
                let w: Float = f <= 100 ? 0 : (f >= 300 ? 1 : (f - 100) / 200)
                out[k] = acc * w
            }
        }
    }
}

/// Tiny deterministic PRNG — we only need reproducible noise, not statistical rigour.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
