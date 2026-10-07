#!/usr/bin/env python3
"""upmix-lab — objective + audible A/B bench for atmos-control's STFT upmixer.

Why this exists
---------------
`Sources/SpatialEngine/STFTUpmixer.swift` is a per-bin primary/ambient extractor
(Avendano & Jot, 2002).  A DSP algorithm of that shape cannot be judged by reading
it: the artefacts that make an upmixer sound "cheap" next to Auro-Matic / Apple's
Spatialize-Stereo / Sonos TV Audio Swap are *level* and *masking* behaviour that only
shows up when you run a signal through it and measure.

This script is a faithful NumPy port of the Swift kernel (`KernelV1`), a prototype of
the proposed kernel (`KernelV2`), and a set of measurements + listening files:

    python3 upmix_lab.py --all
    python3 upmix_lab.py --compare           # metrics only, fast
    python3 upmix_lab.py --wav               # listening files into out/
    python3 upmix-lab.py --input mysong.wav  # your own material

Nothing here runs on the audio thread; it is an offline analysis tool.  It is
deliberately dependency-free (numpy only) so it runs on the same Mac as the app.

Metrics
-------
  pan       : constant-power pan sweep -> output level vs input level (dB).
              A correct upmixer is flat; the current kernel dips ~2.7 dB mid-pan.
  hardpan   : hard-panned coherent source -> how much of it leaks into the surrounds.
  center    : centre-panned source -> centre-channel share and total energy.
  diffuse   : fully decorrelated input -> surround energy share, front/surround
              correlation (should be ~0), and the binaural inter-aural coherence.
  transient : click train -> attack level in the surrounds (should stay low).
  mask      : per-bin send-gain wobble inside a 1/3-octave band (the "shh" on sibilants
              and cymbals); band-aggregated decisions should flatten it.
  null      : strength = 0 -> the bed must equal the input (bit-level passthrough).
  binaural  : round-trip through a cheap spherical-head HRTF: eardrum spectrum
              deviation vs plain stereo, and IACC (lower = more enveloping).
"""

from __future__ import annotations

import argparse
import math
import os
import struct
import sys
import wave

import numpy as np

# ---------------------------------------------------------------------------
# Layout constants (must match SpatialEngine/Audio.swift)
# ---------------------------------------------------------------------------
CH_L, CH_R, CH_C, CH_LFE, CH_LS, CH_RS = 0, 1, 2, 3, 4, 5
CH_RLS, CH_RRS, CH_VHL, CH_VHR, CH_LTR, CH_RTR = 6, 7, 8, 9, 10, 11

AZ_714 = np.array([-30, 30, 0, 0, -110, 110, -145, 145, -45, 45, -135, 135], dtype=float)
EL_714 = np.array([0, 0, 0, 0, 0, 0, 0, 0, 45, 45, 45, 45], dtype=float)

SR = 48_000


