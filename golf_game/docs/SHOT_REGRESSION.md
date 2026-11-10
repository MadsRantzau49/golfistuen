# Shot-note regression testing

Historical reference: the replay and regression services described here were
removed when restoring the first-draft radar tracker. These commands are not
available in the current backend.

Shot notes are the ground-truth dataset for detector changes. One Space-to-Space
window is one attempted shot, including missed swings and undetected real hits.
The runner reuses Rust's real detector and the recorded observations/arming history;
it does not test against the previous detector's decisions.

## Recommended: use the game UI

Open **Shot notes → Regression tests**, using the same connection as for recording.
Choose conditions from dropdowns, click **Next**, enter pass ranges/tolerances,
then click **Run tests on matching recordings**. No terminal commands or JSON are
needed. The speed-range form uses km/h and converts to the framework's m/s units.
Save criteria under a name to reuse them later. Results are saved automatically.

Select a saved result under **Compare with a saved result** to restore its matching
conditions and acceptance criteria. Run again after rebuilding/restarting the radar
service to evaluate the new running detector. Results show overall and clustered
counts, measurement errors, individual expected/actual values, and baseline changes.
You can open any result's shot directly in Shot notes. **Delete selected shot** in
history removes that capture from future test selections; raw data shared by other
shots is retained. See [the UI walkthrough](SHOT_NOTES.md#regression-tests-inside-the-game).

Background jobs use the same evaluator described below and run on the radar
computer. Saved UI profiles/results live under `<recordings-root>/.regression/`.
The game can run on another computer without local recordings or Python. Reconnect
and reopen the tool to recover an ongoing/completed task. One task runs at a time;
capture/annotation/deletion changes wait for it to finish. Historical notes are
available across service restarts.

Replays freeze each selected session's event prefix through the latest selected
window's end marker. Continuous logging after those windows cannot invalidate a
baseline or expose a partially written UART event to replay. Changing recorded
observations inside that prefix, annotations, selection or criteria still makes the
comparison invalid. Baselines from the earlier whole-session fingerprint format
need to be regenerated once.

The remaining sections describe the optional CLI and advanced extensions.

## 1. Capture independent truth

Open `python3 tools/run_range.py --shot-notes` and record windows as described in
[SHOT_NOTES.md](SHOT_NOTES.md). Mark **hit / miss** yourself. A detector rejection
is not evidence of a miss. Use unknown when you cannot establish the outcome.

Name the room, radar placement revision, ball type, launch surface and support
movement. In particular, label a moving pillow rather than treating its returns as
ball truth. Additional context tags are unrestricted categories: room dimensions,
radar height, club, lighting, operator or future equipment can all be represented
without changing code. Change the setup name whenever radar placement/alignment
changes. Contexts and qualitative labels carry into the next shot.

Enter exact measured values when available. Speed supports km/h (km/t) or m/s;
angles use degrees, left negative/right positive. Travel distance uses metres.
Additional measurements allow future metrics. Exact measurements start empty on
each new shot. Never copy the detector's estimate into ground truth.

Keep each **whole session directory**, including `radar.cfg`, `session.json`,
`events-*.jsonl`, raw segments, and `captures/*.json`. The form/exported JSON alone
does not include the observations needed for replay. Run the commands below on
the radar computer, or copy the complete recordings to a development computer.

## 2. Inspect and choose the matching dataset

From the repository root (Python standard library and Rust toolchain required):

```bash
python3 tools/shot_regression.py inventory logs/radar-live
```

Pass a single session, a recordings root, or several roots. Discovery is recursive,
and overlapping roots are deduplicated. Each context value, missing value, outcome
and capture state is listed before loading the point clouds.

The actual bytes of each saved **CFG are SHA-256 fingerprinted**. Renaming a CFG
does not make it a different configuration; editing it does. Recorded CFG timing
and measurement scales are used for each session. Detector tuning JSON is a separate
candidate input; it does not replace the recorded radar CFG.

## 3. Choose numeric pass criteria

```bash
python3 tools/shot_regression.py configure logs/radar-live \
  --profile configs/shot-criteria.json
```

The interactive setup asks for context filters, then **your numeric minimum and
maximum for each qualitative label used by the selected hits**, and an **absolute
± tolerance for each exact measurement key**. There are no invented default
thresholds. It only asks about labels actually needed: exact speed supersedes the
speed label, exact direction supersedes the direction label, and so on.

Qualitative speed ranges use **m/s**; qualitative direction/elevation ranges use
**degrees**. Exact tolerances use the measurement key's units: `speed_kph` is km/h,
`speed_mps` is m/s, `distance_m` is metres, and angles are degrees. Bounds are
inclusive. Exact direction error wraps at ±180°.

Alternatively, `run` without `--profile` asks the same questions before replay.
The full chosen profile is embedded in every report, so the criteria are retained.
Use `configure` to save reusable criteria for unattended runs.

### Profile structure and context-specific criteria

The following is an **illustration of the format**, not calibrated acceptance data:

```json
{
  "schema_version": 1,
  "where": {"room": "living-room", "ball_type": ["foam", "real-golf-ball"]},
  "criteria": {
    "ranges": {
      "speed": {"low": [2, 9], "medium": [9, 18]},
      "direction": {"straight": [-5, 5], "left": [-30, -5]},
      "elevation": {"rolling": [0, 3], "medium": [10, 30]}
    },
    "tolerances": {"speed_kph": 3, "direction_deg": 2, "elevation_deg": 3, "distance_m": 0.3}
  },
  "rules": [
    {
      "where": {"ball_type": "foam", "launch_surface": "pillow"},
      "criteria": {"ranges": {"speed": {"low": [1, 7]}}}
    }
  ]
}
```

Filters are **AND across keys**, **OR within a list**. Missing tags do not match
a named value. `rules` overlay individual ranges/tolerances on the base criteria;
matching rules apply in order, with later values winning. This lets the meaning
of “low” differ between relevant contexts without hardcoding rooms or balls.
The wizard produces the base criteria; edit `rules` when you need these overrides.
Changing criteria requires a new baseline.

## 4. Establish the baseline, then test every detector change

```bash
python3 tools/shot_regression.py run logs/radar-live \
  --profile configs/shot-criteria.json --report logs/baseline.json

# After editing detection code or tuning:
python3 tools/shot_regression.py run logs/radar-live \
  --profile configs/shot-criteria.json --report logs/candidate.json \
  --baseline logs/baseline.json --fail-on-regression
```

The runner builds **current Rust source in release mode once**, then replays each
selected session once. Pass `--detector path/to/candidate.json` to test alternative
detector tuning (default: `radar_app/configs/swing.json`). `--binary /absolute/path`
explicitly uses a prebuilt binary instead. Binary/tuning hashes, commit, dirty-tree
information, actual replay configuration and recording fingerprints are retained.

Narrow to matching experimental conditions without editing source:

```bash
python3 tools/shot_regression.py run logs/radar-live \
  --profile configs/shot-criteria.json --report logs/foam-pillow.json \
  --where ball_type=foam --where launch_surface=pillow --where radar_setup=tripod-v2
```

Repeat a key to choose several values. Command-line filters override the same key
in the profile. By default **every context tag and the CFG fingerprint** contributes
to cluster identity. Each cluster gets its own full summary, including explicit
missing-condition groups. Optional profile `group_by: ["room", "cfg_sha256", ...]`
chooses fewer grouping dimensions deliberately; it does not change selection.

Before accepting a detector change, run the full relevant dataset with the same
profile as its baseline. Use per-cluster results to see whether improvements on
one setup cost accuracy on another. Keep failing real recordings: they are the
cases the next change should improve. Retain reports outside the source data, and
share a profile plus the whole recording folders when reproducing results.

## What passes, fails or remains unscored?

- **Hit:** exactly **one** ball must be detected. All supplied numeric criteria
  must pass. No detection fails; multiple detections fail even if one looks right.
- **Miss:** **zero** balls must be detected. Inherited speed/angle descriptions
  are ignored for misses; any detection is a false positive.
- **Unknown outcome, interrupted window or zero recorded frames:** unscored.
- **Missing range/tolerance or unavailable estimator output:** unscored, unless
  an independent detection/numeric failure already proves the case fails.
- **Partially labelled hits:** only annotated axes are tested. A hit with no
  quantitative/qualitative expectations is explicitly **detection-only**, not a
  claim of correct speed or angles. Coverage counts show this distinction.

Reports include per-case predictions, criteria, exact errors, distance outside a
qualitative range, missing-coverage reasons, original recorded decisions and
per-context summaries. Summary metrics include hit recall, precision (extra balls
penalized), false-positive miss windows/balls, false negatives, duplicates,
detection accuracy, numeric-quality passes, metric coverage/pass rates and exact
mean absolute error. Metrics unavailable because no ball was detected do not get
fabricated error values; recall and coverage expose that failure separately.

Baseline comparisons require identical dataset/window/annotation fingerprints,
grouping and criteria. Changing rooms via a filter, relabelling captures, editing
recordings or changing thresholds cannot masquerade as an algorithm improvement.
Use a fresh baseline after those changes. Algorithm/tuning/metric-estimator changes
are allowed. Comparisons list newly passing and regressed cases, changed
predictions, summary deltas, metric-error deltas and detection/metric deltas per cluster.
A case staying PASS can still have larger exact errors; inspect metric deltas too.

Exit status: **0** passes, **1** known failures/regressions, **2** incomplete
coverage/configuration/replay error. An empty suite cannot pass. `--allow-unscored`
explicitly permits partial coverage, while preserving UNSCORED counts and refusing
an entirely ineligible suite. `--fail-on-regression` also fails a previously passing
case becoming unscored. Baseline files are never overwritten by the candidate path.

## Distance and future metrics

The detector estimates launch speed/direction/elevation, **not actual travel
distance**. `distance_m` ground truth is saved but remains unscored by default;
radar range/visible track extent is not a substitute for total travel distance.
Independent distance-only truth is supported without inventing launch angles.

Supply an estimator adapter with `--metrics-module path/to/estimator.py` when a
compatible distance predictor or other metric is available. It defines:

```python
def derive_metrics(shot, capture, context):
    # Your model uses the replayed launch, captured labels and experimental context.
    # Return predicted values, never the ground-truth measurements from capture.
    return {"distance_m": predict_distance(shot, context)}
```

Adapters return finite numeric values under the same keys as measured truth. They
may add metrics but cannot overwrite the core detector's speed/angles. Configure
an absolute tolerance for each new measured metric. The adapter source hash is
saved in provenance. Arbitrary future numeric measurement keys are supported in
the backend, notes form, profiles, scoring and reports without schema changes.

## Framework verification

```bash
python3 -m unittest tests.test_shot_regression tests.test_rust_live
cargo test --manifest-path radar_app/Cargo.toml
python3 tools/run_range.py --check
```

CI runs scoring/context/baseline contracts, existing independent radar-return
fixtures, and the emulated UART → shot notes → replay → scored report integration.
The native application's checks include the updated form and inherited values.
Private/local recording folders are not bundled into CI: use the dataset commands
above to evaluate each detector change against your own annotated recordings.
