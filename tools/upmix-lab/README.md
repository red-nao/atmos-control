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
| `KernelV1` | a faithful port of the kernel that shipped before the quality pass (Classic) |
| `KernelV2` | the design the Natural kernel follows, with every change switchable |
| measurement suite | pan sweep, centre, bass, hard-pan, diffuse, transient, mask jitter, null, loudness |
| binaural monitor | cheap HRTF (Woodworth ITD + head shadow + pinna notch) so width/front-back is audible |
| WAV I/O | 48 kHz IEEE-float WAVE_FORMAT_EXTENSIBLE, 5.1 / 7.1.4 / stereo |

Results live in `results/` (see `docs/UPMIX-QUALITY.md` for what the numbers mean and what the targets
are). The listening WAVs and the raw multichannel beds are large and regenerable, so they go to `out/`
(git-ignored) — regenerate them with `--wav`.

Note: this is a *model* of the Swift code, not the Swift code itself. It exists to make the DSP
decisions measurable and reviewable; the app is the ground truth.
