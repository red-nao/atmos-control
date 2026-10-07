# upmix-lab

Offline measurement + listening bench for the STFT upmixer (`Sources/SpatialEngine/STFTUpmixer.swift`).
NumPy only — no build step, no Xcode, no audio device.

```bash
python3 upmix_lab.py --compare --level --curve --layout 714   # metric suite + loudness
python3 upmix_lab.py --compare --layout 51                    # 5.1
python3 upmix_lab.py --wav --layout 714                       # listening files into out/
python3 upmix_lab.py --wav --input ~/Music/test.wav           # your own stereo file
python3 upmix_lab.py --wav --layout 714 --wav-multichannel    # raw beds (large)
```

What it contains:

| Piece | What it is |
|---|---|
| `KernelV1` | the first-generation kernel — the "Classic" one that has since been **deleted from the app and the UI**. Kept here because it is the baseline every before/after number in `docs/UPMIX-QUALITY.md` is measured against |
| `KernelV2` | the kernel that ships, with every design change switchable (`v2 (shipped)`) |
| measurement suite | pan sweep, centre, bass, hard-pan, diffuse, transient (with a click-level sweep + false-trigger duty), mask jitter, null, loudness |
| binaural monitor | cheap HRTF (Woodworth ITD + head shadow + pinna notch) so width/front-back is audible |
| WAV I/O | 48 kHz IEEE-float WAVE_FORMAT_EXTENSIBLE, 5.1 / 7.1.4 / stereo |

Results live in `results/` (see `docs/UPMIX-QUALITY.md` for what the numbers mean and what the targets
are). The listening WAVs and the raw multichannel beds are large and regenerable, so they go to `out/`
(git-ignored) — regenerate them with `--wav`.

Note: this is a *model* of the Swift code, not the Swift code itself. It exists to make the DSP
decisions measurable and reviewable; the app is the ground truth.

Two rules the metrics depend on:

- **A fresh kernel for every condition.** `KernelV1/V2.clone()` rebuilds a kernel from its
  constructor arguments, and the transient sweep / mask-jitter metrics use it, because the running
  masks, slow power and gate otherwise leak from one signal into the next and silently change the
  result. A single shared kernel across the bed + four click levels once produced five identical,
  meaningless rows.
- **The false-trigger reference must be genuinely stationary.** `click_bed(clicks=False)` is *not*:
  the bed is shaped around the click slots, so half-window statistics see steps there. Use the
  Gaussian bed built inside `measure_transient_sweep`.

`KernelV2` defaults describe the **shipped** kernel: one window, flux ratio 1.6, a 6-frame hard
gate (0.15) whose depth the `transient` parameter scales linearly. The multi-resolution experiment
of `docs/UPMIX-QUALITY.md` §3.5 is `multi_res=True` plus `onset_mode`; it is off by default and the
measurements say it should stay that way.
