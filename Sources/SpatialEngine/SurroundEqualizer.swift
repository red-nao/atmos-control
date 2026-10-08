// SpatialEngine/SurroundEqualizer.swift — 10-band EQ for 7.1.4 capture.
//
// AUNBandEQ is used for stereo paths. Surround capture has twelve mono feeds, so this
// small RBJ peaking-filter bank applies the same curve independently to each channel
// before it reaches AUSpatialMixer. All storage is allocated at graph setup; process() is
// called from the playback RT callback and performs no allocation or locking. The user-
// facing Equalizer bypass controls the DSP; a flat curve skips band filtering while a
// non-zero manual pre-amp still applies its intended scalar gain.

import Darwin
import Foundation
import Synchronization

private struct SurroundBiquad {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0

    static let identity = SurroundBiquad()

    var isIdentity: Bool {
        abs(b0 - 1) < 1e-6 && abs(b1) < 1e-6 && abs(b2) < 1e-6
            && abs(a1) < 1e-6 && abs(a2) < 1e-6
    }
}

private struct SurroundBiquadState {
    var z1: Float = 0
    var z2: Float = 0
}

/// A per-channel 10-band parametric equalizer for 7.1.4 material.
///
/// update() is called from the control thread; process() is called only from the audio
/// render thread. Target coefficients are aligned Float values, like the live STFT
/// controls. The render thread owns filter state and slews coefficient/preamp changes over
/// about 20 ms so dragging an EQ fader does not click.
final class SurroundEqualizer: @unchecked Sendable {
    private let channelCount: Int
    private let maxFrames: Int
    private let sampleRate: Double
    private let bandCount = EQConfig.bandCount

    private let target0: UnsafeMutablePointer<SurroundBiquad>
    private let target1: UnsafeMutablePointer<SurroundBiquad>
    private let target2: UnsafeMutablePointer<SurroundBiquad>
    private let targetIndex = Atomic<UInt64>(0)
    private let readerIndex = Atomic<UInt64>(3) // 3 = no RT reader currently copying a bank
    private let current: UnsafeMutablePointer<SurroundBiquad>
    private let states: UnsafeMutablePointer<SurroundBiquadState>
    private let dry: UnsafeMutablePointer<Float>

    // The control thread fills a bank that is neither published nor being read, then
    // release-publishes its index. The render thread briefly marks its reader bank while
    // copying the target into RT-owned current values. No lock or partial coefficient set.
    private var targetPreamp0: Float = 1
    private var targetPreamp1: Float = 1
    private var targetPreamp2: Float = 1
    private var targetWet0: Float = 0
    private var targetWet1: Float = 0
    private var targetWet2: Float = 0

    // Render-thread-owned state.
    private var currentPreamp: Float = 1
    private var currentWet: Float = 0

    init?(channels: Int, sampleRate: Double, maxFrames: Int, config: EQConfig) {
        guard channels == kAtmos714Channels, sampleRate > 0, maxFrames > 0 else { return nil }
        channelCount = channels
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames

        target0 = .allocate(capacity: bandCount)
        target1 = .allocate(capacity: bandCount)
        target2 = .allocate(capacity: bandCount)
        current = .allocate(capacity: bandCount)
        states = .allocate(capacity: channels * bandCount)
        dry = .allocate(capacity: maxFrames)
        target0.initialize(repeating: .identity, count: bandCount)
        target1.initialize(repeating: .identity, count: bandCount)
        target2.initialize(repeating: .identity, count: bandCount)
        current.initialize(repeating: .identity, count: bandCount)
        states.initialize(repeating: SurroundBiquadState(), count: channels * bandCount)
        dry.initialize(repeating: 0, count: maxFrames)

        update(config)
        let active = Int(targetIndex.load(ordering: .acquiring))
        let initialTarget = bank(at: active)
        for band in 0..<bandCount { current[band] = initialTarget[band] }
        currentPreamp = active == 0 ? targetPreamp0 : (active == 1 ? targetPreamp1 : targetPreamp2)
        currentWet = active == 0 ? targetWet0 : (active == 1 ? targetWet1 : targetWet2)
    }

    deinit {
        target0.deallocate()
        target1.deallocate()
        target2.deallocate()
        current.deallocate()
        states.deallocate()
        dry.deallocate()
    }

    @inline(__always)
    private func bank(at index: Int) -> UnsafeMutablePointer<SurroundBiquad> {
        switch index {
        case 0: return target0
        case 1: return target1
        default: return target2
        }
    }

    /// Publish a new EQ curve and pre-amp. This is deliberately setup/control-thread only;
    /// all transcendental coefficient math stays out of the real-time callback.
    func update(_ config: EQConfig) {
        let published = Int(targetIndex.load(ordering: .acquiring))
        let reader = Int(readerIndex.load(ordering: .acquiring))
        var next = 0
        while next == published || next == reader { next += 1 }
        let bank = bank(at: next)
        let gains = config.normalizedGains
        var shaped = false
        for band in 0..<bandCount {
            let gain = gains[band]
            if abs(gain) >= 0.005 { shaped = true }
            bank[band] = Self.coefficients(gainDB: gain,
                                           frequency: EQConfig.frequencies[band],
                                           sampleRate: sampleRate)
        }

        let preampDB = config.enabled ? config.effectivePreamp(sampleRate: sampleRate) : 0
        let preamp = Float(pow(10.0, Double(preampDB) / 20.0))
        let needsProcessing = config.enabled && (shaped || abs(preampDB) >= 0.005)
        let wet: Float = needsProcessing ? 1 : 0
        switch next {
        case 0:
            targetPreamp0 = preamp; targetWet0 = wet
        case 1:
            targetPreamp1 = preamp; targetWet1 = wet
        default:
            targetPreamp2 = preamp; targetWet2 = wet
        }
        targetIndex.store(UInt64(next), ordering: .releasing)
    }

