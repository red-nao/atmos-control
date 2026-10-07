// SpatialEngine/STFTUpmixer.swift — 2 → 6/12 channel upmix.
//
// Two kernels share one analysis/synthesis engine (see UpmixConfig.quality):
//
// `.classic` — the first-generation per-bin primary/ambient extractor, behaviour
//   unchanged since the fork. Coherence γ² says how much of a bin is phantom image
//   (direct) versus room/reverb (ambience), β says where that image sits, the direct
//   part is re-panned with a fitted L/C/R law and the ambience is decorrelated into the
//   surrounds. Two defects motivated the quality pass, both measured on the bench:
//     • the fitted centre law (C = √2·c·m with L/R = s + (1−c)·m) only preserves energy
//       at c = 0 and c = 1. In between it dips up to 2.9 dB, and because c moves per bin
//       and per frame the dip *modulates*: a W-shaped level curve across the stereo
//       image, which is what "phasey / dull / pumping" sounds like;
//     • γ² alone cannot separate "hard-panned" from "diffuse". A source panned fully to
//       one side has low coherence by construction, so the classic kernel treats it as
//       ambience and moves it: a hard-panned tone ends up 100 % in Ls/Rs and not at all
//       in the front. Avendano & Jot (2002) list the missing criterion explicitly — the
//       two channels must also have *comparable energy* to call a bin ambient.
//
// `.natural` — the default. Power-exact masks, an energy-correct centre law, a
//   diffuseness estimator using level similarity as well as coherence, asymmetric
//   (transient-preserving) smoothing, the decision aggregated over 1/3-octave critical
//   bands, bass management on the sends, and an Auro-Matic-style reflection/height layer
//   built in the time domain. Every choice is documented with its measurement in
//   docs/UPMIX-QUALITY.md, and tools/upmix-lab/upmix_lab.py reproduces the numbers
//   offline on any machine.
//
// RT contract: every buffer and FFT setup is allocated in init and freed in deinit;
// process() allocates nothing, takes no locks and calls no Swift runtime entry points
// (no Array, no String, no ARC — that is why the kernel selector is a Bool, not the enum).

import Accelerate
import Foundation

// Atmos_7_1_4 bus order: 0 L, 1 R, 2 C, 3 LFE, 4 Ls, 5 Rs, 6 Rls, 7 Rrs,
//                        8 Vhl, 9 Vhr, 10 Ltr, 11 Rtr
private let chL = 0, chR = 1, chC = 2, chLFE = 3, chLs = 4, chRs = 5
private let chRls = 6, chRrs = 7, chVhl = 8, chVhr = 9, chLtr = 10, chRtr = 11

/// Early-reflection matrix for the natural kernel (7.1.4 only). Each destination gets
/// delayed, high-passed, HF-trimmed copies of the ground channels, weighted by physical
/// adjacency — mostly the speaker below, less the adjacent, least the diagonal opposite.
/// Auro-Matic describes its own height layer the same way (a slightly delayed, HF
/// rolled-off remix of the base layer), which is why its heights read as reflections
/// rather than as a bright phasey halo. Read on the setup thread only.
private let kReflSources: [Int] = [chL, chR, chC, chLs, chRs]
private let kReflDests:   [Int] = [chVhl, chVhr, chLtr, chRtr, chRls, chRrs]
private let kReflDelayMS: [Float] = [11, 17, 13, 23, 9, 9]
private let kReflWeights: [[Float]] = [
    [1.00, 0.30, 0.45, 0.65, 0.08],   // Vhl
    [0.30, 1.00, 0.45, 0.08, 0.65],   // Vhr
    [0.45, 0.12, 0.20, 0.95, 0.15],   // Ltr
    [0.12, 0.45, 0.20, 0.15, 0.95],   // Rtr
    [0.35, 0.05, 0.10, 0.55, 0.02],   // Rls
    [0.05, 0.35, 0.10, 0.02, 0.55],   // Rrs
]

final class STFTUpmixer {
    let channels: Int          // 6 (5.1) or 12 (7.1.4)
    let fftSize: Int
    let hop: Int
    private let half: Int      // fftSize / 2 — bins 1…half-1 complex; 0 = DC, half = Nyquist
    private let sampleRate: Double
    private let maxFrames: Int

    // FFT
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    // Windows / weights
    private let win: UnsafeMutablePointer<Float>          // √Hann, fftSize
    private let heightW: UnsafeMutablePointer<Float>      // half+1 — classic "air" send
    private let lfeW: UnsafeMutablePointer<Float>         // half+1

    // Natural-kernel band shapes (half+1 each)
    private let shapeSurroundBass: UnsafeMutablePointer<Float>
    private let shapeSurroundFlat: UnsafeMutablePointer<Float>
    private let shapeHeightBass: UnsafeMutablePointer<Float>
    private let shapeHeightFlat: UnsafeMutablePointer<Float>

    // Input FIFO (linear, shifted down by hop after each frame)
    private let inL: UnsafeMutablePointer<Float>
    private let inR: UnsafeMutablePointer<Float>
    private var inCount = 0
    private let inCap: Int

    // Analysis scratch
    private let frame: UnsafeMutablePointer<Float>        // fftSize
    private let aRe: UnsafeMutablePointer<Float>          // half
    private let aIm: UnsafeMutablePointer<Float>
    private let bRe: UnsafeMutablePointer<Float>
    private let bIm: UnsafeMutablePointer<Float>

    // Smoothed cross-spectrum state (half+1 each)
    private let pLL: UnsafeMutablePointer<Float>
    private let pRR: UnsafeMutablePointer<Float>
    private let pLRr: UnsafeMutablePointer<Float>
    private let pLRi: UnsafeMutablePointer<Float>

    // Per-output-channel spectra (channels × half)
    private let outRe: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let outIm: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    // Overlap-add tails (channels × fftSize) and the output FIFO (channels × outCap)
    private let ola: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let outFIFO: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private var outCount = 0
    private let outCap: Int

    // Decorrelation phase tables: base φ, and cos/sin of φ·decorrelation (rebuilt on change)
    private let phi: UnsafeMutablePointer<UnsafeMutablePointer<Float>>     // channels × (half+1)
    private let phCos: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let phSin: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    // Gentler curves for the two front-ambience copies (half+1 each, one per ear)
    private let frontPhi: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let frontCosL: UnsafeMutablePointer<Float>
    private let frontSinL: UnsafeMutablePointer<Float>
    private let frontCosR: UnsafeMutablePointer<Float>
    private let frontSinR: UnsafeMutablePointer<Float>
    private var tableDecorr: Float = -1

