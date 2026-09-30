// SpatialEngine/STFTUpmixer.swift — 2 → 6/12 channel upmix by direct/ambient separation
// in the STFT domain (§4 of the spec).
//
// Per bin we estimate the smoothed cross-spectrum of L and R. Coherence γ² tells us how
// much of that bin is a phantom image (direct sound) versus room/reverb (ambience);
// the panning index β tells us where that image sits. The direct part is re-panned with
// a constant-power L/C/R law, the ambient part is decorrelated and sent to the surrounds
// (and, in 7.1.4, to the heights with a high-frequency bias). The spatial mixer then
// renders those virtual speakers binaurally.
//
// RT contract: every buffer and FFT setup is allocated in init and freed in deinit;
// process() allocates nothing, takes no locks and calls no Swift runtime entry points.

import Accelerate
import Foundation

// Atmos_7_1_4 bus order: 0 L, 1 R, 2 C, 3 LFE, 4 Ls, 5 Rs, 6 Rls, 7 Rrs,
//                        8 Vhl, 9 Vhr, 10 Ltr, 11 Rtr
private let chL = 0, chR = 1, chC = 2, chLFE = 3, chLs = 4, chRs = 5
private let chRls = 6, chRrs = 7, chVhl = 8, chVhr = 9, chLtr = 10, chRtr = 11

final class STFTUpmixer {
    let channels: Int          // 6 (5.1) or 12 (7.1.4)
    let fftSize: Int
    let hop: Int
    private let half: Int      // fftSize / 2 — bins 1…half-1 are complex; 0 = DC, half = Nyquist
    private let sampleRate: Double
    private let maxFrames: Int

    // FFT
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    // Windows / weights
    private let win: UnsafeMutablePointer<Float>          // √Hann, fftSize
    private let heightW: UnsafeMutablePointer<Float>      // half+1
    private let lfeW: UnsafeMutablePointer<Float>         // half+1

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
    private var tableDecorr: Float = -1

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

