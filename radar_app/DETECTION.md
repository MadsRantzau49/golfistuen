# Live ball detection and recorded-shot analysis

## Analysis of the 2026-10-29 recording

Source: `logs/radar-live/1793282339202354539-12936/` under `radar_app/`.
The original session contains 5,226 frames, 4,364 points and ten original motion
triggers. All ten were rejected by the previous fixed-zone detector.

Inspecting the **original points**, including points the old filters excluded,
reveals two simultaneous velocity groups in triggers **1, 3, 4, 6, 7, 9 and 10**:
an outgoing, approximately 12–16 m/s object and a slower/decelerating club track.
The faster object first becomes visible well inside the old 2.75 m ball gate.
Triggers **2, 5 and 8** contain low-speed motion without a separately identifiable
ball trajectory. These are observations, not video-verified ground-truth labels:
if a ball was hit during those intervals, this recording does not resolve it.

| Original trigger | Previous failure | Adaptive replay |
| --- | --- | --- |
| 1 | Two surviving points were split into singleton tracks; most flight points were discarded | Ball confirmed |
| 2 | No points survived the distance/speed gates | No separate flight confirmed |
| 3 | All faster early-flight points were inside the club exclusion zone | Ball confirmed |
| 4 | Same exclusion; also an additional fixed SNR cutoff | Ball confirmed |
| 5 | Low-speed motion; no separate faster trajectory identified | No separate flight confirmed |
| 6 | One surviving point; earlier flight excluded | Ball confirmed |
| 7 | Fixed 12 cm straight-line residual cutoff | Ball confirmed |
| 8 | Low-speed motion; no separate faster trajectory identified | No separate flight confirmed |
| 9 | All visible ball-flight points were inside the exclusion zone | Ball confirmed |
| 10 | First surviving point arrived after the fixed 180 ms deadline | Ball confirmed |

The uploaded waveform gives a **0.1953125 m range bin**, approximately
**0.457527 m/s Doppler bin**, and **20 ms frame period**. A fixed 12 cm maximum
XYZ deviation ignored both range quantization and much larger angular uncertainty.
There are also missing ball returns; the previous nearest-neighbour tracker split
otherwise coherent observations rather than carrying a motion prediction over gaps.

The adaptive replay confirms the seven separate-flight traces and no additional
balls in this recording. It also reports weaker motion attempts that the old
2 m/s trigger ignored; an attempt is not counted as a ball. This positive session
does not establish a real-world false-positive rate. Dedicated dry-swing recordings
are still needed in addition to the synthetic club-only regression cases.

## Detection model

The live and replay paths use the same `ShotDetector` implementation:

1. **Read the actual waveform.** Range/Doppler bin widths, frame period and the
   acquisition FOV come from the supplied `profileCfg`, `chirpCfg`/`frameCfg`, and
   range `cfarFovCfg`. The implementation supports the standard single-profile
   TDM frame configuration. It never assumes a tee at 2 m, a 7 m software gate,
   a 50 Hz sensor, or a particular measured shot speed.
2. **Estimate background motion.** A rolling median/MAD with a Doppler-quantization
   uncertainty floor separates moving returns from stationary background. It
   replaces the fixed 2 m/s software cutoff. Firmware CFAR still determines which
   points reach the app; the app adds no fixed SNR rejection threshold.
3. **Keep alternative trajectories.** Range integration, Doppler and spatial
   prediction are compared in sensor-uncertainty units. Branches retain both a
   longer existing path and a newly appearing launch path, rather than always
   assigning a ball return to the nearest club point. Configured missing-frame
   tolerance carries hypotheses through absent returns.
4. **Fit flight jointly.** Weighted position and Doppler observations estimate
   position/velocity, with gravity and locally approximated quadratic air drag.
   Radial and angular measurement errors are treated separately. Angular error
   also propagates into the Doppler projection; noisy direction cosines are not
   treated as exact. The model-consistency decision uses a normalized residual
   statistic and its degrees of freedom, not a maximum XYZ error in metres.