    // Natural-kernel state
    private let sD: UnsafeMutablePointer<Float>            // half+1 smoothed diffuseness
    // Critical-band aggregation (see docs/UPMIX-QUALITY.md §3.4). A per-bin decision
    // flutters from frame to frame on broadband transients — sibilants, cymbals — and
    // that flutter is heard as a "shh-shh" haze: the send gain becomes a comb that
    // changes shape every 10 ms. The decision is therefore taken per 1/3-octave band and
    // spread back over the bins, with `bandMix` of the (already smoothed) per-bin
    // estimate kept so that one very direct bin inside an ambient band is not swallowed.
    private let bandCount: Int
    private let binBand: UnsafeMutablePointer<Int>         // half+1 → band index
    private let bandPow: UnsafeMutablePointer<Float>       // bandCount, cleared each frame
    private let bandDRaw: UnsafeMutablePointer<Float>      // bandCount, cleared each frame
    private let sDBand: UnsafeMutablePointer<Float>        // bandCount smoothed band value
    private let bandMix: Float = 0.25
    private let coherenceBias: Float                       // 1/L of the coherence estimator
    private let biasInv: Float
    private let alphaSlow: Float                           // mask closing (reverb tails)
    private var alphaFast: Float                           // mask opening (transients)
    private var pNatural = true
    private var pStrength: Float = 1
    private var pSpread: Float = 0.6
    private var pTransients: Float = 1
    private var pReflections: Float = 1         // linear gain (config value is dB)
    private var pBassManage = true
    private var pAutoLevel = true
    private var powSlow: Float = 0
    private var onsetHold = 0
    private var sLevelGain: Float = 1

    // Reflection stage (7.1.4 only; zero destinations in 5.1)
    private let reflCount: Int
    private let reflDests: Int
    private let reflLen: Int                   // delay-line length (power of two)
    private let reflMask: Int
    private let reflDelay: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let reflW: UnsafeMutablePointer<Float>         // destinations × sources
    private let reflTau: UnsafeMutablePointer<Int>         // destinations, in samples
    private let reflSrcCh: UnsafeMutablePointer<Int>
    private let reflDestCh: UnsafeMutablePointer<Int>
    private let reflHpZ: UnsafeMutablePointer<Float>
    private let reflHpX: UnsafeMutablePointer<Float>
    private let reflLpZ: UnsafeMutablePointer<Float>
    private let reflHpA: Float
    private let reflLpA: Float
    private var reflIdx = 0

    // Parameters. Written by the main thread, read by the RT thread: aligned 32-bit
    // scalars, and every one of them is smoothed per frame below, so a torn update is
    // inaudible. (Swift's Atomic<Float> would need a boxed load on every bin.)
    private var pCenter: Float = 1
    private var pSurroundGain: Float = 1
    private var pHeightGain: Float = 0.5
    private var pDecorr: Float = 0.7
    private var pAmbient: Float = 1
    private var pLFE = false

    // Smoothed (per-frame one-pole, ~30 ms) working values
    private var sCenter: Float = 1
    private var sSurround: Float = 1
    private var sHeight: Float = 0.5
    private var sAmbient: Float = 1
    private var sStrength: Float = 1

    private let alphaSmooth: Float          // parameter smoothing coefficient
    private let alphaPowerClassic: Float    // classic cross-spectrum smoothing (τ = 50 ms)
    private let alphaPower: Float           // natural cross-spectrum smoothing (τ = 120 ms)
    private let scale: Float                // FFT round-trip + WOLA normalization