    private let alphaSmooth: Float      // parameter smoothing coefficient
    private let alphaPower: Float       // cross-spectrum smoothing (τ = 50 ms)
    private let scale: Float            // FFT round-trip + WOLA normalization

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
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        func allocPlanes(_ count: Int, _ n: Int) -> UnsafeMutablePointer<UnsafeMutablePointer<Float>> {
            let pp = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: count)
            for i in 0..<count { pp[i] = alloc(n) }
            return pp
        }

        win = alloc(N)
        heightW = alloc(H + 1)
        lfeW = alloc(H + 1)
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

        // Every stored property must be set before self is usable below.
        let hopSeconds = Float(hop) / Float(self.sampleRate)
        alphaPower = exp(-hopSeconds / 0.050)      // cross-spectrum τ = 50 ms
        alphaSmooth = exp(-hopSeconds / 0.030)     // parameter smoothing τ = 30 ms
        // vDSP real FFT: forward is 2× the DFT, inverse is N× the IDFT → 1/(2N).
        // √Hann at hop = N/4 overlap-adds to 1.5 → another 1/1.5.
        scale = 1.0 / (2.0 * Float(N) * 1.5)

        // √Hann: applied on both analysis and synthesis, COLA-exact at hop = N/4.
        for i in 0..<N {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(N))
            win[i] = Float(sqrt(w))
        }
        // Height send: nothing below 2 kHz, full above 8 kHz (Auro-Matic-like).
        // LFE: flat to 120 Hz, cosine roll-off to 180 Hz.
        let df = self.sampleRate / Double(N)
        for k in 0...H {
            let f = Double(k) * df
            if f < 2000 { heightW[k] = 0 }
            else if f < 8000 { heightW[k] = Float(log2(f / 2000) / 2.0) }
            else { heightW[k] = 1 }
            if f < 120 { lfeW[k] = 1 }
            else if f < 180 { lfeW[k] = Float(0.5 + 0.5 * cos(Double.pi * (f - 120) / 60)) }
            else { lfeW[k] = 0 }
        }

        // Bounded-group-delay decorrelation phases (§4.3-7).
        Decorrelator.fill(phi: phi, channels: channels, bins: H + 1,
                          sampleRate: self.sampleRate, fftSize: N)

        update(config)
        sCenter = pCenter; sSurround = pSurroundGain; sHeight = pHeightGain; sAmbient = pAmbient
        rebuildPhaseTables(pDecorr)

        // Prime the output FIFO with one window of silence: that IS the algorithmic
        // latency, and it guarantees process() can always satisfy its reader.
        outCount = N
    }

    deinit {
        func freePlanes(_ pp: UnsafeMutablePointer<UnsafeMutablePointer<Float>>) {
            for i in 0..<channels { pp[i].deallocate() }
            pp.deallocate()
        }
        vDSP_destroy_fftsetup(setup)
        win.deallocate(); heightW.deallocate(); lfeW.deallocate()
        inL.deallocate(); inR.deallocate(); frame.deallocate()
        aRe.deallocate(); aIm.deallocate(); bRe.deallocate(); bIm.deallocate()
        pLL.deallocate(); pRR.deallocate(); pLRr.deallocate(); pLRi.deallocate()
        freePlanes(outRe); freePlanes(outIm); freePlanes(ola); freePlanes(outFIFO)
        freePlanes(phi); freePlanes(phCos); freePlanes(phSin)
    }

    /// Live parameter update (main thread). Layout / FFT size changes need a rebuild.
    func update(_ c: UpmixConfig) {
        pCenter = min(max(c.centerStrength, 0), 1.5)
        pSurroundGain = powf(10, min(max(c.surroundLevel, -24), 6) / 20)
        pHeightGain = powf(10, min(max(c.heightLevel, -24), 6) / 20)
        pDecorr = min(max(c.decorrelation, 0), 1)
        pAmbient = powf(10, min(max(c.ambientBias, -12), 12) / 20)
        pLFE = (c.lfeMode == .lowpass150)
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
    }

    // MARK: - One STFT frame

    private func processFrame() {
        let N = fftSize, H = half

        if tableDecorr != pDecorr { rebuildPhaseTables(pDecorr) }
        sCenter   += (1 - alphaSmooth) * (pCenter - sCenter)
        sSurround += (1 - alphaSmooth) * (pSurroundGain - sSurround)
        sHeight   += (1 - alphaSmooth) * (pHeightGain - sHeight)
        sAmbient  += (1 - alphaSmooth) * (pAmbient - sAmbient)

        // --- analysis ------------------------------------------------------
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

        // Packed real FFT: index 0 carries DC in realp and Nyquist in imagp.
        let dcL = aRe[0], nyqL = aIm[0]
        let dcR = bRe[0], nyqR = bIm[0]

        let a = alphaPower, ia = 1 - a
        let eps: Float = 1e-20
        let center = min(sCenter, 1.5)
        let ambientGain = sAmbient
        let sqrt2: Float = 1.414213562

        let twelve = (channels == kAtmos714Channels)

        // --- per-bin decomposition ----------------------------------------
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

        // --- synthesis ------------------------------------------------------
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

    /// Ambient bin → one surround/height channel, with its fixed decorrelation phase.
    @inline(__always)
    private func rotate(_ ch: Int, _ k: Int, _ re: Float, _ im: Float, _ gain: Float) {
        let cs = phCos[ch][k], sn = phSin[ch][k]
        outRe[ch][k] = gain * (re * cs - im * sn)
        outIm[ch][k] = gain * (re * sn + im * cs)
    }

    /// DC (real == true) or Nyquist (real == false) — both live in bin 0 of the packed
    /// layout (realp / imagp respectively).
    @inline(__always)
    private func writeRealBin(l: Float, r: Float, real: Bool) {
        let k = real ? 0 : half
        let ell = l * l, err = r * r, xr = l * r
        let a = alphaPower, ia = 1 - a
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
    /// (pure arithmetic — safe to do on the RT thread, ~4 k trig calls, once).
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
        tableDecorr = d
    }
}
