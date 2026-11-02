# Full-swing recording analysis — v3

Source: `logs/radar-live/1793624821430555760-2948/` on the radar computer.
Analysis uses a frozen event prefix through the last completed capture; the live
service can keep recording. Original recordings and operator annotations are preserved.

## Results on all 43 annotated attempts

| Metric | Recorded/current v2 replay | v3 replay |
| --- | ---: | ---: |
| Labelled-hit windows with a registered ball | 26 / 35 | 28 / 35 |
| Labelled hits still unconfirmed | 9 | 7 |
| Hit-window recall | 74.3% | 80.0% |
| Labelled misses with a false detection | 0 / 8 | 0 / 8 |
| Windows with duplicate balls | 0 | 0 |

Two of nine missed-hit windows are recovered (22.2% fewer missed hits). All 26
previously registered shots retain the same estimates and selected observations.
The new detections also select independently identified ball returns, rather than
accepting club fragments just to improve the hit count.

These are **hit/miss detection results**, not independently measured speed/angle
accuracy. The qualitative labels are useful context; they are not enforced as exact
angles or speeds. In particular, an unchanged “straight” label does not override the
measured lateral trajectory. Eight negative recordings do not establish a universal
zero false-positive rate.

| Operator's radar-setup tag | Hits | v2 registered | v3 registered | Labelled misses |
| --- | ---: | ---: | ---: | ---: |
| 1.5m behind | 25 | 21 | 22 | 1 |
| 1.5m behind and straight | 10 | 5 | 6 | 7 |

This is not a controlled orientation experiment: shot types, visibility and swing
motion also vary. The second subgroup's lower recall does not by itself establish
that standing the radar upright caused the misses.

## Recovered failure mode: ball observations inside their own club envelope

Captures 15 and 28 (IDs ending **117** and **176**) contain a coherent outgoing
band at about 11 m/s and 9 m/s respectively, alongside a separately slowing club.
The first ball band continues to about 4.49 m radar range, the second to about 3.52 m.

The club graph can follow early club observations and then switch onto the ball.
V2 conservatively unions related braking paths. A club-to-ball branch shares an
early prefix with the real club; the union consequently includes the ball itself.
The valid ball candidate is then rejected for lying inside the club envelope or
sharing observations with its supposed club reference.

V3 adds a separate evidence path:

1. Retain the existing conservative envelope decision.
2. For an otherwise physically valid rejected candidate, remove its observations
   from a possible reference and **revalidate that reference**: independent support,
   association gaps, global range/Doppler agreement and sustained braking must hold.
3. Require actual simultaneous independent observations, a statistically resolved
   forward frontier and increasing relative velocity. Interpolated references do
   not count toward the minimum actual concurrent evidence.
4. Require cumulative Doppler deceleration consistent with free outgoing motion.
   Edge-wise quantization allowances cannot accumulate into a slowing club tail.
5. Reject a club/ball explanation if **one free-flight model explains both sets**.
   Quantized speed changes along a lone ball must not manufacture its own “club”.
6. Count the additional model comparisons against the existing fit-work budget.
   Incomplete validation remains unconfirmed.

The recovered paths have 5 and 8 actual independent concurrent observations, with
forward-frontier significances about 7.0 and 10.5. Estimated launch values are:

| Capture suffix | Speed | Direction | Elevation |
| --- | ---: | ---: | ---: |
| 117 | 11.33 m/s / 40.8 km/h | 1.3° right | 14.1° |
| 176 | 9.49 m/s / 34.2 km/h | 7.5° left | 14.7° |

These fitted estimates are not external ground-truth measurements.
There are no room, pillow, tee-distance, shot-ID, frame-number or speed-band tests
in the production detector. The new diagnostic version is
`backward_independent_split_v3`, with validation mode
`independent_concurrent_outgoing_split`.

## Why seven labelled hits remain unconfirmed

| Capture suffix | What the recording supports |
| --- | --- |
| 84 | Three late, slow outgoing returns around 2.15–2.54 m; the independent separation from the observed club reach is unresolved. This is an ambiguous tail, not proof that no ball was hit. |
| 106 | Two clear fast candidate observations at frames 38688 and 38690, about 21.05 and 20.59 m/s. No third consistent fast observation establishes a confirmed path. |
| 142 | Sparse fast observations, including an isolated approximately 18.3 m/s return; the longer visible band decelerates like the club. No separately supported ball path is established. |
| 212 | An isolated approximately 22.9 m/s observation and later sparse returns; no three-observation, independently detached flight survives the physical checks. |
| 222 | An isolated faster observation near frame 70282; the longer remaining track is consistent with the slowing club, not a confirmed separate flight. |
| 235 | Two approximately 16.0 m/s returns at frames 72848–72849; the following visible band decelerates. There is no third independently supported fast return. |
| 239 | The available moving track mainly follows the accelerating/braking club. Other returns do not establish a separate coherent free flight. |