    init?(channels: Int, fftSize: Int, sampleRate: Double, maxFrames: Int, config: UpmixConfig) {
        guard channels == 6 || channels == kAtmos714Channels,
              fftSize == 1024 || fftSize == 2048, maxFrames > 0 else { return nil }
        self.channels = channels
        self.fftSize = fftSize
        self.hop = fftSize / 4
        self.half = fftSize / 2
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.maxFrames = maxFrames
        self.log2n = vDSP_Length(round(log2(Double(fftSize))))
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = s

        let N = fftSize, H = half
        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(n, 1))
            p.initialize(repeating: 0, count: max(n, 1))
            return p
        }
        func allocPlanes(_ count: Int, _ n: Int) -> UnsafeMutablePointer<UnsafeMutablePointer<Float>> {
            let pp = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: max(count, 1))
            for i in 0..<count { pp[i] = alloc(n) }
            return pp
        }

        // 1/3-octave band edges from 63 Hz: band = floor(3·log2(f/63)). Bins below 63 Hz
        // collapse into band 0. The same formula lives in tools/upmix-lab/upmix_lab.py
        // (`band_index`) — keep the two in step, the lab is how this is measured.
        func bandIndex(_ frequency: Double) -> Int {
            let f = frequency < 1 ? 1 : frequency
            let b = Int(floor(3 * log2(f / 63.0)))
            return b < 0 ? 0 : b
        }
        var lastBand = 0
        let binHz = self.sampleRate / Double(N)
        for k in 0...H {
            let b = bandIndex(Double(k) * binHz)
            if b > lastBand { lastBand = b }
        }
        bandCount = lastBand + 1

        win = alloc(N)
        heightW = alloc(H + 1)
        lfeW = alloc(H + 1)
        shapeSurroundBass = alloc(H + 1)
        shapeSurroundFlat = alloc(H + 1)
        shapeHeightBass = alloc(H + 1)
        shapeHeightFlat = alloc(H + 1)
        inCap = N + maxFrames + hop
        inL = alloc(inCap); inR = alloc(inCap)
        frame = alloc(N)
        aRe = alloc(H); aIm = alloc(H); bRe = alloc(H); bIm = alloc(H)
        pLL = alloc(H + 1); pRR = alloc(H + 1); pLRr = alloc(H + 1); pLRi = alloc(H + 1)
        outRe = allocPlanes(channels, H)
        outIm = allocPlanes(channels, H)
        ola = allocPlanes(channels, N)
        outCap = N + 2 * maxFrames + hop
        outFIFO = allocPlanes(channels, outCap)
        phi = allocPlanes(channels, H + 1)
        phCos = allocPlanes(channels, H + 1)
        phSin = allocPlanes(channels, H + 1)
        frontPhi = allocPlanes(6, H + 1)
        frontCosL = alloc(H + 1)
        frontSinL = alloc(H + 1)
        frontCosR = alloc(H + 1)
        frontSinR = alloc(H + 1)
        sD = alloc(H + 1)
        binBand = UnsafeMutablePointer<Int>.allocate(capacity: max(H + 1, 1))
        binBand.initialize(repeating: 0, count: max(H + 1, 1))
        bandPow = alloc(bandCount)
        bandDRaw = alloc(bandCount)
        sDBand = alloc(bandCount)

        // The reflection stage is a 7.1.4 feature. In 5.1 the surrounds are fed by the
        // ambience extraction alone, which measures clean (no hard-pan leakage, no bass).
        reflCount = (channels == kAtmos714Channels) ? kReflSources.count : 0
        reflDests = (channels == kAtmos714Channels) ? kReflDests.count : 0
        reflLen = 1 << 13                       // 8192 samples = 170 ms @48k, 43 ms @192k
        reflMask = reflLen - 1
        reflDelay = allocPlanes(max(reflCount, 1), reflLen)
        reflW = alloc(max(reflDests * max(reflCount, 1), 1))
        reflTau = UnsafeMutablePointer<Int>.allocate(capacity: max(reflDests, 1))
        reflTau.initialize(repeating: 0, count: max(reflDests, 1))
        reflSrcCh = UnsafeMutablePointer<Int>.allocate(capacity: max(reflCount, 1))
        reflSrcCh.initialize(repeating: 0, count: max(reflCount, 1))
        reflDestCh = UnsafeMutablePointer<Int>.allocate(capacity: max(reflDests, 1))
        reflDestCh.initialize(repeating: 0, count: max(reflDests, 1))
        reflHpZ = alloc(max(reflCount, 1))
        reflHpX = alloc(max(reflCount, 1))
        reflLpZ = alloc(max(reflCount, 1))

        // Every stored property must be set before self is usable below.
        let hopSeconds = Float(hop) / Float(self.sampleRate)
        // A short-time coherence estimate is biased upward by ~1/L for independent
        // channels; averaging for 120 ms (instead of the classic 50 ms) plus an explicit
        // debias keeps diffuse material out of the direct path.
        let naturalTau: Float = 0.120
        alphaPowerClassic = exp(-hopSeconds / 0.050)
        alphaPower = exp(-hopSeconds / naturalTau)
        // Transient preservation maps to the mask's opening time constant: 30 ms at 0
        // (gently asymmetric) down to 5 ms at 1, where onsets also gate the sends.
        alphaFast = exp(-hopSeconds / 0.030)
        alphaSlow = exp(-hopSeconds / 0.150)
        coherenceBias = hopSeconds / naturalTau
        biasInv = 1 / max(1 - coherenceBias, 1e-3)
        alphaSmooth = exp(-hopSeconds / 0.030)      // parameter smoothing τ = 30 ms
        // vDSP real FFT: forward is 2× the DFT, inverse is N× the IDFT → 1/(2N).
        // √Hann on analysis and synthesis is a Hann window, whose overlap-add at hop = N/4
        // sums to exactly 2.0 (four windows overlap and the cosine terms cancel). The fork
        // divided by 1.5, which made the upmixer 2.5 dB hotter than its input.
        scale = 1.0 / (2.0 * Float(N) * 2.0)

        // √Hann: applied on both analysis and synthesis, COLA-exact at hop = N/4.
        for i in 0..<N {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(N))
            win[i] = Float(sqrt(w))
        }
        // Classic height send: nothing below 2 kHz, full above 8 kHz.
        // LFE: flat to 120 Hz, cosine roll-off to 180 Hz.
        // Natural shapes: first-order high-pass at 150 Hz (bass management — the low end
        // must not detach from the front), then an HF roll-off for the height layer; both
        // normalized to unit power gain on white noise.
        let df = self.sampleRate / Double(N)
        for k in 0...H { binBand[k] = bandIndex(Double(k) * df) }
        let hpHz = 150.0
        var sumS = 0.0, sumH = 0.0
        for k in 0...H {
            let f = Double(k) * df
            if f < 2000 { heightW[k] = 0 }
            else if f < 8000 { heightW[k] = Float(log2(f / 2000) / 2.0) }
            else { heightW[k] = 1 }
            if f < 120 { lfeW[k] = 1 }
            else if f < 180 { lfeW[k] = Float(0.5 + 0.5 * cos(Double.pi * (f - 120) / 60)) }
            else { lfeW[k] = 0 }
            let hp = f / (f * f + hpHz * hpHz).squareRoot()
            let lp = 1.0 / (1.0 + (f / 7000.0) * (f / 7000.0)).squareRoot()
            shapeSurroundBass[k] = Float(hp)
            shapeSurroundFlat[k] = 1
            shapeHeightBass[k] = Float(hp * lp)
            shapeHeightFlat[k] = Float(lp)
            sumS += hp * hp
            sumH += hp * lp * hp * lp
        }
        let normS = Float(1.0 / (sumS / Double(H + 1)).squareRoot())
        let normH = Float(1.0 / (sumH / Double(H + 1)).squareRoot())
        for k in 0...H {
            shapeSurroundBass[k] *= normS
            shapeHeightBass[k] *= normH
            shapeHeightFlat[k] *= normH
        }

        // Bounded-group-delay decorrelation phases.
        Decorrelator.fill(phi: phi, channels: channels, bins: H + 1,
                          sampleRate: self.sampleRate, fftSize: N)
        // The front ambience gets a gentler curve (τ ≤ 1.2 ms): it is summed with the
        // direct path, so it may colour the image but must not smear transients.
        Decorrelator.fill(phi: frontPhi, channels: 6, bins: H + 1,
                          sampleRate: self.sampleRate, fftSize: N,
                          tauMax: 0.0012, segment: 4)

        // Reflection matrix (delays are stored in samples so the pattern follows the rate).
        for d in 0..<reflDests {
            reflDestCh[d] = kReflDests[d]
            let samples = Int((kReflDelayMS[d] / 1000.0) * Float(self.sampleRate))
            reflTau[d] = min(max(samples, 1), reflLen - 1)
            for src in 0..<reflCount { reflW[d * reflCount + src] = kReflWeights[d][src] }
        }
        for src in 0..<reflCount { reflSrcCh[src] = kReflSources[src] }
        reflHpA = Float(exp(-2 * Double.pi * 150.0 / self.sampleRate))
        reflLpA = Float(1 - exp(-2 * Double.pi * 5000.0 / self.sampleRate))

        update(config)
        sCenter = pCenter; sSurround = pSurroundGain; sHeight = pHeightGain
        sAmbient = pAmbient; sStrength = pStrength
        rebuildPhaseTables(pDecorr)

        // Prime the output FIFO with one window of silence: that IS the algorithmic
        // latency, and it guarantees process() can always satisfy its reader.
        outCount = N
    }

    deinit {
        func freePlanes(_ pp: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, _ count: Int) {
            for i in 0..<max(count, 1) { pp[i].deallocate() }
            pp.deallocate()
        }
        vDSP_destroy_fftsetup(setup)
        win.deallocate(); heightW.deallocate(); lfeW.deallocate()
        shapeSurroundBass.deallocate(); shapeSurroundFlat.deallocate()
        shapeHeightBass.deallocate(); shapeHeightFlat.deallocate()
        inL.deallocate(); inR.deallocate(); frame.deallocate()
        aRe.deallocate(); aIm.deallocate(); bRe.deallocate(); bIm.deallocate()
        pLL.deallocate(); pRR.deallocate(); pLRr.deallocate(); pLRi.deallocate()
        freePlanes(outRe, channels); freePlanes(outIm, channels)
        freePlanes(ola, channels); freePlanes(outFIFO, channels)
        freePlanes(phi, channels); freePlanes(phCos, channels); freePlanes(phSin, channels)
        freePlanes(frontPhi, 6)
        frontCosL.deallocate(); frontSinL.deallocate()
        frontCosR.deallocate(); frontSinR.deallocate(); sD.deallocate()
        binBand.deallocate(); bandPow.deallocate(); bandDRaw.deallocate(); sDBand.deallocate()
        freePlanes(reflDelay, max(reflCount, 1))
        reflW.deallocate(); reflTau.deallocate()
        reflSrcCh.deallocate(); reflDestCh.deallocate()
        reflHpZ.deallocate(); reflHpX.deallocate(); reflLpZ.deallocate()
    }

    /// Live parameter update (main thread). Layout / FFT size changes need a rebuild.
    func update(_ c: UpmixConfig) {
        pCenter = min(max(c.centerStrength, 0), 1.5)
        pSurroundGain = powf(10, min(max(c.surroundLevel, -24), 6) / 20)
        pHeightGain = powf(10, min(max(c.heightLevel, -24), 6) / 20)
        pDecorr = min(max(c.decorrelation, 0), 1)
        pAmbient = powf(10, min(max(c.ambientBias, -12), 12) / 20)
        pLFE = (c.lfeMode == .lowpass150)
        // The kernel selector must stay a Bool inside process(): comparing the
        // String-backed enum there would dereference heap storage on the RT thread.
        pNatural = (c.quality == .natural)
        pStrength = min(max(c.strength, 0), 1)
        pSpread = min(max(c.spread, 0), 1)
        pTransients = min(max(c.transients, 0), 1)
        pReflections = powf(10, min(max(c.reflectionsLevel, -24), 6) / 20)
        pBassManage = c.bassManagement
        pAutoLevel = c.autoLevel
        // Transient handling is a time constant, not a coefficient we can interpolate.
        alphaFast = exp(-(Float(hop) / Float(sampleRate))
                        / (0.030 - 0.025 * pTransients))
    }

    /// Algorithmic latency in samples (one analysis window).
    var latencySamples: Int { fftSize }

    // MARK: - RT entry point

    /// Consume `frames` of stereo and produce `frames` of `channels` planar output.
    func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>,
                 out: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        guard frames > 0 else { return }
        if frames > maxFrames || inCount + frames > inCap {
            // Never happens with a sane maxFrames; degrade to silence rather than scribble.
            for ch in 0..<channels { memset(out[ch], 0, frames * 4) }
            return
        }
        memcpy(inL + inCount, inLeft, frames * 4)
        memcpy(inR + inCount, inRight, frames * 4)
        inCount += frames

        while inCount >= fftSize && outCount + hop <= outCap {
            processFrame()
            let rest = inCount - hop
            memmove(inL, inL + hop, rest * 4)
            memmove(inR, inR + hop, rest * 4)
            inCount = rest
        }

        let n = min(frames, outCount)
        for ch in 0..<channels {
            memcpy(out[ch], outFIFO[ch], n * 4)
            if n < frames { memset(out[ch] + n, 0, (frames - n) * 4) }
            let rest = outCount - n
            if rest > 0 { memmove(outFIFO[ch], outFIFO[ch] + n, rest * 4) }
        }
        outCount -= n

        // Natural-kernel post-stages. Both work on the samples just emitted, so a block
        // boundary never changes what they see (the reflection delay lines are
        // sample-accurate). Order matters: the trim runs first, so the reflection layer
        // is built from — and is therefore consistent with — the levelled bed, and the
        // level invariant is measured on the ground layer alone.
        if pNatural {
            if pAutoLevel { levelStage(out: out, inLeft: inLeft, inRight: inRight, frames: n) }
            if reflDests > 0 { reflectionStage(out: out, frames: n) }
        }
    }

    // MARK: - One STFT frame

    private func processFrame() {
        if pNatural { processFrameNatural() } else { processFrameClassic() }
    }

    /// Analysis + synthesis scaffolding shared by both kernels.
    private func analyze() {
        let N = fftSize, H = half
        var splitA = DSPSplitComplex(realp: aRe, imagp: aIm)
        var splitB = DSPSplitComplex(realp: bRe, imagp: bIm)
        vDSP_vmul(inL, 1, win, 1, frame, 1, vDSP_Length(N))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: H) {
            vDSP_ctoz($0, 2, &splitA, 1, vDSP_Length(H))
        }
        vDSP_fft_zrip(setup, &splitA, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_vmul(inR, 1, win, 1, frame, 1, vDSP_Length(N))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: H) {
            vDSP_ctoz($0, 2, &splitB, 1, vDSP_Length(H))
        }
        vDSP_fft_zrip(setup, &splitB, 1, log2n, FFTDirection(FFT_FORWARD))
    }

    private func synthesize() {
        let N = fftSize, H = half
        for ch in 0..<channels {
            var sp = DSPSplitComplex(realp: outRe[ch], imagp: outIm[ch])
            vDSP_fft_zrip(setup, &sp, 1, log2n, FFTDirection(FFT_INVERSE))
            frame.withMemoryRebound(to: DSPComplex.self, capacity: H) {
                vDSP_ztoc(&sp, 1, $0, 2, vDSP_Length(H))
            }
            var s = scale
            vDSP_vsmul(frame, 1, &s, frame, 1, vDSP_Length(N))
            // synthesis window + overlap-add
            let o = ola[ch]
            vDSP_vma(frame, 1, win, 1, o, 1, o, 1, vDSP_Length(N))
            // The first hop samples are final: push them out and shift the tail down.
            memcpy(outFIFO[ch] + outCount, o, hop * 4)
            memmove(o, o + hop, (N - hop) * 4)
            memset(o + (N - hop), 0, hop * 4)
        }
        outCount += hop
    }

    // MARK: - Classic kernel (behaviour unchanged)

    private func processFrameClassic() {
        let H = half

        if tableDecorr != pDecorr { rebuildPhaseTables(pDecorr) }
        sCenter   += (1 - alphaSmooth) * (pCenter - sCenter)
        sSurround += (1 - alphaSmooth) * (pSurroundGain - sSurround)
        sHeight   += (1 - alphaSmooth) * (pHeightGain - sHeight)
        sAmbient  += (1 - alphaSmooth) * (pAmbient - sAmbient)

        analyze()

        // Packed real FFT: index 0 carries DC in realp and Nyquist in imagp.
        let dcL = aRe[0], nyqL = aIm[0]
        let dcR = bRe[0], nyqR = bIm[0]

        let a = alphaPowerClassic, ia = 1 - a
        let eps: Float = 1e-20
        let center = min(sCenter, 1.5)
        let ambientGain = sAmbient
        let sqrt2: Float = 1.414213562
        let twelve = (channels == kAtmos714Channels)

        var k = 1
        while k < H {
            let lr = aRe[k], li = aIm[k]
            let rr = bRe[k], ri = bIm[k]

            let ell = lr * lr + li * li
            let err = rr * rr + ri * ri
            let xr = lr * rr + li * ri          // Re(L · conj(R))
            let xi = li * rr - lr * ri          // Im(L · conj(R))

            pLL[k] = a * pLL[k] + ia * ell
            pRR[k] = a * pRR[k] + ia * err
            pLRr[k] = a * pLRr[k] + ia * xr
            pLRi[k] = a * pLRi[k] + ia * xi

            let cll = pLL[k], crr = pRR[k], cr = pLRr[k], ci = pLRi[k]
            var g2 = (cr * cr + ci * ci) / (cll * crr + eps)
            if g2 > 1 { g2 = 1 }
            // Out-of-phase content is room, not image: push it to the ambient side.
            if cr < 0 { g2 *= 0.25 }
            let beta = (cll - crr) / (cll + crr + eps)

            let gd = sqrtf(g2)
            let ga = sqrtf(1 - g2) * ambientGain

            // Direct part, re-panned L / C / R (constant power, energy preserving).
            let dlr = gd * lr, dli = gd * li
            let drr = gd * rr, dri = gd * ri
            let mr = 0.5 * (dlr + drr), mi = 0.5 * (dli + dri)
            let slr = dlr - mr, sli = dli - mi
            let srr = drr - mr, sri = dri - mi
            var c = 1 - abs(beta)
            if c < 0 { c = 0 }
            c = c * c * center
            if c > 1 { c = 1 }
            let oneMinusC = 1 - c

            outRe[chL][k] = slr + oneMinusC * mr;  outIm[chL][k] = sli + oneMinusC * mi
            outRe[chR][k] = srr + oneMinusC * mr;  outIm[chR][k] = sri + oneMinusC * mi
            outRe[chC][k] = sqrt2 * c * mr;        outIm[chC][k] = sqrt2 * c * mi

            // Ambient part, decorrelated into the surrounds (and heights in 7.1.4).
            let alr = ga * lr, ali = ga * li
            let arr = ga * rr, ari = ga * ri
            let gS = sSurround

            rotate(chLs, k, alr, ali, gS)
            rotate(chRs, k, arr, ari, gS)

            if twelve {
                rotate(chRls, k, alr, ali, gS * 0.7)
                rotate(chRrs, k, arr, ari, gS * 0.7)
                let wh = heightW[k] * sHeight
                if wh > 0 {
                    rotate(chVhl, k, alr, ali, wh)
                    rotate(chVhr, k, arr, ari, wh)
                    rotate(chLtr, k, alr, ali, wh * 0.7)
                    rotate(chRtr, k, arr, ari, wh * 0.7)
                } else {
                    outRe[chVhl][k] = 0; outIm[chVhl][k] = 0
                    outRe[chVhr][k] = 0; outIm[chVhr][k] = 0
                    outRe[chLtr][k] = 0; outIm[chLtr][k] = 0
                    outRe[chRtr][k] = 0; outIm[chRtr][k] = 0
                }
            }

            if pLFE {
                let w = lfeW[k]
                outRe[chLFE][k] = 0.5 * (lr + rr) * w
                outIm[chLFE][k] = 0.5 * (li + ri) * w
            } else {
                outRe[chLFE][k] = 0; outIm[chLFE][k] = 0
            }
            k += 1
        }

        // DC and Nyquist: real-valued, no decorrelation phase (rotating them would just
        // fold energy into the imaginary part that the packed format can't carry).
        writeRealBin(l: dcL, r: dcR, real: true)
        writeRealBin(l: nyqL, r: nyqR, real: false)

        synthesize()
    }

    // MARK: - Natural kernel

    private func processFrameNatural() {
        let H = half

        if tableDecorr != pDecorr { rebuildPhaseTables(pDecorr) }
        sCenter   += (1 - alphaSmooth) * (pCenter - sCenter)
        sSurround += (1 - alphaSmooth) * (pSurroundGain - sSurround)
        sHeight   += (1 - alphaSmooth) * (pHeightGain - sHeight)
        sAmbient  += (1 - alphaSmooth) * (pAmbient - sAmbient)
        sStrength += (1 - alphaSmooth) * (pStrength - sStrength)

        analyze()

        let dcL = aRe[0], nyqL = aIm[0]
        let dcR = bRe[0], nyqR = bIm[0]

        let a = alphaPower, ia = 1 - a
        let strength = min(max(sStrength, 0), 1)
        let spread = min(max(pSpread, 0), 1)
        let shpS = pBassManage ? shapeSurroundBass : shapeSurroundFlat
        let shpH = pBassManage ? shapeHeightBass : shapeHeightFlat
        let twelve = (channels == kAtmos714Channels)

        // Transient gate: an onset briefly closes the sends, so an attack stays in the
        // front instead of being smeared into the rear channels. The detector runs on the
        // frame power below and takes effect on the next frame (one hop of lookahead,
        // which the STFT's own latency makes free).
        let gate: Float = (onsetHold > 0 && pTransients > 0) ? 0.15 : 1

        // The spectra are scratch that persists between frames: channels nobody writes
        // this frame would replay stale bins, so they are zeroed explicitly.
        if twelve {
            memset(outRe[chRls], 0, H * 4); memset(outIm[chRls], 0, H * 4)
            memset(outRe[chRrs], 0, H * 4); memset(outIm[chRrs], 0, H * 4)
            memset(outRe[chLtr], 0, H * 4); memset(outIm[chLtr], 0, H * 4)
            memset(outRe[chRtr], 0, H * 4); memset(outIm[chRtr], 0, H * 4)
        }

        // Pass 1: cross-spectra and the per-bin diffuseness, accumulated into bands.
        memset(bandPow, 0, bandCount * 4)
        memset(bandDRaw, 0, bandCount * 4)
        var framePow: Float = 0
        var k = 1
        while k < H {
            let lr = aRe[k], li = aIm[k]
            let rr = bRe[k], ri = bIm[k]
            framePow += lr * lr + li * li + rr * rr + ri * ri
            naturalAnalyzeBin(k, lr, li, rr, ri, a, ia)
            k += 1
        }

        // Aggregate and smooth per band. A band with no power this frame (a gap, or a
        // band the material never excites) keeps its previous value.
        var b = 0
        while b < bandCount {
            let p = bandPow[b]
            if p > 1e-20 {
                let mean = bandDRaw[b] / p
                let prev = sDBand[b]
                sDBand[b] = mean < prev ? (alphaFast * prev + (1 - alphaFast) * mean)
                                        : (alphaSlow * prev + (1 - alphaSlow) * mean)
            }
            b += 1
        }

        // Pass 2: render. The per-bin spectra are still in aRe/aIm/bRe/bIm and the
        // smoothed cross-spectrum is in pLL/pRR/pLRr, so the analysis does not have to be
        // stored twice.
        k = 1
        while k < H {
            naturalRenderBin(k, gate, strength, spread, shpS, shpH, twelve)
            k += 1
        }

        naturalRealBin(l: dcL, r: dcR, real: true, shpS: shpS, shpH: shpH,
                       twelve: twelve, strength: strength, spread: spread)
        naturalRealBin(l: nyqL, r: nyqR, real: false, shpS: shpS, shpH: shpH,
                       twelve: twelve, strength: strength, spread: spread)

        if pTransients > 0 {
            if onsetHold > 0 { onsetHold -= 1 }
            let ratio = framePow / (powSlow + 1e-20)
            if ratio > 1.6 { onsetHold = 6 }     // +2 dB in one frame: an onset
        }
        powSlow = 0.8 * powSlow + 0.2 * framePow

        synthesize()
    }

    /// Pass 1 of the natural kernel: cross-spectrum smoothing plus the per-bin
    /// diffuseness estimate, accumulated into the critical bands. Nothing is written to
    /// the output spectra here — the band decision has to be complete before any bin can
    /// be rendered.
    @inline(__always)
    private func naturalAnalyzeBin(_ k: Int, _ lRe: Float, _ lIm: Float,
                                   _ rRe: Float, _ rIm: Float, _ a: Float, _ ia: Float) {
        let eps: Float = 1e-20

        let ell = lRe * lRe + lIm * lIm
        let err = rRe * rRe + rIm * rIm
        let xr = lRe * rRe + lIm * rIm
        let xi = lIm * rRe - lRe * rIm

        pLL[k] = a * pLL[k] + ia * ell
        pRR[k] = a * pRR[k] + ia * err
        pLRr[k] = a * pLRr[k] + ia * xr
        pLRi[k] = a * pLRi[k] + ia * xi

        let cll = pLL[k], crr = pRR[k], cr = pLRr[k], ci = pLRi[k]

        var g2 = (cr * cr + ci * ci) / (cll * crr + eps)
        g2 = (g2 - coherenceBias) * biasInv
        if g2 < 0 { g2 = 0 } else if g2 > 1 { g2 = 1 }

        // Level similarity — the criterion the classic estimator omits. It is ~0 for a
        // source panned to one side, so hard-panned direct sound cannot be mistaken for
        // ambience however low its coherence happens to be.
        let lsim = 2 * sqrtf(cll * crr) / (cll + crr + eps)
        let dRaw = (1 - g2) * lsim * lsim * lsim

        // Asymmetric smoothing: open fast (transients and entrances stay direct), close
        // slowly (a reverb tail is not yanked back into the front between frames).
        let dPrev = sD[k]
        sD[k] = dRaw < dPrev ? (alphaFast * dPrev + (1 - alphaFast) * dRaw)
                             : (alphaSlow * dPrev + (1 - alphaSlow) * dRaw)

        // Power-weighted band accumulation: the band decision follows what is audible in
        // the band, not the bin count.
        let weight = cll + crr
        let b = binBand[k]
        bandPow[b] += weight
        bandDRaw[b] += weight * dRaw
    }

    /// Pass 2: one bin of the natural kernel. Everything here is power-exact: the direct
    /// mask, the front-ambience mask and the send mask sum to one in power, and the
    /// centre law is the constant-power three-speaker law, so no position or mask value
    /// dips.
    @inline(__always)
    private func naturalRenderBin(_ k: Int, _ gate: Float, _ strength: Float,
                                  _ spread: Float, _ shpS: UnsafePointer<Float>,
                                  _ shpH: UnsafePointer<Float>, _ twelve: Bool) {
        let eps: Float = 1e-20
        let lRe = aRe[k], lIm = aIm[k]
        let rRe = bRe[k], rIm = bIm[k]
        let cll = pLL[k], crr = pRR[k], cr = pLRr[k]

        // Critically-aggregated decision, plus a quarter of the (already smoothed)
        // per-bin estimate so a single very direct bin inside an ambient band is not
        // swallowed whole.
        let bandD = sDBand[binBand[k]]
        var D = bandD + bandMix * (sD[k] - bandD)
        if D < 0 { D = 0 } else if D > 1 { D = 1 }
        D = D * gate * strength
        if D < 0 { D = 0 } else if D > 1 { D = 1 }

        let gd = sqrtf(1 - D)                 // direct / primary mask
        let dSend = D * spread
        let gSend = sqrtf(dSend) * sAmbient   // to the surrounds and heights
        let gFront = sqrtf(D - dSend)         // the rest stays in front, decorrelated

        let beta = (cll - crr) / (cll + crr + eps)
        var ab = beta < 0 ? -beta : beta
        if ab > 0.999 { ab = 0.999 }
        let oneMinus = 1 - ab
        var c = oneMinus * oneMinus * sCenter * strength
        if c < 0 { c = 0 } else if c > 1 { c = 1 }
        var alpha = 1 - c
        // γ = √(2(1−α²)) is the gain that makes L' = α·m + s, R' = α·m − s, C = γ·m
        // energy-exact for every α. The classic kernel used γ = √2·c, which is only
        // correct at the endpoints — that is the 2.9 dB W-shaped dip across the image.
        var gamma = sqrtf(2 * (1 - alpha * alpha))
        // Anti-phase content has no stable phantom image: keep it in the front pair
        // rather than letting β claim a position it does not have.
        if cr < 0 { alpha = 1; gamma = 0 }

        let mRe = 0.5 * (lRe + rRe), mIm = 0.5 * (lIm + rIm)
        let sRe = 0.5 * (lRe - rRe), sIm = 0.5 * (lIm - rIm)
        let ga = gd * alpha

        // L / R: direct part, plus a decorrelated copy of the ambience that stays in front
        let fc0 = frontCosL[k], fs0 = frontSinL[k]
        outRe[chL][k] = ga * mRe + gd * sRe + gFront * (lRe * fc0 - lIm * fs0)
        outIm[chL][k] = ga * mIm + gd * sIm + gFront * (lRe * fs0 + lIm * fc0)
        let fc1 = frontCosR[k], fs1 = frontSinR[k]
        outRe[chR][k] = ga * mRe - gd * sRe + gFront * (rRe * fc1 - rIm * fs1)
        outIm[chR][k] = ga * mIm - gd * sIm + gFront * (rRe * fs1 + rIm * fc1)

        let gC = gd * gamma
        outRe[chC][k] = gC * mRe
        outIm[chC][k] = gC * mIm

        // Surround sends, bass-managed and decorrelated
        let gLS = gSend * sSurround * shpS[k]
        rotateSet(chLs, k, lRe, lIm, gLS)
        rotateSet(chRs, k, rRe, rIm, gLS)

        if twelve {
            let gH = gSend * sHeight * shpH[k]
            rotateSet(chVhl, k, lRe, lIm, gH)
            rotateSet(chVhr, k, rRe, rIm, gH)
        }

        if pLFE {
            let w = lfeW[k]
            outRe[chLFE][k] = 0.5 * (lRe + rRe) * w
            outIm[chLFE][k] = 0.5 * (lIm + rIm) * w
        } else {
            outRe[chLFE][k] = 0
            outIm[chLFE][k] = 0
        }
    }

    /// DC (real == true) or Nyquist (real == false) for the natural kernel.
    private func naturalRealBin(l: Float, r: Float, real: Bool,
                                shpS: UnsafePointer<Float>, shpH: UnsafePointer<Float>,
                                twelve: Bool, strength: Float, spread: Float) {
        let k = real ? 0 : half
        let eps: Float = 1e-20
        let a = alphaPower, ia = 1 - a

        let ell = l * l, err = r * r, xr = l * r
        pLL[k] = a * pLL[k] + ia * ell
        pRR[k] = a * pRR[k] + ia * err
        pLRr[k] = a * pLRr[k] + ia * xr
        let cll = pLL[k], crr = pRR[k], cr = pLRr[k]

        var g2 = (cr * cr) / (cll * crr + eps)
        g2 = (g2 - coherenceBias) * biasInv
        if g2 < 0 { g2 = 0 } else if g2 > 1 { g2 = 1 }
        let lsim = 2 * sqrtf(cll * crr) / (cll + crr + eps)
        let dRaw = (1 - g2) * lsim * lsim * lsim
        let dPrev = sD[k]
        let d = dRaw < dPrev ? (alphaFast * dPrev + (1 - alphaFast) * dRaw)
                             : (alphaSlow * dPrev + (1 - alphaSlow) * dRaw)
        sD[k] = d

        var D = d * strength
        if D < 0 { D = 0 } else if D > 1 { D = 1 }
        let gd = sqrtf(1 - D)
        let dSend = D * spread
        let gSend = sqrtf(dSend) * sAmbient
        let gFront = sqrtf(D - dSend)

        let beta = (cll - crr) / (cll + crr + eps)
        var ab = beta < 0 ? -beta : beta
        if ab > 0.999 { ab = 0.999 }
        let oneMinus = 1 - ab
        var c = oneMinus * oneMinus * sCenter * strength
        if c < 0 { c = 0 } else if c > 1 { c = 1 }
        var alpha = 1 - c
        var gamma = sqrtf(2 * (1 - alpha * alpha))
        if cr < 0 { alpha = 1; gamma = 0 }

        let m = 0.5 * (l + r), sd = 0.5 * (l - r)

        func put(_ ch: Int, _ v: Float) {
            if real { outRe[ch][0] = v } else { outIm[ch][0] = v }
        }
        // No phase rotation at DC/Nyquist: the packed format carries one real value per
        // slot, so rotating would fold the energy into a part nothing reads.
        put(chL, gd * (alpha * m + sd) + gFront * l)
        put(chR, gd * (alpha * m - sd) + gFront * r)
        put(chC, gd * gamma * m)
        put(chLs, gSend * sSurround * shpS[k] * l)
        put(chRs, gSend * sSurround * shpS[k] * r)
        if twelve {
            put(chVhl, gSend * sHeight * shpH[k] * l)
            put(chVhr, gSend * sHeight * shpH[k] * r)
            put(chRls, 0); put(chRrs, 0); put(chLtr, 0); put(chRtr, 0)
        }
        put(chLFE, pLFE ? 0.5 * (l + r) * lfeW[k] : 0)
    }

    // MARK: - Post-stages

    /// Early-reflection layer: delayed, high-passed, HF-trimmed copies of the ground
    /// channels, cross-mixed by adjacency. It runs on the emitted time-domain samples,
    /// not on STFT bins — a phase ramp inside the STFT would wrap the analysis window and
    /// turn an 11 ms reflection into a pre-echo.
    private func reflectionStage(out: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
                                 frames: Int) {
        let gain = pReflections * sHeight * min(max(sStrength, 0), 1)
        if gain == 0 || frames <= 0 { return }
        var w = reflIdx
        var i = 0
        while i < frames {
            var src = 0
            while src < reflCount {
                let x = out[reflSrcCh[src]][i]
                // high-pass first (the reflection layer carries no bass), then a low-shelf
                // HF trim of the high-passed signal — bounded to about unit gain
                let hz = reflHpA * (reflHpZ[src] + x - reflHpX[src])
                reflHpX[src] = x
                reflHpZ[src] = hz
                reflLpZ[src] += reflLpA * (hz - reflLpZ[src])
                reflDelay[src][w] = 1.10 * (0.6 * hz + 0.4 * reflLpZ[src])
                src += 1
            }
            var d = 0
            while d < reflDests {
                let base = d * reflCount
                let tap = (w - reflTau[d]) & reflMask
                var acc: Float = 0
                var q = 0
                while q < reflCount {
                    let wt = reflW[base + q]
                    if wt != 0 { acc += wt * reflDelay[q][tap] }
                    q += 1
                }
                out[reflDestCh[d]][i] += gain * acc
                d += 1
            }
            w = (w + 1) & reflMask
            i += 1
        }
        reflIdx = w
    }

    /// Slow bed-domain loudness trim: a one-block-delayed AGC that level-matches upmix
    /// on/off. It is a trim, not a loudness model — the sends are diffuse, so the bed
    /// power sum over-estimates what they contribute at the eardrum.
    private func levelStage(out: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
                            inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>,
                            frames: Int) {
        if frames <= 0 { return }
        var inPow: Float = 0
        var i = 0
        while i < frames {
            let l = inLeft[i], r = inRight[i]
            inPow += l * l + r * r
            i += 1
        }
        let g = sLevelGain
        var outPow: Float = 0
        for ch in 0..<channels {
            let p = out[ch]
            var j = 0
            while j < frames {
                p[j] *= g
                outPow += p[j] * p[j]
                j += 1
            }
        }
        if outPow > 1e-12 && inPow > 1e-12 {
            var target = g * sqrtf(inPow / outPow)
            if target < 0.5 { target = 0.5 } else if target > 2 { target = 2 }
            // Per-block coefficient for a 2 s time constant: no libm on the RT thread,
            // and at most ~0.05 dB of gain movement per 512-sample block.
            var k = Float(frames) / (2.0 * Float(sampleRate))
            if k > 1 { k = 1 }
            sLevelGain = g + k * (target - g)
        }
    }

    // MARK: - Helpers

    /// Ambient bin → one surround/height channel with its fixed decorrelation phase.
    @inline(__always)
    private func rotate(_ ch: Int, _ k: Int, _ re: Float, _ im: Float, _ gain: Float) {
        let cs = phCos[ch][k], sn = phSin[ch][k]
        outRe[ch][k] = gain * (re * cs - im * sn)
        outIm[ch][k] = gain * (re * sn + im * cs)
    }

    /// Same rotation, used where every destination is written by exactly one source.
    @inline(__always)
    private func rotateSet(_ ch: Int, _ k: Int, _ re: Float, _ im: Float, _ gain: Float) {
        rotate(ch, k, re, im, gain)
    }

    /// DC (real == true) or Nyquist (real == false) — both live in bin 0 of the packed
    /// layout (realp / imagp respectively). Classic kernel.
    @inline(__always)
    private func writeRealBin(l: Float, r: Float, real: Bool) {
        let k = real ? 0 : half
        let ell = l * l, err = r * r, xr = l * r
        let a = alphaPowerClassic, ia = 1 - a
        pLL[k] = a * pLL[k] + ia * ell
        pRR[k] = a * pRR[k] + ia * err
        pLRr[k] = a * pLRr[k] + ia * xr
        let cll = pLL[k], crr = pRR[k], cr = pLRr[k]
        var g2 = (cr * cr) / (cll * crr + 1e-20)
        if g2 > 1 { g2 = 1 }
        if cr < 0 { g2 *= 0.25 }
        let beta = (cll - crr) / (cll + crr + 1e-20)
        let gd = sqrtf(g2), ga = sqrtf(1 - g2) * sAmbient
        let dl = gd * l, dr = gd * r
        let m = 0.5 * (dl + dr)
        var c = 1 - abs(beta); if c < 0 { c = 0 }
        c = c * c * sCenter; if c > 1 { c = 1 }

        func put(_ ch: Int, _ v: Float) {
            if real { outRe[ch][0] = v } else { outIm[ch][0] = v }
        }
        put(chL, (dl - m) + (1 - c) * m)
        put(chR, (dr - m) + (1 - c) * m)
        put(chC, 1.414213562 * c * m)
        put(chLs, ga * l * sSurround)
        put(chRs, ga * r * sSurround)
        if channels == kAtmos714Channels {
            put(chRls, ga * l * sSurround * 0.7)
            put(chRrs, ga * r * sSurround * 0.7)
            let wh = heightW[k] * sHeight
            put(chVhl, ga * l * wh); put(chVhr, ga * r * wh)
            put(chLtr, ga * l * wh * 0.7); put(chRtr, ga * r * wh * 0.7)
        }
        put(chLFE, pLFE ? 0.5 * (l + r) * lfeW[k] : 0)
    }

    /// cos/sin of φ·decorrelation, recomputed only when the amount actually changes
    /// (pure arithmetic — safe to do on the RT thread, a few thousand trig calls, once).
    private func rebuildPhaseTables(_ d: Float) {
        for ch in 0..<channels {
            let src = phi[ch], cp = phCos[ch], sp = phSin[ch]
            var k = 0
            while k <= half {
                let p = src[k] * d
                cp[k] = cosf(p)
                sp[k] = sinf(p)
                k += 1
            }
        }
        // Front-ambience curves: channels 4 and 5 of the gentler table (0…3 are coherent
        // by construction, which is what makes them usable as front channels here).
        let srcL = frontPhi[4], srcR = frontPhi[5]
        frontCosL[0] = 1; frontSinL[0] = 0
        frontCosR[0] = 1; frontSinR[0] = 0
        frontCosL[half] = 1; frontSinL[half] = 0
        frontCosR[half] = 1; frontSinR[half] = 0
        var k = 1
        while k < half {
            let pL = srcL[k] * d
            let pR = srcR[k] * d
            frontCosL[k] = cosf(pL); frontSinL[k] = sinf(pL)
            frontCosR[k] = cosf(pR); frontSinR[k] = sinf(pR)
            k += 1
        }
        tableDecorr = d
    }
}