# ---------------------------------------------------------------------------
# STFT core
# ---------------------------------------------------------------------------
class STFT:
    """sqrt-Hann analysis/synthesis at 75 % overlap, exactly as the Swift code."""

    def __init__(self, n: int = 2048, sr: int = SR):
        self.n = n
        self.hop = n // 4
        self.half = n // 2
        self.sr = sr
        i = np.arange(n)
        self.win = np.sqrt(0.5 - 0.5 * np.cos(2 * np.pi * i / n))
        # sum of win^2 (= Hann) over hops of n/4 is exactly 2.0: four windows overlap
        # and the cosine terms cancel.  The Swift kernel divides by 1.5 instead, which
        # makes its output +2.5 dB hot relative to its input (measured, not guessed).
        self.cola = 2.0
        self.df = sr / n  # Hz per bin

    def frames(self, x: np.ndarray):
        n, hop = self.n, self.hop
        count = max(0, (len(x) - n) // hop + 1)
        for i in range(count):
            yield i, x[i * hop:i * hop + n]


# ---------------------------------------------------------------------------
# Decorrelator (port of Sources/SpatialEngine/Decorrelator.swift)
# ---------------------------------------------------------------------------
class SplitMix64:
    def __init__(self, seed: int):
        self.s = seed & 0xFFFF_FFFF_FFFF_FFFF

    def next(self) -> int:
        self.s = (self.s + 0x9E37_79B9_7F4A_7C15) & 0xFFFF_FFFF_FFFF_FFFF
        z = self.s
        z = ((z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9) & 0xFFFF_FFFF_FFFF_FFFF
        z = ((z ^ (z >> 27)) * 0x94D0_49BB_1331_11EB) & 0xFFFF_FFFF_FFFF_FFFF
        return z ^ (z >> 31)

    def unit(self) -> float:
        return (self.next() >> 40) / float(1 << 24)


def decorrelator_phase(channels: int, bins: int, sr: int, n: int,
                       tau_max: float = 0.0025, segment: int = 8) -> np.ndarray:
    """phi[ch, k] — bounded-group-delay phase curves (ch <= 3 stay coherent)."""
    rng = SplitMix64(0x5EED_A7_C0FFEE)
    df = sr / n
    phi = np.zeros((channels, bins))
    for ch in range(channels):
        if ch <= 3:
            continue
        points = bins // segment + 2
        taus = (np.array([rng.unit() for _ in range(points)]) * 2 - 1) * tau_max
        acc = 0.0
        for k in range(bins):
            pos = k / segment
            i0 = int(pos)
            frac = pos - i0
            tau = taus[i0] + (taus[min(i0 + 1, points - 1)] - taus[i0]) * frac
            acc -= 2 * math.pi * df * tau
            f = k * df
            w = 0.0 if f <= 100 else (1.0 if f >= 300 else (f - 100) / 200)
            phi[ch, k] = acc * w
    return phi


# ---------------------------------------------------------------------------
# Kernel V1 — faithful port of the current STFTUpmixer.swift
# ---------------------------------------------------------------------------
class KernelV1:
    """Current released kernel.  Kept bit-reasonable so the A/B is honest."""

    name = "v1 (current)"

    def __init__(self, sr: int = SR, n: int = 2048, channels: int = 6,
                 center=1.0, surround_db=0.0, height_db=-6.0, decorr=0.7,
                 ambient_db=0.0, lfe=False, probe: bool = False):
        self.stft = STFT(n, sr)
        self.sr, self.n, self.hop, self.half = sr, n, n // 4, n // 2
        self.channels = channels
        self.center = center
        self.g_surround = 10 ** (surround_db / 20)
        self.g_height = 10 ** (height_db / 20)
        self.decorr = decorr
        self.g_ambient = 10 ** (ambient_db / 20)
        self.lfe = lfe
        self.probe = probe            # record the shape-free send gain per bin/frame
        self.probe_send = []
        a = math.exp(-(self.hop / sr) / 0.050)
        self.alpha_pow = a
        # windows
        half = self.half
        df = sr / n
        k = np.arange(half + 1)
        f = k * df
        self.heightW = np.where(f < 2000, 0.0,
                                np.where(f < 8000, np.log2(np.maximum(f, 1e-9) / 2000) / 2.0, 1.0))
        self.lfeW = np.where(f < 120, 1.0,
                             np.where(f < 180, 0.5 + 0.5 * np.cos(np.pi * (f - 120) / 60), 0.0))
        self.heightW[half] = self.heightW[half]
        self.phi = decorrelator_phase(channels, half + 1, sr, n)
        self.ph = np.exp(1j * self.phi * decorr)

    def run(self, L: np.ndarray, R: np.ndarray):
        st = self.stft
        n, hop, half = self.n, self.hop, self.half
        if self.probe:
            self.probe_send = []
        out = np.zeros((self.channels, len(L) + n))
        pLL = np.zeros(half + 1)
        pRR = np.zeros(half + 1)
        pLR = np.zeros(half + 1, dtype=complex)
        a = self.alpha_pow
        eps = 1e-20
        sqrt2 = math.sqrt(2.0)
        twelve = self.channels == 12
        frame = np.zeros(n)
        # algorithmic latency: prime with one window of silence
        pad = np.concatenate([np.zeros(n), L]), np.concatenate([np.zeros(n), R])
        Lp, Rp = pad
        for _, s in st.frames(Lp):
            pass
        count = (len(Lp) - n) // hop + 1
        for i in range(count):
            l = Lp[i * hop:i * hop + n] * st.win
            r = Rp[i * hop:i * hop + n] * st.win
            A = np.fft.rfft(l)
            B = np.fft.rfft(r)
            # packed real-FFT bookkeeping is irrelevant to the maths
            ell = np.abs(A) ** 2
            err = np.abs(B) ** 2
            x = A * np.conj(B)
            pLL = a * pLL + (1 - a) * ell
            pRR = a * pRR + (1 - a) * err
            pLR = a * pLR + (1 - a) * x
            g2 = np.clip((np.abs(pLR) ** 2) / (pLL * pRR + eps), 0, 1)
            g2 = np.where(pLR.real < 0, g2 * 0.25, g2)
            beta = (pLL - pRR) / (pLL + pRR + eps)
            gd = np.sqrt(g2)
            ga = np.sqrt(1 - g2) * self.g_ambient
            if self.probe:
                self.probe_send.append(20 * np.log10(np.maximum(ga, 1e-6)))
            # direct L/C/R
            dl, dr = gd * A, gd * B
            m = 0.5 * (dl + dr)
            sl, sr_ = dl - m, dr - m
            c = np.clip(1 - np.abs(beta), 0, 1) ** 2 * self.center
            c = np.clip(c, 0, 1)
            spec = np.zeros((self.channels, half + 1), dtype=complex)
            spec[CH_L] = sl + (1 - c) * m
            spec[CH_R] = sr_ + (1 - c) * m
            spec[CH_C] = sqrt2 * c * m
            # ambient
            al, ar = ga * A, ga * B
            spec[CH_LS] = self.g_surround * self.ph[CH_LS] * al
            spec[CH_RS] = self.g_surround * self.ph[CH_RS] * ar
            if twelve:
                spec[CH_RLS] = self.g_surround * 0.7 * self.ph[CH_RLS] * al
                spec[CH_RRS] = self.g_surround * 0.7 * self.ph[CH_RRS] * ar
                wh = self.heightW * self.g_height
                spec[CH_VHL] = self.ph[CH_VHL] * al * wh
                spec[CH_VHR] = self.ph[CH_VHR] * ar * wh
                spec[CH_LTR] = self.ph[CH_LTR] * al * wh * 0.7
                spec[CH_RTR] = self.ph[CH_RTR] * ar * wh * 0.7
            if self.lfe:
                spec[CH_LFE] = 0.5 * (A + B) * self.lfeW
            for ch in range(self.channels):
                out[ch, i * hop:i * hop + n] += np.fft.irfft(spec[ch], n) * st.win
        out /= st.cola
        return out[:, n:n + len(L)]          # drop the latency priming


# ---------------------------------------------------------------------------
# Critical bands (1/3 octave), shared by the kernel and the mask metric
# ---------------------------------------------------------------------------
def band_index(n: int, sr: int, origin: float = 63.0):
    """1/3-octave band index per FFT bin, from `origin` Hz: floor(3*log2(f/origin)).
    Duplicated in STFTUpmixer.swift — keep the two in step."""
    f = np.arange(n // 2 + 1) * (sr / n)
    return np.maximum(0, np.floor(3 * np.log2(np.maximum(f, 1.0) / origin))).astype(int)


# ---------------------------------------------------------------------------
# Kernel V2 — proposed kernel
# ---------------------------------------------------------------------------
SHAPE_HEIGHT = "auro"      # "auro": HP 150 Hz + HF roll-off (Auro-Matic-like)
                           # "air"  : >2 kHz emphasis (current behaviour)


class KernelV2:
    """Proposed kernel.

    Changes vs V1 (each one is independently switchable so the lab can attribute
    every dB of difference to one decision):

      1. diffuseness  D = (1 - g2) * level_similarity**3   -> hard-panned coherent
         content is no longer classified as ambience (Avendano/Jot's "comparable
         energies" criterion, which V1 omits).
      2. masks are power-complementary (sqrt) so the direct/ambient split is exactly
         energy preserving instead of leaving a mid-mask dip.
      3. energy-correct centre law: gamma = sqrt(2(1-alpha^2)) instead of the fitted
         sqrt(2)*c, which removes the 2.7 dB mid-pan level dip (and the pumping that
         goes with it).
      4. asymmetric (fast-attack) mask smoothing + an onset gate: transients stay
         direct, reverb tails are allowed to decorrelate.
      5. bass management: the surround/height sends are high-passed at 150 Hz.
      6. height layer is synthesised Auro-Matic-style: delayed, HF-trimmed,
         adjacency-weighted copies of the ground channels, plus an HF ambience send
         - instead of an undelayed >2 kHz decorrelated copy.
      7. strength: 0..1 master control scaling the whole effect (0 = passthrough).
      8. auto level: slow (500 ms) bed-domain gain trim so toggling upmix does not
         change loudness.
      9. the diffuseness decision is taken per critical band (1/3 octave) instead of per
         bin, then blended back into the bins: a per-bin decision flutters frame to frame
         on broadband transients (sibilants, cymbals) and that flutter is the "shh-shh"
         haze.  A quarter of the per-bin estimate is kept so one very direct bin inside
         an ambient band is not swallowed whole.  Switchable (`band_agg=False`).
    """

    name = "v2 (proposed)"

    def __init__(self, sr: int = SR, n: int = 2048, channels: int = 6,
                 center=1.0, surround_db=0.0, height_db=-6.0, decorr=0.7,
                 ambient_db=0.0, lfe=False, strength=1.0, transient=1.0,
                 reflections_db=-6.0, bass_hz=150.0, auto_level=True,
                 height_shape=SHAPE_HEIGHT, spread=0.6, band_agg=True,
                 band_mix=0.25, probe: bool = False):
        self.stft = STFT(n, sr)
        self.sr, self.n, self.hop, self.half = sr, n, n // 4, n // 2
        self.channels = channels
        self.center = center
        self.g_surround = 10 ** (surround_db / 20)
        self.g_height = 10 ** (height_db / 20)
        self.decorr = decorr
        self.g_ambient = 10 ** (ambient_db / 20)
        self.lfe = lfe
        self.strength = strength
        self.spread = spread          # share of the extracted ambience sent to the surrounds
        self.transient = transient
        self.reflections = 10 ** (reflections_db / 20)
        self.bass_hz = bass_hz
        self.auto_level = auto_level
        self.height_shape = height_shape
        self.band_agg = band_agg
        self.band_mix = band_mix
        self.probe = probe            # record the shape-free send gain per bin/frame
        self.probe_send = []
        self.hop_s = self.hop / sr
        self.tau_pow = 0.120                                # cross-spectrum averaged 120 ms
        self.a_pow = math.exp(-self.hop_s / self.tau_pow)
        # effective number of independent looks: window-hopping means roughly
        # tau/hop frames, of which only the 25 % un-overlapped part is new information
        self.bias = 1.0 / max(self.tau_pow / self.hop_s, 1.0)
        # Transient preservation maps to the mask's opening time constant: 30 ms at 0
        # (gently asymmetric) down to 5 ms at 1. MUST stay in step with STFTUpmixer.swift.
        self.a_fast = math.exp(-self.hop_s / (0.030 - 0.025 * min(max(transient, 0.0), 1.0)))
        self.a_slow = math.exp(-self.hop_s / 0.150)
        self.a_lvl = math.exp(-self.hop_s / 0.500)
        self.alpha_dc = math.exp(-2 * math.pi * 20 / sr)      # 20 Hz one-pole (bass mgmt)
        self.lvl = 1.0
        self.onset_hold = 0
        self.pow_slow = 0.0
        half = self.half
        f = np.arange(half + 1) * (sr / n)
        # surround/height band shaping
        hp = f / np.sqrt(f ** 2 + bass_hz ** 2)               # 1st-order HP magnitude
        if height_shape == "auro":
            # rolled-off top (Auro-Matic deliberately darkens the height layer)
            lp = 1.0 / np.sqrt(1.0 + (f / 7000.0) ** 2)
            self.shapeH = hp * lp * 1.2
        else:
            self.shapeH = hp * np.where(f < 2000, 0.0,
                                        np.where(f < 8000, np.log2(np.maximum(f, 1.0) / 2000) / 2, 1.0)) * 1.6
        self.shapeS = hp                                       # surrounds: bass-managed only
        for nm in ("shapeH", "shapeS"):
            v = getattr(self, nm)
            g = math.sqrt(float(np.mean(v ** 2)) + 1e-12)
            setattr(self, nm, v / g)
        self.lfeW = np.where(f < 120, 1.0,
                             np.where(f < 180, 0.5 + 0.5 * np.cos(np.pi * (f - 120) / 60), 0.0))
        # decorrelation phases (same tables as V1 so only the algorithm differs)
        self.band_idx = band_index(n, sr)
        self.nbands = int(self.band_idx.max()) + 1
        self.phi = decorrelator_phase(max(channels, 6), half + 1, sr, n)
        self.ph = np.exp(1j * self.phi[:max(channels, 6)] * decorr)
        # front-ambience copies need their own (gentler) phase so they do not simply
        # re-correlate with the direct path they were extracted from.
        fphi = decorrelator_phase(6, half + 1, sr, n, tau_max=0.0012, segment=4)
        # channels 0..3 of a decorrelator table are deliberately coherent; take the
        # two curves that actually carry phase (4, 5) for the front L/R ambience copies
        self.ph_front = np.exp(1j * fphi[4:6] * decorr)
        # reflection matrix (source -> destination), Auro-Matic-ish adjacency weights
        #   mostly the speaker below, less the adjacent, least the diagonal opposite
        src = {CH_L: 0, CH_R: 1, CH_C: 2, CH_LS: 3, CH_RS: 4}
        self.refl_src = list(src.keys())
        # destination -> (delay ms, weight per source)
        self.refl = {}
        if channels == 12:
            self.refl[CH_VHL] = (11.0, np.array([1.00, 0.30, 0.45, 0.65, 0.08]))
            self.refl[CH_VHR] = (17.0, np.array([0.30, 1.00, 0.45, 0.08, 0.65]))
            self.refl[CH_LTR] = (13.0, np.array([0.45, 0.12, 0.20, 0.95, 0.15]))
            self.refl[CH_RTR] = (23.0, np.array([0.12, 0.45, 0.20, 0.15, 0.95]))
            self.refl[CH_RLS] = (9.0, np.array([0.35, 0.05, 0.10, 0.55, 0.02]))
            self.refl[CH_RRS] = (9.0, np.array([0.05, 0.35, 0.10, 0.02, 0.55]))

    # -- STFT front end -----------------------------------------------------
    def run(self, L: np.ndarray, R: np.ndarray):
        st = self.stft
        n, hop, half = self.n, self.hop, self.half
        out = np.zeros((self.channels, len(L) + n))
        if self.probe:
            self.probe_send = []
        pLL = np.zeros(half + 1)
        pRR = np.zeros(half + 1)
        pLR = np.zeros(half + 1, dtype=complex)
        sD = np.zeros(half + 1)
        sDBand = np.zeros(self.nbands)
        a, eps, sqrt2 = self.a_pow, 1e-20, math.sqrt(2.0)
        twelve = self.channels == 12
        Lp = np.concatenate([np.zeros(n), L])
        Rp = np.concatenate([np.zeros(n), R])
        count = (len(Lp) - n) // hop + 1
        for i in range(count):
            l = Lp[i * hop:i * hop + n] * st.win
            r = Rp[i * hop:i * hop + n] * st.win
            A = np.fft.rfft(l)
            B = np.fft.rfft(r)
            ell, err = np.abs(A) ** 2, np.abs(B) ** 2
            pLL = a * pLL + (1 - a) * ell
            pRR = a * pRR + (1 - a) * err
            pLR = a * pLR + (1 - a) * (A * np.conj(B))

            g2 = (np.abs(pLR) ** 2) / (pLL * pRR + eps)
            # remove the upward bias of a short-time coherence estimate so that fully
            # diffuse material really reads as diffuse (gamma^2 -> 1 with L averages)
            g2 = np.clip((g2 - self.bias) / (1 - self.bias), 0, 1)
            lsim = 2 * np.sqrt(pLL * pRR) / (pLL + pRR + eps)      # (1) comparable energy
            beta = (pLL - pRR) / (pLL + pRR + eps)
            d_raw = (1 - g2) * lsim ** 3

            # (4) asymmetric smoothing: direct fast, diffuse slow
            fast = d_raw < sD
            sD = np.where(fast, self.a_fast * sD + (1 - self.a_fast) * d_raw,
                          self.a_slow * sD + (1 - self.a_slow) * d_raw)

            # (9) critical-band aggregation.  Power-weighted so the band follows what is
            # audible in it; bands are smoothed with the same asymmetric rule and the
            # per-bin estimate is mixed back in (band_mix) to preserve within-band
            # contrast.  A band with no power keeps its previous value.
            if self.band_agg:
                pw = pLL + pRR
                bp = np.bincount(self.band_idx, weights=pw, minlength=self.nbands)
                bd = np.bincount(self.band_idx, weights=pw * d_raw, minlength=self.nbands)
                valid = bp > 1e-18
                means = np.where(valid, bd / (bp + eps), 0.0)
                upd = np.where(means < sDBand,
                               self.a_fast * sDBand + (1 - self.a_fast) * means,
                               self.a_slow * sDBand + (1 - self.a_slow) * means)
                sDBand = np.where(valid, upd, sDBand)
                bandD = sDBand[self.band_idx]
                d_sm = bandD + self.band_mix * (sD - bandD)
            else:
                d_sm = sD

            # onset gate: broadband flux -> hold the mask down (transients stay front)
            pw = float(np.sum(ell + err))
            ratio = pw / (self.pow_slow + eps)
            self.pow_slow = 0.8 * self.pow_slow + 0.2 * pw
            if ratio > 1.6 and self.transient > 0:
                self.onset_hold = 6
            gate = 1.0
            if self.onset_hold > 0:
                gate = 0.15
                self.onset_hold -= 1

            D = np.clip(d_sm * gate * self.strength, 0, 1)         # (7) strength scales D
            gd = np.sqrt(1 - D)                                    # (2) power masks
            Dsend = D * self.spread
            Dfront = D * (1 - self.spread)
            gsend = np.sqrt(Dsend) * self.g_ambient
            gfront = np.sqrt(Dfront)

            m = 0.5 * (A + B)
            sd = 0.5 * (A - B)
            beta_p = np.clip(beta, -0.999, 0.999)
            # strength also gates the centre extraction: at 0 the input channels pass
            # through untouched (same contract as Auro-Matic strength = 0)
            c = np.clip((1 - np.abs(beta_p)) ** 2 * self.center * self.strength, 0, 1)
            alpha = 1 - c
            gamma = np.sqrt(np.maximum(2 * (1 - alpha ** 2), 0))    # (3) energy-correct
            # wide/anti-phase content (Re(P_LR) < 0) has no stable phantom: keep it
            # in the front pair instead of letting beta lie about its position.
            anti = pLR.real < 0
            alpha = np.where(anti, 1.0, alpha)
            gamma = np.where(anti, 0.0, gamma)

            spec = np.zeros((self.channels, half + 1), dtype=complex)
            spec[CH_L] = gd * (alpha * m + sd) + gfront * self.ph_front[0] * A
            spec[CH_R] = gd * (alpha * m - sd) + gfront * self.ph_front[1] * B
            spec[CH_C] = gd * gamma * m

            if self.probe:
                self.probe_send.append(20 * np.log10(np.maximum(gsend, 1e-6)))

            al, ar = gsend * A, gsend * B
            spec[CH_LS] = self.g_surround * self.shapeS * self.ph[CH_LS] * al
            spec[CH_RS] = self.g_surround * self.shapeS * self.ph[CH_RS] * ar
            if twelve:
                spec[CH_VHL] = self.g_height * self.shapeH * self.ph[CH_VHL] * al
                spec[CH_VHR] = self.g_height * self.shapeH * self.ph[CH_VHR] * ar
            if self.lfe:
                spec[CH_LFE] = 0.5 * (A + B) * self.lfeW

            for ch in range(self.channels):
                out[ch, i * hop:i * hop + n] += np.fft.irfft(spec[ch], n) * st.win

        out /= st.cola
        out = out[:, n:n + len(L)]
        # (6) reflection layer (time domain — a phase-ramp delay inside the STFT
        # would wrap the window; the Swift kernel does the same thing on its output)
        if self.refl:
            out = self._reflections(out)
        if self.auto_level:
            out = self._auto_level(out, L, R)
        return out

    def _reflections(self, out: np.ndarray):
        """Add delayed, HF-trimmed, adjacency-weighted copies of the ground layer."""
        nch = out.shape[1]
        max_delay = int(max(d for d, _ in self.refl.values()) * self.sr / 1000) + 1
        delay_lines = {s: np.zeros(max_delay) for s in self.refl_src}
        # one-pole low shelf (HF trim) + one-pole high-pass, per source.  Both are
        # normalised so the reflection layer has a defined level instead of inheriting
        # whatever gain the filter happens to have.
        lp_a = 1 - math.exp(-2 * math.pi * 5000 / self.sr)
        hp_a = math.exp(-2 * math.pi * self.bass_hz / self.sr)
        lpz = {s: 0.0 for s in self.refl_src}
        hpx = {s: 0.0 for s in self.refl_src}
        hpz = {s: 0.0 for s in self.refl_src}
        out = out.copy()
        for i in range(nch):
            filt = {}
            for s in self.refl_src:
                x = out[s, i]
                # high-pass FIRST (bass management), then a low-shelf HF trim on the
                # high-passed signal — so the reflection layer really carries no bass
                hpz[s] = hp_a * (hpz[s] + x - hpx[s])
                hpx[s] = x
                s_ = hpz[s]                             # one-pole HP: |H| <= ~0.9, bass gone
                lpz[s] += lp_a * (s_ - lpz[s])          # HF trim of the high-passed signal
                filt[s] = 1.10 * (0.6 * s_ + 0.4 * lpz[s])   # bounded to ~unit gain
                delay_lines[s][1:] = delay_lines[s][:-1]
                delay_lines[s][0] = filt[s]
            for dest, (ms, w) in self.refl.items():
                d = int(ms * self.sr / 1000)
                acc = 0.0
                for j, s in enumerate(self.refl_src):
                    if w[j] != 0.0:
                        acc += w[j] * delay_lines[s][d]
                out[dest, i] += self.reflections * self.g_height * self.strength * acc
        return out

    def _auto_level(self, out: np.ndarray, L: np.ndarray, R: np.ndarray):
        """Slow bed-domain gain trim so upmix on/off does not change loudness."""
        win = 4096
        n = len(L)
        gain = np.ones(n)
        p_in = L ** 2 + R ** 2
        # bed energy: front pair counts double (it is what the ear gets first),
        # surrounds/height are diffuse and sum incoherently
        p_out = out[CH_L] ** 2 + out[CH_R] ** 2 + out[CH_C] ** 2 \
            + np.sum(out[4:] ** 2, axis=0)
        for i in range(0, n, win):
            a = self.a_lvl
            pi = float(np.mean(p_in[i:i + win]))
            po = float(np.mean(p_out[i:i + win]))
            if po > 1e-12 and pi > 1e-12:
                target = math.sqrt(pi / po)
                self.lvl = min(max(a * self.lvl + (1 - a) * target, 0.5), 2.0)
            gain[i:i + win] = self.lvl
        return out * gain


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
def pan(x: np.ndarray, p: float):
    """Constant-power pan, p in [-1, 1] (VBAP over a 60 deg pair)."""
    p = float(np.clip(p, -1, 1))
    gL = math.cos((np.arcsin(p) + math.pi / 2) / 2)  # smooth, monotone, gL^2+gR^2=1
    gR = math.sin((np.arcsin(p) + math.pi / 2) / 2)
    return x * gL, x * gR


def pan_sweep(sr: int, dur: float, f=700.0):
    t = np.arange(int(sr * dur)) / sr
    pos = np.sin(2 * np.pi * 0.25 * t)          # 4 s round trip
    env = np.ones_like(t)
    L = np.zeros_like(t)
    R = np.zeros_like(t)
    for i in range(len(t)):
        a, b = pan(np.array([env[i]]), pos[i])
        ph = np.sin(2 * np.pi * f * t[i])
        L[i] = a[0] * ph
        R[i] = b[0] * ph
    return L, R


def tone_center(sr: int, dur: float, f=1000.0):
    t = np.arange(int(sr * dur)) / sr
    x = 0.5 * np.sin(2 * np.pi * f * t)
    return pan(x, 0.0)


def tone_hard(sr: int, dur: float, f=1000.0, side=+1):
    t = np.arange(int(sr * dur)) / sr
    x = 0.5 * np.sin(2 * np.pi * f * t)
    return pan(x, side)


def noise_diffuse(sr: int, dur: float, seed=1):
    rng = np.random.default_rng(seed)
    n = int(sr * dur)
    L = 0.2 * rng.standard_normal(n)
    R = 0.2 * rng.standard_normal(n)
    return L, R


def clicks(sr: int, dur: float, period=0.5):
    n = int(sr * dur)
    x = np.zeros(n)
    k = np.arange(int(sr * 0.002))
    burst = np.exp(-k / (sr * 0.0003))
    i = 0
    while i < n - len(burst):
        x[i:i + len(burst)] += burst
        i += int(period * sr)
    return pan(x * 0.4, -1.0)      # hard left click train


def song(sr: int, dur: float = 10.0, seed=7):
    """Synthetic 'song': bass, vocal-ish lead, hard-panned guitar + piano,
    drum hits, a slow pan move, and a decorrelated reverb tail."""
    rng = np.random.default_rng(seed)
    n = int(sr * dur)
    t = np.arange(n) / sr
    L = np.zeros(n)
    R = np.zeros(n)

    def add(l, r):
        nonlocal L, R
        L += l
        R += r

    # bass: 2 slow notes, centre
    bass = 0.22 * np.sin(2 * np.pi * 55 * t) * (1 + 0.4 * np.sin(2 * np.pi * 0.4 * t))
    add(*pan(bass, 0.0))
    # lead: sawtooth with vibrato, centre-ish, slow pan move
    f0 = 220 * (1 + 0.01 * np.sin(2 * np.pi * 5.2 * t))
    ph = 2 * np.pi * np.cumsum(f0) / sr
    lead = 0.16 * (2 * (ph / np.pi % 2) - 1) * np.exp(-((t % 8) - 4) ** 2 / 6)
    add(lead * 0.85, lead * 0.52)              # slightly left of centre
    # hard-left guitar
    gtr = 0.14 * np.sign(np.sin(2 * np.pi * 147 * t)) * (0.5 + 0.5 * np.sin(2 * np.pi * 2.1 * t))
    add(*pan(gtr, -1.0))
    # hard-right piano-ish arpeggio
    notes = [392, 494, 587, 784]
    pi_ = np.zeros(n)
    for i, f in enumerate(notes):
        seg = (t % (0.5 * len(notes))) - i * 0.5
        env = np.where((seg >= 0) & (seg < 0.5), np.exp(-seg * 6), 0.0)
        pi_ += 0.10 * env * np.sin(2 * np.pi * f * t)
    add(*pan(pi_, +1.0))
    # drums: hard-panned hats, centre kick
    kick = 0.25 * np.sin(2 * np.pi * 60 * t) * np.exp(-((t % 0.5)) * 12)
    add(*pan(kick, 0.0))
    hp = np.diff(np.concatenate([[0], rng.standard_normal(n)]))
    hat_env = np.exp(-((t % 0.25)) * 60)
    add(*pan(0.05 * hp * hat_env, +0.7))
    # decorrelated reverb tail: filtered noise, independent L/R
    rev = rng.standard_normal(n)
    b = 0.0
    revf = np.zeros(n)
    for i in range(1, n):
        b = 0.995 * b + 0.005 * rev[i]
        revf[i] = b
    revf *= np.exp(-t / 6)
    add(0.25 * revf, 0.25 * rng.standard_normal(n) * np.exp(-t / 6) * 0.6)
    peak = max(np.abs(L).max(), np.abs(R).max())
    return L / peak * 0.5, R / peak * 0.5


# ---------------------------------------------------------------------------
# Cheap binaural monitor (spherical head + ITD + pinna notch)
# ---------------------------------------------------------------------------
def hrir(az_deg: float, el_deg: float, sr: int, taps: int = 96):
    """Return (left, right) FIRs for a direction. Crude but directionally honest:
    Woodworth ITD, angle-dependent head shadow, elevation-dependent pinna notch."""
    a, c = 0.0875, 343.0
    az = math.radians(max(-90.0, min(90.0, abs(az_deg))))
    near_is_left = az_deg < 0
    itd = a / c * (az + math.sin(az))                 # seconds, contralateral extra path
    n = taps
    t = np.arange(n) / sr
    fir_far = np.zeros(n)
    fir_near = np.zeros(n)
    # head shadow: one-pole low-pass whose cutoff falls with angle
    fc = 20000.0 * (1 - 0.85 * math.sin(az)) + 800.0
    k = math.exp(-2 * math.pi * fc / sr)
    g = (1 - k)
    y = 0.0
    h = np.zeros(n)
    for i in range(n):
        y = k * y + g * (1.0 if i == 0 else 0.0)
        h[i] = y
    # ipsilateral: slight HF boost above 3 kHz
    boost = 1.0 + 0.35 * math.sin(az)
    ip = np.exp(-t / 0.0004) * (1.0 + boost * 0.0)
    ip = np.zeros(n)
    ip[0] = 1.0
    ip[1] = 0.35 * boost * math.exp(-1 / (sr * 0.0002))
    # pinna notch for elevation
    fc_n = 4000.0 + 90.0 * (el_deg + 40.0)
    wn = 2 * math.pi * fc_n / sr
    notch = np.zeros(n)
    notch[0] = 1.0
    q = 0.85
    notch[1] = -2 * q * math.cos(wn)
    notch[2] = q * q
    # normalize notch again: use it as a mild 1-zero/1-pole extra
    far = h
    near = ip
    d = int(round(itd * sr))
    far_s = np.concatenate([np.zeros(d), far])[:n]
    if near_is_left:
        return np.concatenate([near, np.zeros(n - len(near))])[:n], far_s
    return far_s, np.concatenate([near, np.zeros(n - len(near))])[:n]


def binaural_render(bed: np.ndarray, channels: int, sr: int):
    """Sum the bed over its speaker directions through the cheap HRIR."""
    n = bed.shape[1]
    nfft = 1 << int(math.ceil(math.log2(n + 256)))
    left = np.zeros(nfft)
    right = np.zeros(nfft)
    for ch in range(channels):
        if ch == CH_LFE or np.allclose(bed[ch], 0):
            continue
        az, el = AZ_714[ch], EL_714[ch]
        hl, hr = hrir(az, el, sr)
        X = np.fft.rfft(bed[ch], nfft)
        left += np.fft.irfft(X * np.fft.rfft(hl, nfft), nfft)
        right += np.fft.irfft(X * np.fft.rfft(hr, nfft), nfft)
    return left[:n], right[:n]


def iacc(l: np.ndarray, r: np.ndarray):
    """Inter-aural cross-correlation at zero lag over 100 ms frames (lower = wider)."""
    w = int(0.1 * SR)
    vals = []
    for i in range(0, len(l) - w, w):
        a, b = l[i:i + w], r[i:i + w]
        d = math.sqrt(float(np.sum(a * a)) * float(np.sum(b * b)))
        if d > 1e-9:
            vals.append(abs(float(np.sum(a * b))) / d)
    return float(np.mean(vals)) if vals else float("nan")


def spectrum_deviation(a: np.ndarray, b: np.ndarray, sr: int, nfft=4096):
    """Mean |dB difference| between two signals' long-term spectra, 150 Hz..10 kHz."""
    f, Pa = _psd(a, sr, nfft)
    _, Pb = _psd(b, sr, nfft)
    band = (f > 150) & (f < 10000)
    d = 10 * np.log10((Pa[band] + 1e-20) / (Pb[band] + 1e-20))
    return float(np.mean(np.abs(d)))


def _psd(x: np.ndarray, sr: int, nfft=4096):
    w = np.hanning(nfft)
    acc = np.zeros(nfft // 2 + 1)
    cnt = 0
    for i in range(0, len(x) - nfft, nfft // 2):
        acc += np.abs(np.fft.rfft(x[i:i + nfft] * w)) ** 2
        cnt += 1
    return np.fft.rfftfreq(nfft, 1 / sr), acc / max(cnt, 1)


def db(x: float) -> float:
    return 20 * math.log10(max(x, 1e-12))


# ---------------------------------------------------------------------------
# Measurements
# ---------------------------------------------------------------------------
def build(channels: int, **kw):
    """Measurement kernels: auto-level OFF, because it would mask the very level
    behaviour we are measuring (pan-law flatness)."""
    v1 = KernelV1(channels=channels, **kw)
    v2 = KernelV2(channels=channels, auto_level=False, **kw)
    return v1, v2


def bed_power(y, skip=0, chans=None, tail=4096):
    """Total acoustic power (power sum over channels) — the level invariant that
    matters when a signal is redistributed over more loudspeakers.  The last
    window of overlap-add is incomplete, so it is trimmed."""
    z = y if chans is None else y[chans]
    z = z[:, skip:len(z[1]) - tail if tail else None]
    return math.sqrt(float(np.sum(np.mean(z ** 2, axis=1))))


def measure_pan(kernels, sr=SR, channels=6, positions=17, hold=0.6):
    """Steady tone at each pan position: the upmixer's level response across the image.
    A correct law is flat in dB; V1's fitted centre law is not."""
    out = {}
    n = int(hold * sr)
    t = np.arange(n) / sr
    for k in kernels:
        lv = []
        for p in np.linspace(-1, 1, positions):
            x = 0.4 * np.sin(2 * np.pi * 800 * t)
            L, R = pan(x, p)
            ref = bed_power(np.vstack([L, R]))
            y = k.run(L, R)
            lv.append(db(bed_power(y, skip=int(0.35 * sr), chans=range(6)) / ref))
        lv = np.array(lv)
        out[k.name] = (float(lv.min()), float(lv.max()), float(lv.mean()))
    return out


def measure_hardpan(kernels, sr=SR, channels=6):
    L, R = tone_hard(sr, 3.0, side=-1)
    out = {}
    for k in kernels:
        y = k.run(L, R)
        e = np.sum(y[:, sr:] ** 2, axis=1)
        tot = e.sum()
        out[k.name] = (e[4:].sum() / tot if tot else 0.0, e[:3].sum() / tot if tot else 0.0,
                       e[CH_L] / tot if tot else 0)
    return out


def measure_center(kernels, sr=SR, channels=6):
    """Centre-panned source: how much lands in C, and what happens to the total."""
    L, R = tone_center(sr, 3.0)
    ref = bed_power(np.vstack([L, R]))
    out = {}
    for k in kernels:
        y = k.run(L, R)
        e = np.sum(y[:, sr:] ** 2, axis=1)
        tot = e.sum()
        out[k.name] = (db(bed_power(y, skip=sr, chans=range(6)) / ref),
                       e[CH_C] / tot if tot else 0.0)
    return out


def measure_bass(kernels, sr=SR, channels=6):
    """Decorrelated low-frequency content (studio rumble / reverb): with bass
    management the surround and height sends must be high-passed, because a
    detached low end is one of the things that makes an upmix sound wrong."""
    rng = np.random.default_rng(11)
    n = int(sr * 4.0)
    x = rng.standard_normal(n)
    b = np.zeros(n)
    acc = 0.0
    for i in range(1, n):                       # one-pole LP -> rumbly
        acc = acc * 0.999 + 0.001 * x[i]
        b[i] = acc
    b /= (np.abs(b).max() + 1e-9)
    scale = math.sqrt(float(np.mean(b ** 2)))
    L = 0.4 * b / scale * 0.05
    R = 0.4 * np.roll(b, 977) / scale * 0.05    # decorrelated partner
    lo = 120.0
    out = {}
    for k in kernels:
        y = k.run(L, R)
        seg = slice(sr, -4096)
        sub = y[4:, seg]
        # energy below 120 Hz, measured with a 4th-order-ish one-pole cascade
        a = math.exp(-2 * math.pi * lo / sr)
        z = np.zeros(sub.shape[1])
        for ch in range(sub.shape[0]):
            st_ = 0.0
            v = np.empty_like(sub[ch])
            for i in range(len(sub[ch])):
                st_ = a * st_ + (1 - a) * sub[ch, i]
                v[i] = st_
            z += v ** 2
        inl = L[seg] ** 2 + R[seg] ** 2
        st_ = 0.0
        ref = np.empty_like(L[seg])
        for i in range(len(ref)):
            st_ = a * st_ + (1 - a) * (L[seg][i] + R[seg][i]) * 0.5
            ref[i] = st_
        out[k.name] = (float(np.mean(z) / (float(np.mean(ref ** 2)) * 2 + 1e-20)),)
    return out


def measure_diffuse(kernels, sr=SR, channels=6):
    L, R = noise_diffuse(sr, 4.0)
    out = {}
    for k in kernels:
        y = k.run(L, R)
        e = np.sum(y[:, sr:] ** 2, axis=1)
        tot = e.sum()

        def corr(a, b):
            d = math.sqrt(float(np.sum(a * a)) * float(np.sum(b * b)))
            return abs(float(np.sum(a * b))) / d if d > 1e-9 else 0.0

        bl, br = binaural_render(y, channels, sr)
        out[k.name] = (e[4:].sum() / tot if tot else 0.0,
                       corr(y[CH_L, sr:], y[CH_RS, sr:]),
                       corr(y[CH_LS, sr:], y[CH_RS, sr:]),
                       iacc(bl, br))
    return out


def measure_null(kernels, sr=SR, channels=6):
    L, R = song(sr, 3.0)
    out = {}
    for k in kernels:
        if isinstance(k, KernelV2):
            saved = (k.strength, k.auto_level)
            k.strength, k.auto_level = 0.0, False
            y = k.run(L, R)
            k.strength, k.auto_level = saved
            t = slice(4096, -4096)
            d = max(float(np.max(np.abs(y[CH_L, t] - L[t]))),
                    float(np.max(np.abs(y[CH_R, t] - R[t]))))
            out[k.name] = d
    return out


def measure_song(kernels, sr=SR, channels=6, dur=8.0):
    """Front-stage timbre (the direct sound must survive) + binaural width vs a
    plain-stereo binaural reference rendered at +-30 deg."""
    L, R = song(sr, dur)
    bed = np.zeros((12, len(L)))
    bed[CH_L], bed[CH_R] = L, R
    ref_l, ref_r = binaural_render(bed, 12, sr)
    out = {}
    for k in kernels:
        y = k.run(L, R)
        front = y[CH_L] + y[CH_R]
        bl, br = binaural_render(y, channels, sr)
        out[k.name] = (spectrum_deviation(front, L + R, sr),
                       iacc(bl, br), iacc(ref_l, ref_r),
                       spectrum_deviation(bl + br, ref_l + ref_r, sr))
    return out


def click_bed(sr=SR, dur=6.0, seed=3):
    """A dry click train over a decaying, partly decorrelated bed: the test signal for
    both the transient metric and the mask-jitter metric."""
    rng = np.random.default_rng(seed)
    t = np.arange(int(sr * dur)) / sr
    k = np.arange(int(sr * 0.002))
    burst = np.exp(-k / (sr * 0.0003))
    clicks_ = np.zeros(len(t))
    onsets = []
    i = 0
    while i < len(clicks_) - len(burst):
        clicks_[i:i + len(burst)] += burst
        onsets.append(i)
        i += int(0.5 * sr)
    # each click is followed by a decaying, partially decorrelated tail
    tailL = np.zeros(len(t))
    tailR = np.zeros(len(t))
    for o in onsets:
        kk = int(0.30 * sr)
        env = np.exp(-np.arange(kk) / (0.06 * sr))
        a = rng.standard_normal(kk) * env
        c = rng.standard_normal(kk) * env
        seg = slice(o, min(o + kk, len(t)))
        m = seg.stop - seg.start
        tailL[seg] += 0.12 * (0.7 * a[:m] + 0.3 * c[:m])
        tailR[seg] += 0.12 * (0.7 * c[:m] + 0.3 * a[:m])
    return 0.4 * clicks_ + tailL, 0.4 * clicks_ + tailR, onsets


def mask_jitter(send_db, sr, n, lo=500.0, hi=10000.0, floor_db=-35.0):
    """Per-bin send-gain jitter inside a critical band, in dB: for every 1/3-octave band
    take the gain of each bin relative to the band's own mean, then average the temporal
    std over bins.  It is the spectral comb that changes every frame — the "shh" in
    sibilants and cymbals, and the reason a per-bin mask sounds cheap.  Lower = smoother.
    Bands whose send is below `floor_db` (nothing being sent) are skipped."""
    f = np.arange(n // 2 + 1) * (sr / n)
    bidx = band_index(n, sr)
    sel = (f >= lo) & (f <= hi)
    b, X = bidx[sel], np.asarray(send_db)[:, sel]
    vals = []
    for band in np.unique(b):
        m = b == band
        if m.sum() < 2:
            continue
        sub = X[:, m]
        if float(sub.mean()) < floor_db:
            continue
        vals.append(float(np.mean(np.std(sub - sub.mean(axis=1, keepdims=True), axis=0))))
    return float(np.mean(vals)) if vals else float("nan")


def measure_mask_jitter(kernels, sr=SR, channels=12, n=2048, dur=4.0):
    """Run each probe-enabled kernel over two signals and report the send-gain jitter."""
    Lb, Rb, _ = click_bed(sr, dur)
    Ls, Rs = song(sr, dur)
    out = {}
    for k in kernels:
        vals = []
        for L, R in ((Lb, Rb), (Ls, Rs)):
            k.run(L, R)
            vals.append(mask_jitter(k.probe_send, sr, n) if k.probe_send else float("nan"))
        out[k.name] = tuple(vals)
    return out


def measure_transient(kernels, sr=SR, channels=6):
    """Click + diffuse bed.  A good upmixer keeps the *attack* out of the surrounds:
    attack/tail ratio below 1 means the transient was not spread to the rear."""
    L, R, onsets = click_bed(sr, 6.0)
    out = {}
    for kk in kernels:
        y = kk.run(L, R)
        rear = np.sum(y[4:, :] ** 2, axis=0)
        front = np.sum(y[:3, :] ** 2, axis=0)
        att, tail = [], []
        for o in onsets:
            o = o + int(0.048 * sr)     # skip the STFT's one-window latency
            a0, a1 = o + int(0.002 * sr), o + int(0.020 * sr)
            t0, t1 = o + int(0.100 * sr), o + int(0.300 * sr)
            if a1 < len(rear) and t1 < len(rear):
                att.append(float(np.mean(rear[a0:a1])) / (float(np.mean(front[a0:a1])) + 1e-20))
                tail.append(float(np.mean(rear[t0:t1])) / (float(np.mean(front[t0:t1])) + 1e-20))
        r = (np.mean(att) / (np.mean(tail) + 1e-20)) if att else float("nan")
        out[kk.name] = (r,)
    return out


# ---------------------------------------------------------------------------
# Loudness when the upmixer is engaged — "turning it on changes the level" is a
# level-*and*-timbre problem, so we report the bed-domain power ratio, what
# arrives at the eardrum through the binaural monitor, and how much energy left
# the front pair.
# ---------------------------------------------------------------------------
def measure_loudness(sr=SR, channels=12, dur=8.0):
    L, R = song(sr, dur)
    bed = np.zeros((12, len(L)))
    bed[CH_L], bed[CH_R] = L, R
    ref_l, ref_r = binaural_render(bed, 12, sr)
    ref_rms = math.sqrt(float(np.mean((ref_l + ref_r) ** 2)))
    ref_bed = bed_power(np.vstack([L, R]))

    def binaural_rms(y):
        bl, br = binaural_render(y, channels, sr)
        return math.sqrt(float(np.mean((bl + br) ** 2)))

    variants = [("v1 (current)", KernelV1(channels=channels)),
                ("v2 (auto level off)", KernelV2(channels=channels, auto_level=False)),
                ("v2 (auto level on)", KernelV2(channels=channels, auto_level=True))]
    out = {}
    for name, k in variants:
        y = k.run(L, R)
        out[name] = (db(bed_power(y) / ref_bed),
                     db(binaural_rms(y) / ref_rms),
                     db(bed_power(y, chans=[0, 1]) / ref_bed))
    return out


# ---------------------------------------------------------------------------
# WAV I/O
# ---------------------------------------------------------------------------
def write_wav(path: str, data: np.ndarray, sr: int, layout: str = "714"):
    """data: (channels, n). IEEE-float 32 WAVE_FORMAT_EXTENSIBLE."""
    ch = data.shape[0]
    masks = {
        "714": 0x0,   # custom; players use our order
        "51": (0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20),
    }
    mask = masks.get(layout, 0)
    if ch == 6:
        mask = 0x3F
    if ch == 2:
        mask = 0x3
    x = data.T.astype("<f4").tobytes()
    # RIFF size counts everything after this field: "WAVE" + (8+40) fmt + (8+len) data
    header = b"RIFF" + struct.pack("<I", 12 + 40 + 8 + len(x)) + b"WAVE"
    header += b"fmt " + struct.pack("<I", 40) + struct.pack("<HHIIHH", 0xFFFE, ch, sr,
                                                           sr * ch * 4, ch * 4, 32)
    header += struct.pack("<HHI", 22, 32, mask)
    header += struct.pack("<H", 3) + b"\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"
    header += b"data" + struct.pack("<I", len(x))
    with open(path, "wb") as f:
        f.write(header)
        f.write(x)


def read_wav(path: str):
    """Minimal reader: 16/24-bit PCM and 32-bit float, including EXTENSIBLE."""
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:4] != b"RIFF":
        raise SystemExit("not a RIFF/WAVE file")
    pos = 12
    fmt = None
    data = None
    while pos + 8 <= len(raw):
        cid, sz = struct.unpack("<4sI", raw[pos:pos + 8])
        body = raw[pos + 8:pos + 8 + sz]
        if cid == b"fmt ":
            fmt = body
        elif cid == b"data":
            data = body
        pos += 8 + sz + (sz & 1)
    tag, ch, sr_, avg, align, bits = struct.unpack("<HHIIHH", fmt[:16])
    if tag == 0xFFFE:
        tag = struct.unpack("<H", fmt[24:26])[0]   # sub-format
    if tag == 3 and bits == 32:
        a = np.frombuffer(data, dtype="<f4").astype(np.float64)
    elif tag == 1 and bits == 16:
        a = np.frombuffer(data, dtype="<i2").astype(np.float64) / 32768
    elif tag == 1 and bits == 24:
        b = np.frombuffer(data, dtype=np.uint8).reshape(-1, 3)
        a = ((b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8)
              | (b[:, 2].astype(np.int32) << 16)) << 8).astype(np.float64) / 2 ** 31
    elif tag == 1 and bits == 32:
        a = np.frombuffer(data, dtype="<i4").astype(np.float64) / 2 ** 31
    else:
        raise SystemExit(f"unsupported wav: tag {tag} bits {bits}")
    return a.reshape(-1, ch).T, sr_


def _read_wav_lib(path: str):
    with wave.open(path, "rb") as w:
        ch, sw, sr = w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(w.getnframes())
    if sw == 2:
        a = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    elif sw == 3:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        a = ((b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8)
              | (b[:, 2].astype(np.int32) << 16)) << 8).astype(np.float64) / 2 ** 31
    elif sw == 4:
        a = np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2 ** 31
    else:
        raise SystemExit(f"unsupported sample width {sw}")
    return a.reshape(-1, ch).T, sr


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="atmos-control upmix lab")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--compare", action="store_true", help="run the metric suite")
    ap.add_argument("--wav", action="store_true", help="write listening files to out/")
    ap.add_argument("--input", help="stereo WAV to use instead of the synthetic song")
    ap.add_argument("--layout", choices=["51", "714"], default="714")
    ap.add_argument("--quick", action="store_true", help="shorter signals")
    ap.add_argument("--curve", action="store_true", help="print the level-vs-pan curve")
    ap.add_argument("--level", action="store_true",
                    help="print the upmix-on loudness table (bed / binaural / front pair)")
    ap.add_argument("--wav-multichannel", action="store_true",
                    help="also write the raw 5.1/7.1.4 beds (large files)")
    args = ap.parse_args()
    if not (args.all or args.compare or args.wav or args.level):
        args.all = True

    sr = SR
    channels = 12 if args.layout == "714" else 6
    v1, v2 = build(channels)

    if args.all or args.compare:
        print(f"== atmos-control upmix lab · layout {args.layout} · {sr} Hz ==")
        print("   (auto-level disabled in the measurement kernels)\n")
        print("-- level response across the image (steady tone, 17 positions) --")
        for name, (lo, hi, mean) in measure_pan([v1, v2], sr, channels).items():
            print(f"   {name:16s} {lo:+.2f} .. {hi:+.2f} dB  (spread {hi-lo:4.2f} dB)")
        if args.curve:
            print("\n   pan position ->   " + " ".join(f"{p:+5.2f}" for p in np.linspace(-1, 1, 17)))
            for k in (v1, v2):
                lv = []
                n = int(0.6 * sr)
                t = np.arange(n) / sr
                for p in np.linspace(-1, 1, 17):
                    x = 0.4 * np.sin(2 * np.pi * 800 * t)
                    L, R = pan(x, p)
                    ref = bed_power(np.vstack([L, R]))
                    y = k.run(L, R)
                    lv.append(db(bed_power(y, skip=int(0.35 * sr), chans=range(6)) / ref))
                print(f"   {k.name:16s} " + " ".join(f"{v:+5.2f}" for v in lv))
            print()
        print("\n-- centre source --")
        for name, (lvl, cshare) in measure_center([v1, v2], sr, channels).items():
            print(f"   {name:16s} level {lvl:+.2f} dB   centre share {10*math.log10(max(cshare,1e-12)):+6.1f} dB")
        print("\n-- 60 Hz centre bass (surround share; bass must stay in the front) --")
        for name, (lf,) in measure_bass([v1, v2], sr, channels).items():
            print(f"   {name:16s} <120 Hz energy in the surrounds/height, vs input  "
                  f"{10*math.log10(max(lf,1e-12)):+6.1f} dB")
        print("\n-- hard-panned coherent tone (must stay in the front) --")
        for name, (sur, front, l) in measure_hardpan([v1, v2], sr, channels).items():
            print(f"   {name:16s} surround {10*math.log10(max(sur,1e-12)):+6.1f} dB"
                  f"   front {10*math.log10(max(front,1e-12)):+6.1f} dB"
                  f"   L {10*math.log10(max(l,1e-12)):+6.1f} dB")
        print("\n-- fully decorrelated input (ambience must go wide, not away) --")
        for name, (sur, fr, lr, ic) in measure_diffuse([v1, v2], sr, channels).items():
            print(f"   {name:16s} surround share {10*math.log10(max(sur,1e-12)):+6.1f} dB"
                  f"   front/rear corr {fr:.3f}   Ls/Rs corr {lr:.3f}   IACC {ic:.3f}")
        print("\n-- click train + diffuse bed (attack/tail energy in the surrounds) --")
        for name, (r,) in measure_transient([v1, v2], sr, channels).items():
            print(f"   {name:16s} surround attack/tail {10*math.log10(max(r,1e-12)):+6.1f} dB")
        print("\n-- surround-send mask jitter (per-bin gain wobble inside a critical band) --")
        pv1 = KernelV1(channels=channels, probe=True)
        pbin = KernelV2(channels=channels, auto_level=False, band_agg=False, probe=True)
        pbin.name = "v2, per-bin mask"
        pband = KernelV2(channels=channels, auto_level=False, band_agg=True, probe=True)
        pband.name = "v2, band-aggregated"
        probes = [pv1, pbin, pband]
        for name, (jb, js) in measure_mask_jitter(probes, sr, channels).items():
            print(f"   {name:20s} click+bed {jb:5.2f} dB   song {js:5.2f} dB")
        print("\n-- synthetic song: front-stage timbre + binaural width --")
        for name, (dev, ic, ric, bdev) in measure_song([v1, v2], sr, channels,
                                                       dur=4.0 if args.quick else 8.0).items():
            print(f"   {name:16s} front L+R deviation {dev:5.2f} dB"
                  f"   IACC {ic:.3f} (stereo ref {ric:.3f})"
                  f"   eardrum deviation {bdev:5.2f} dB")
        if args.level or args.all:
            print("\n-- loudness with the upmixer engaged (synthetic song, vs plain stereo) --")
            for name, (bed_db, bi_db, front_db) in measure_loudness(
                    sr, channels, dur=4.0 if args.quick else 8.0).items():
                print(f"   {name:22s} bed {bed_db:+5.2f} dB   binaural {bi_db:+5.2f} dB"
                      f"   front pair {front_db:+5.2f} dB")
        print("\n-- passthrough null (strength = 0) --")
        for name, d in measure_null([v1, v2], sr, channels).items():
            print(f"   {name:16s} max |out - in| = {d:.3e}")
        print()

    if args.all or args.wav:
        outdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
        os.makedirs(outdir, exist_ok=True)
        if args.input:
            x, sr = read_wav(args.input)
            if x.shape[0] == 1:
                x = np.vstack([x, x])
            L, R = x[0], x[1]
            peak = max(np.abs(L).max(), np.abs(R).max())
            L, R = L / peak * 0.5, R / peak * 0.5
        else:
            L, R = song(sr, 12.0)
        for k, tag in ((v1, "v1"), (v2, "v2")):
            y = k.run(L, R)
            if args.wav_multichannel:
                p = os.path.join(outdir, f"song_{tag}_{args.layout}.wav")
                write_wav(p, y, sr, args.layout)
                print(f"wrote {p}")
            bl, br = binaural_render(y, channels, sr)
            p2 = os.path.join(outdir, f"song_{tag}_{args.layout}_binaural.wav")
            write_wav(p2, np.vstack([bl, br]) * 0.7, sr, "stereo")
            print(f"wrote {p2}")
        write_wav(os.path.join(outdir, "song_input_stereo.wav"), np.vstack([L, R]), sr, "stereo")
        # a plain-stereo binaural reference: L/R placed at +-30 deg, no upmix
        bed = np.zeros((12, len(L)))
        bed[CH_L], bed[CH_R] = L, R
        az_save = AZ_714.copy()
        AZ_714[CH_L], AZ_714[CH_R] = -30, 30
        bl, br = binaural_render(bed, 12, sr)
        AZ_714[:] = az_save
        write_wav(os.path.join(outdir, "song_stereo_binaural_ref.wav"),
                  np.vstack([bl, br]) * 0.7, sr, "stereo")
        print(f"wrote {os.path.join(outdir, 'song_stereo_binaural_ref.wav')}")


if __name__ == "__main__":
    main()