The original UART/point recordings cannot establish which missing returns were
lost to antenna sensitivity, firmware CFAR, velocity aliasing, occlusion or another
acquisition effect. The existence of a real hit and the existence of enough
independent radar observations to confirm it are different questions. A future
two-observation mode would need its own strong uncertainty/separation validation
and substantially more negative data; simply lowering the minimum support would
make club fragments easier to mistake for balls.

The saved waveform is **50 Hz / 20 ms**, with approximately **0.195 m range bins**,
**0.458 m/s Doppler bins** and **29.28 m/s maximum unambiguous radial velocity**.
The firmware output gate is 0…29 m/s. Approximately 105 km/h is therefore a radial
velocity capability limit, not a guarantee for every full-speed golf shot. The
qualitative “full speed” label is not evidence that a particular shot exceeded it.
Faster framing with a validated hardware processing budget is a useful acquisition
experiment for short visible flights; it is not a replay-software fix for returns
that were never recorded.

## Upright radar 1.5 m behind the ball

Assuming the standard **IWR6843ISK**, antenna face vertical, nominal pointing
horizontal along the target line, and approximately tee-level antenna height:

- TI specifies **120° azimuth FoV and 30° elevation FoV**, approximately ±15°
  vertically around the antenna's pointing direction. This is nominal antenna
  coverage, not a hard boundary beyond which radio waves cease to exist.
- `aoaFovCfg -1 -90 90 -90 90` accepts reported angles over a wide interval. It
  does not widen the physical antenna pattern or guarantee accurate ±90° tracking.
- At the ball, 1.5 m ahead, the nominal upper coverage is only about **0.40 m above
  the antenna**. At 2.5 m and 3.5 m ahead it is about 0.67 m and 0.94 m.

Thus **level/upright is a reasonable starting alignment, but 1.5 m behind is not
a guarantee of all golf launch angles**, particularly lofted shots. For illustration,
ignoring gravity/drag and assuming equal antenna/launch height, the forward distance
after impact before crossing the nominal upper boundary is

```text
x_exit = 1.5 × tan(15°) / (tan(launch_angle) − tan(15°))
```

For a 30° launch this is about 1.30 m; for 45° about 0.55 m. At 20 m/s ball speed,
the corresponding visibility times are about 75 ms and 39 ms: roughly four and two
50-Hz sampling intervals. Frame phase, return strength, trajectory curvature and
the soft antenna pattern affect actual observations. This illustrates a sampling
constraint; it is not a diagnosis of a particular missed shot.

There is no single “highest wave.” For the nominal upper-beam line, ceiling height
`H`, antenna height `h`, and upward antenna pitch `p`, the horizontal intersection is

```text
d_ceiling = (H − h) / tan(p + 15°)
```

For example, a 2.4 m ceiling and 0.2 m antenna height with level pointing give about
8.2 m horizontally, beyond this recording's 7 m range gate. Sidelobes and indirect
ceiling reflections can still occur at nearer ranges. Ceiling reflections do not
imply that the whole ball trajectory is inside useful antenna coverage.

A modest upward pitch can extend lofted-flight coverage while keeping the tee
visible, depending on antenna/ball heights. The configured forward/up axes must
then describe that mounting, or reported elevation and gravity fitting remain in
the wrong coordinate system. Raising the radar's height is different from changing
its pitch: the ball must remain in the antenna's near-launch view.

Source: [TI IWR6843ISK antenna specifications](https://www.ti.com/tool/IWR6843ISK).
Other antenna variants, such as ISK-ODS, have different patterns.

## Regression coverage and reproduction

The existing seven independently labelled positive captures still pass, including
their ball-withheld and ball-only controls. The new compact fixture adds both
recovered positives and all eight real dry/missed-swing recordings. It also checks
ball-withheld and ball-only versions and repeats the same point clouds under a
30° coordinate rotation with the corresponding calibrated forward/up axes.

```bash
cargo test --manifest-path radar_app/Cargo.toml
python3 -m unittest tests.test_shot_regression tests.test_rust_live
```

These checks passed: **49 Rust tests and 16 Python/integration tests**. The new
recorded-data check runs the actual Rust replay executable, verifies independent
ball-point membership, and requires zero detections on the negative controls.

For the full private session, use `replay-live SESSION detector.json report.json`
on the baseline and updated binaries with the same saved observations. On the local
development machine the maximum per-attempt analysis time in this replay increased
from about 1.4 ms to 4.8 ms; no attempt exhausted its fitting budget. This is not a
Raspberry Pi timing measurement. The Pi's running detector must be rebuilt/restarted
to use the updated source.
