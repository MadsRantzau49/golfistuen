# Radar debug range — a 3D movie of the actual measurements

Open **05 · Radar debug range · 3D capture** from Pinewater's main menu.
This instrument view displays the radar's raw point returns over time, including
stationary/filtered points, club motion, people and reflections. It also shows the
trajectories considered by the detector and why an attempt was accepted/rejected.

These are sparse radar measurements, **not camera footage or reconstructed meshes
of people/clubs**. Unclassified points are not automatically labelled objects.

## Live capture

1. Restart the updated Rust `live` service using your usual command, for example
   from `radar_app/`:

   ```bash
   cargo run --release -- live configs/golf.cfg \
     /dev/ttyUSB0 /dev/ttyUSB1 0.0.0.0:8765 configs/swing.json
   ```

2. Rebuild/relaunch the game, open **Radar debug range**, enter the radar computer's
   host/IP and port **8765**, and click **Connect**. It initially uses the endpoint
   saved by the game's Real-mode settings.
3. Swing normally. Raw frames arrive continuously; a completed attempt appears in
   the list even when the result is **UNCONFIRMED** or **INTERRUPTED**.
4. **Replay each new attempt** automatically opens a before/after movie. Turn this
   off to inspect an older attempt while capture continues.

The debug subscription continuously evaluates attempts without consuming a golf
turn. It does not launch simulated balls, add strokes or wait for the golf flight
animation. The service supports one active game/instrument connection; opening
this mode replaces an existing gameplay connection. Leaving debug disconnects the
instrument. The Rust service keeps its always-on recording independently.

### Label hits that the detector missed

Immediately after an actual hit, click **Mark live hit** or press **M**. Use
**Dry swing** for a club-only swing. The last **three seconds** of live observations
are frozen for replay/export, even if the detector never generated an attempt.
An optional note can describe the club, ball/contact, placement or expected result.

When connected, these labels are also appended to the radar session as
`operator_mark` events and appear in its saved-attempt list. The UI confirms when
the label is saved on the radar computer. Disconnected marks remain local until
you export their clip. Labels are operator ground truth, separate from detector
verdicts; they never change the algorithm or automatically turn a miss into a shot.

## Movie and camera controls

| Control | Action |
| --- | --- |
| **Right-drag** | Orbit around the current focus |
| **Middle-drag** | Pan |
| **Mouse wheel** | Zoom |
| **Orbit / Top / Side / Front** | Camera presets |
| **Ortho** | Orthographic projection for measuring paths |
| **Fit** or **F** | Frame the current movie's raw observations and radar origin (a nearby window for very long recordings) |
| **Click a point** | Inspect its XYZ, radial speed, SNR/noise and point-gate reason |
| **Space** | Play/pause the movie |
| **Left / Right** | Step one recorded frame |
| **Timeline slider** | Scrub the selected attempt/window |
| **0.1× / 0.25× / 0.5× / 1× / 2×** | Playback speed |
| **Loop** | Repeat the current movie window |
| **Follow live** or **L** | Return to the most recent raw frames |
| **All loaded frames** | Clear attempt overlays and browse the loaded recording/buffer |
| **Clip around current frame** | Select before/after context at any loaded time, including an untriggered hit |
| **Escape / Main menu** | Leave the debug range |

Pausing the movie does **not** stop live acquisition or recording. Before/after
controls change the displayed context only; they do not change detection timing.
Frame spacing and gaps use the recorded timestamps. Raw point positions are not
interpolated into invented observations.

Radar coordinates stay in **metres**: +X right, +Y downrange, +Z above the radar.
The scene mapping is `(X, Z, -Y)`. The one-metre grid is the **radar Z=0 plane**,
not an automatically calibrated physical floor. Marker radius is an adjustable
display size, not a measured golf-ball diameter.

## Understand a decision

- **Raw colors:** choose Doppler speed, point eligibility or SNR. Background and
  rejected points are visible by default. Passing a point gate does not mean a
  point was classified as a ball.
- **Green:** observations on the detector's selected ball track.
- **Purple:** observations used as independent club evidence (an inference).
- **Orange:** the hypothesis currently chosen in the inspector.
- **Gold:** its fitted motion model, distinct from the measured observations.

Select an attempt, then choose a hypothesis in **What the detector considered**.
Every transferred hypothesis retains its original observations, model and rejection
reason. **All considered trajectories** displays the competing paths together.
**Show whole-attempt trajectories** includes later observations as an explicit
overlay; normally trajectories advance with the movie frame. Point persistence
leaves a short fading history and can be reduced to zero for a pure frame snapshot.

The inspector shows the recorded result, point rejection counts, chosen hypothesis,
normalized model residual/limit, velocity uncertainty and club/flight separation
evidence when supplied by that detector version. Old recordings remain viewable
even if they only contain the earlier estimator's fields. Loading a recording
shows the decisions that were actually logged; it does not silently re-run or
replace them with the current algorithm.

## Browse recordings across the LAN

While connected, press **↻** beside the source selector. Choose a session from the
radar computer, select an attempt, and the raw before/after frames and complete
attempt diagnostics are transferred to the game. The current session is included,
so you can reload a complete clip if live streaming reported a gap. Operator marks
provide selectable clips for hits without automatic attempts.

Archive indexing/reading runs on a background worker, leaving serial acquisition
on its normal loop. Network transfer is chunked and bounded. A slow viewer can
drop whole live-preview frames or reports; the status line reports those counts.
The always-on raw/event recording remains the source for a complete reload.

The remote picker lists the latest 1,000 sessions/attempts. For older attempts or
arbitrary times without an attempt/mark, use a local recording folder and **All
loaded frames**. Refresh the session to include newly completed attempts/marks.

## Local recordings and portable clips

- **Open folder:** choose a folder containing `session.json` and all its
  `events-*.jsonl` segments. No running radar service is required. Files are indexed
  incrementally; raw points and reports are read on demand rather than retaining
  an entire long recording in memory. An incomplete trailing line in an active
  recording is reported and ignored; malformed complete records produce an error.
- **Export selected clip:** writes a portable `.json` with raw frames, timestamps,
  the selected attempt's full diagnostics, configuration and your note. Share this
  to investigate a missed hit or false positive.
- **Open clip:** reopens that portable file on another computer, without hardware.
- **Copy diagnostic summary:** copies the current frame, inspected hypothesis,
  chosen fit, configuration and note to the clipboard.

The live buffer retains up to 9,000 frames / 120,000 raw points, plus bounded
attempt diagnostics. Older frames remain on the radar computer and can be reloaded.
Local indexing supports up to one million frame references and uses a small point
cache. Single clip/transfer budgets are bounded; an oversized request gives an
explicit error so you can reduce context. These are viewer/transport resource
limits, not detection thresholds.

### Developer shortcuts

From the repository root:

```bash
python3 tools/run_range.py --radar-debug
python3 tools/run_range.py --radar-session radar_app/logs/radar-live/SESSION
```

Packaged games need rebuilding to include this new mode:

```bash
python3 tools/build_range.py --target linux windows
```

Checks include actual fragmented/chunked TCP messages, all raw background points,
failed-attempt replay, timeline stepping, point inspection, clip round trips,
indexed folders, navigation and a serial-emulated backend debug subscription:

```bash
cargo test --manifest-path radar_app/Cargo.toml
python3 -m unittest tests.test_rust_live
python3 tools/run_range.py --check
```

Set `RADAR_DEBUG_TEST_SESSION` to a local session path when running
`res://tests/radar_debug_checks.gd` directly to also exercise actual captured
points and saved reports in the viewport.
