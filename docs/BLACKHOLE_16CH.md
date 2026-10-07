# Surround 7.1.4 via BlackHole 16ch

An alternative to the bundled HAL driver for the `Surround 7.1.4` capture mode.
`BlackHole 16ch` (Existential Audio) works as a multichannel loopback device,
with one practical advantage: **System Integrity Protection (SIP) can stay enabled**.

Device selection is automatic: when both are installed, the bundled
`atmos-control` driver (exact 12ch) is preferred; otherwise `BlackHole 16ch` is used.
The active capture device is shown in `Settings > Output` as `Surround input: ...`.

## 1. Install

```bash
brew install blackhole-16ch
sudo killall -9 coreaudiod
```

Alternatively, use the official installer from
[ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole)
and restart the Mac.

Checklist:

- `BlackHole 16ch` appears in `Audio MIDI Setup`.
- Its sample rate is set to `48 kHz` (a mismatch forces the engine to rebuild).
- No bundled driver is required: install the app without it:

```bash
./install.sh   # without --with-driver
```

## 2. Select the capture mode

`Surround 7.1.4` hijacks the system default output to the loopback device.
Personalized HRTF is unavailable in this mode (generic HRTF only).

1. Open `Settings > Output > Audio capture` and select `Surround 7.1.4`.
2. Set `Output device` to headphones (for example AirPods), or `Follow system default`.
3. Power on. The system default switches to `BlackHole 16ch` (or the bundled driver).
4. Power off or quit to restore the previous default automatically.

## 3. Channel mapping

The engine consumes 12 channels. From a 16-channel device only the first
12 planes are used; channels 13–16 are ignored.

| ch | Speaker | ch | Speaker |
|----|---|---|---|
| 1 | Front Left | 7 | Rear Left |
| 2 | Front Right | 8 | Rear Right |
| 3 | Center | 9 | Top Front Left |
| 4 | LFE (unspatialized) | 10 | Top Front Right |
| 5 | Surround Left | 11 | Top Rear Left |
| 6 | Surround Right | 12 | Top Rear Right |
| 13–16 | Unused | | |

## 4. Speaker assignment in Audio MIDI Setup (required)

Selecting the `7.1.4` layout is not enough. The per-speaker `Channel`
column must be set to `1–12` by hand. Fresh `BlackHole 16ch` installs
typically leave the rears unassigned (`-`) and map the heights to `13/15`,
in which case channels 7–12 never reach the engine.

In `Audio MIDI Setup > BlackHole 16ch > Configure Speakers`, with
`Configuration: 7.1.4`, assign from top to bottom:

```
Left → 1, Right → 2, Center → 3, Subwoofer → 4,
Left Surround → 5, Right Surround → 6,
Left Rear Surround → 7, Right Rear Surround → 8,
Left Top Front → 9, Right Top Front → 10,
Left Top Rear → 11, Right Top Rear → 12
```

Choose each value from the dropdown, then press `Apply`.
Leave channels 13–16 unassigned.

Note: the speaker-test buttons play directly into `BlackHole 16ch`,
so they sound silent on their own. That is expected. With the engine
powered on in `Surround 7.1.4` (capture = BlackHole, output = headphones),
pressing the test buttons produces spatialized sound on the headphones:

```
BlackHole 16ch → atmos-control → AUSpatialMixer → headphones
```

## 5. Settings to avoid double processing

- Turn system Spatial Audio **off**
  (`Control Center > Sound > headphones > Spatial Audio`), otherwise audio
  is spatialized twice.
- `Apple Music > Settings > Playback > Dolby Atmos`: `Automatic` for
  `Surround 7.1.4`. Set it back to `Off` for Personalized / Stereo capture.

## 6. Verification

Run the `Audio MIDI Setup` speaker test for the `7.1` layout described above.
Front, side, and rear directions should be clearly distinguishable.
Height channels (9–12) are rendered in the graph but are less thoroughly
validated subjectively (see upstream
[yukij3/atmos-control#1](https://github.com/yukij3/atmos-control/issues/1)).

## 7. Troubleshooting

- `Surround needs a 12-channel loopback`: no surround-capable device was found.
  Confirm a device with `BlackHole` in its name and at least 12 channels exists.
  The `Surround input:` row shows `—` when nothing is detected.
- Test tones are silent: the engine is not running in `Surround 7.1.4` mode,
  or its capture device is not `BlackHole 16ch`. Power the engine on first.
- Default output stuck on `BlackHole 16ch`: set it back in
  `Control Center > Sound`. Powering the engine off normally restores it.
- `Upmix` unavailable: by design. `Surround 7.1.4` is already multichannel,
  so the stereo-to-surround upmixer does not apply.
- Personalization shows `Generic`: by design. The loopback path cannot carry
  a personalized profile. Use `Personalized (headphones)` capture for
  personalized HRTF.

## 8. Implementation notes

- `Sources/SpatialEngine/Devices.swift`: `findBlackHole16chDevice()`
  (name contains `blackhole`, ≥12ch), `findSurroundCaptureDevice()`
  (bundled driver preferred, then BlackHole), `isVirtualLoopbackDevice()`.
- `Sources/SpatialEngine/SpatialEngine.swift`: `surroundDriverInstalled()`
  accepts either backend; `outputDevices()` excludes both loopbacks from sink
  candidates; `start()` requests the engine width (12ch) and falls back to the
  native width, consuming only the first planes.
- `Sources/AtmosControlApp/EngineController.swift`: `startLoopbackMode()`
  captures from `surroundCaptureDeviceID()`; power-off restores the default
  for either backend.