    /// In-place EQ of `channelCount` non-interleaved planes. RT-safe: no Array, lock,
    /// AudioUnit call, or dynamic allocation.
    @inline(__always)
    func process(_ planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        let count = min(max(frames, 0), maxFrames)
        guard count > 0 else { return }

        let wasDry = currentWet <= 0.00001
        var targetSlot = Int(targetIndex.load(ordering: .acquiring))
        while true {
            readerIndex.store(UInt64(targetSlot), ordering: .releasing)
            let confirmed = Int(targetIndex.load(ordering: .acquiring))
            if confirmed == targetSlot { break }
            readerIndex.store(3, ordering: .releasing)
            targetSlot = confirmed
        }
        let targetBands = bank(at: targetSlot)
        let requestedPreamp: Float
        let requestedWet: Float
        switch targetSlot {
        case 0:
            requestedPreamp = targetPreamp0; requestedWet = targetWet0
        case 1:
            requestedPreamp = targetPreamp1; requestedWet = targetWet1
        default:
            requestedPreamp = targetPreamp2; requestedWet = targetWet2
        }
        let smoothing = min(1, Float(count) / Float(sampleRate * 0.020))

        var band = 0
        while band < bandCount {
            let t = targetBands[band]
            var c = current[band]
            c.b0 += smoothing * (t.b0 - c.b0)
            c.b1 += smoothing * (t.b1 - c.b1)
            c.b2 += smoothing * (t.b2 - c.b2)
            c.a1 += smoothing * (t.a1 - c.a1)
            c.a2 += smoothing * (t.a2 - c.a2)
            if t.isIdentity && c.isIdentity { c = .identity }
            current[band] = c
            band += 1
        }
        readerIndex.store(3, ordering: .releasing)
        currentPreamp += smoothing * (requestedPreamp - currentPreamp)
        currentWet += smoothing * (requestedWet - currentWet)

        if currentWet < 0.00001 && requestedWet == 0 {
            currentWet = 0
            return
        }

        // A bypassed interval leaves stale IIR history. Reset it on the first block that
        // becomes wet again; the 20 ms dry/wet ramp masks the filter's warm-up transient.
        if wasDry && requestedWet > 0 {
            var i = 0
            while i < channelCount * bandCount {
                states[i] = SurroundBiquadState()
                i += 1
            }
        }

        let wet = currentWet
        let preamp = currentPreamp
        var channel = 0
        while channel < channelCount {
            let samples = planes[channel]
            memcpy(dry, samples, count * MemoryLayout<Float>.size)

            band = 0
            while band < bandCount {
                let stateIndex = channel * bandCount + band
                let c = current[band]
                if c.isIdentity {
                    states[stateIndex] = SurroundBiquadState()
                    band += 1
                    continue
                }
                var state = states[stateIndex]
                var i = 0
                while i < count {
                    let x = samples[i]
                    let y = c.b0 * x + state.z1
                    state.z1 = c.b1 * x - c.a1 * y + state.z2
                    state.z2 = c.b2 * x - c.a2 * y
                    samples[i] = y
                    i += 1
                }
                states[stateIndex] = state
                band += 1
            }

            var i = 0
            while i < count {
                let original = dry[i]
                let equalized = samples[i] * preamp
                samples[i] = original + wet * (equalized - original)
                i += 1
            }
            channel += 1
        }
    }

    private static func coefficients(gainDB: Float, frequency: Float,
                                     sampleRate: Double) -> SurroundBiquad {
        guard abs(gainDB) >= 0.005, Double(frequency) < sampleRate * 0.49 else { return .identity }

        let f0 = Double(frequency)
        let gain = Double(gainDB)
        let bandwidth = Double(EQConfig.bandwidthOctaves)
        let omega = 2 * Double.pi * f0 / sampleRate
        let sine = sin(omega)
        guard abs(sine) > 1e-9 else { return .identity }

        // Keep the bandwidth convention in step with EQConfig.responseDB, which also
        // drives the Auto pre-amp curve readout.
        let alpha = sine / 2 * sinh(log(2.0) / 2 * bandwidth * omega / sine)
        let amplitude = pow(10.0, gain / 40.0)
        let cosine = cos(omega)
        let a0 = 1 + alpha / amplitude
        guard a0.isFinite, abs(a0) > 1e-12 else { return .identity }

        return SurroundBiquad(
            b0: Float((1 + alpha * amplitude) / a0),
            b1: Float((-2 * cosine) / a0),
            b2: Float((1 - alpha * amplitude) / a0),
            a1: Float((-2 * cosine) / a0),
            a2: Float((1 - alpha / amplitude) / a0))
    }
}