5. **Require independent club evidence.** A candidate needs observed motion
   preceding its launch, a spatial connection to that motion, and multiple
   simultaneous observations of a separate slower moving object. Detachment must
   be resolved through growing relative velocity or spatial separation above the
   measurement uncertainty. A single straight club path or a ball-only path cannot
   satisfy this two-object test. Absolute ball distance and centerline width play
   no role in classification.
6. **Close on evidence/quiet.** Tracks resolve after missing returns or quiet
   frames. There is no fixed arrival deadline measured from the club's first
   motion. A configurable event-size cap bounds CPU/memory for persistent clutter;
   rearming depends on quiet observations rather than a fixed 500 ms delay.

## Configuration and assumptions

`configs/swing.json` exposes the complete set of statistical settings, sensor-array
uncertainty calibration, ball/air parameters, minimum evidence and resource limits.
It contains **no shot-specific locations or speed/timing cutoffs**. Defaults are
general statistical confidence levels and physical/sensor assumptions, not values
fitted to this recording. Unknown/obsolete fields fail validation, so an old
`max_swing_distance_m` or `club_clearance_m` file cannot silently keep those gates.

- Range and Doppler standard deviations start from bin width / sqrt(12), the
  quantization uncertainty of a uniform bin. `measurement_uncertainty_scale` is
  an explicit calibration factor for additional installation/sensor error.
- `azimuth_resolution_sine` and `elevation_resolution_sine` default to the
  IWR6843ISK virtual-array geometry (eight azimuth/four elevation elements). Array
  layout is **not encoded in a TI CFG**: change these calibration settings for a
  different board. They are uncertainty estimates, not launch-angle restrictions.
- `forward_axis` and `up_axis` describe the radar mounting; defaults are +Y/+Z.
  There is no fixed lateral lane or maximum direction/elevation angle.
- Ball diameter/mass, air density and drag coefficient are physical priors and
  are configurable. Acceleration is locally approximated over the observed short
  flight segment; this is not a full outdoor flight/spin estimator.
- All sigma levels, evidence counts, fit iterations, gap/quiet/context frames and
  hypothesis/event caps are serialized into the live session metadata. Resource
  settings trade computation against the number of competing trajectories kept.

The app cannot reconstruct a ball the firmware did not report, remove velocity
aliasing from insufficient data, or reliably distinguish physically ambiguous
club/ball observations. Short/noisy trajectories can have substantial angle
uncertainty even when outward speed is resolved. Fit residuals, velocity standard
deviations, chosen hypotheses and the club-detachment evidence are logged for
inspection. The physical acquisition setup and real dry-swing validation matter.

## Reproduce analysis

From `radar_app/`:

```bash
cargo run --release -- replay-live \
  logs/radar-live/1793282339202354539-12936 configs/swing.json \
  logs/radar-live/1793282339202354539-12936/adaptive-replay.json
```

This uses the recording's `radar.cfg`, original decoded points and arm/reset
history. Every point is re-evaluated; original filter decisions are not reused.
Original swing numbers are attached to overlapping replay attempts for comparison.
The replay preserves the original arm history rather than simulating the game
disarming after a newly accepted shot. A replay end with an unresolved attempt is
reported as aborted, never promoted to a ball merely because the file ended.

From the repository root, inspect rejected points and chosen fit uncertainties:

```bash
python3 tools/analyze_live_session.py \
  radar_app/logs/radar-live/1793282339202354539-12936 \
  --summary-only --replay-report \
  radar_app/logs/radar-live/1793282339202354539-12936/adaptive-replay.json
```

Omit `--summary-only` for a point-by-point view around each original trigger.
`--before-s`, `--after-s` and `--min-speed-mps` control this **report view** only;
they never change the detector or label observations as club/ball. `--out` saves
the original-point report as JSON. All original capture files remain intact.
