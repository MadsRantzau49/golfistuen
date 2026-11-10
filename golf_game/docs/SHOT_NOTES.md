# Shot notes — Space to start, Space to end

Historical reference: these screens require services removed from the simplified
radar backend. The current backend supports live gameplay shots only.

Open **Shot notes · timed capture** from the main menu and connect to the same
radar host/port used by Real mode (normally port 8765).

1. Press **Space** before you take a shot.
2. Hit the ball.
3. Press **Space** again after the shot.
4. Click your estimates and optionally describe what happened.
5. Press Space to start the next shot when ready.

The Start/End shot button performs the same action. Holding Space does not create
repeated captures. Space works while buttons are focused; inside the notes/host
text fields it types a normal space, so click outside the text field or use the
Start/End button before starting another shot.

## The form

| Field | Choices |
| --- | --- |
| Outcome | Hit · ball struck, Miss · no ball struck, or unselected/unknown |
| Speed | Low, Medium, High, Full speed |
| Elevation | Rolling, Very low jumping, Low, Medium, Good swing, Too high, Instant ceiling |
| Direction | Full left, Left, Straight, Right, Full right |

These are your qualitative estimates. They are not converted into invented speeds
or angles. No selection means “Not set”; clicking the selected button again clears
it. The next capture inherits the **latest capture's context, hit/miss and qualitative
estimates**, even while you are inspecting an older history row. Change only what
differs. Verify inherited hit/miss against what actually happened. Unknown outcomes
are retained but cannot pass regression tests. **Other notes: None** and exact
measurements start empty for each new attempt.

### Test conditions

Use your own names for room/environment, radar placement/alignment revision, ball
type, launch surface/support, support movement and CFG label. For example, a pillow
and whether it moved belong in launch surface and support movement. Moving or
rotating the radar should produce a new radar-setup name. Room dimensions can be
recorded in the room name or as additional tags.

There are no fixed lists of rooms, balls or supports. **Additional tags** accepts
a JSON object with string values, such as `{"club":"7-iron","room_size":"4x6x2.5m"}`.
Keys use letters, digits and underscores (up to 64 characters); values are up to
512 characters, with at most 64 context tags. Empty named fields mean unknown.
The actual saved `radar.cfg` is automatically fingerprinted by the test runner;
the optional CFG label does not override it. `cfg_sha256` is reserved.

### Optional exact ground truth

Alongside the abstract labels, enter measured **speed in km/h (km/t)**, **direction
in degrees**, **elevation in degrees**, and/or **actual travel distance in metres**.
Left is negative; right positive. Empty means unknown; **zero is a real measurement**.
Use independent measurements, not the detector's own displayed estimate.

**Additional measurements** accepts numeric JSON with explicit unit-bearing keys,
for example `{"carry_m":4.2}` or `{"speed_mps":15.0}`. Use either `speed_mps` or
the km/h field, not both. Known speed/distance values must be nonnegative, direction
is −180…180°, and elevation −90…90°. Measurement keys follow the context key rules;
at most 64 finite numeric measurements are supported.

Exact truth overrides the qualitative label for that axis during testing. Missing
axes can still use qualitative labels. Actual measurements are **not inherited**,
because one measured shot is not proof of the next shot's speed or distance.
Context and qualitative descriptions still are inherited.

Distance is preserved independently of launch angles/speed. The current radar
detector does not estimate total travel distance; those test criteria stay
**UNSCORED** until a compatible metric estimator is supplied. See the
[regression testing guide](SHOT_REGRESSION.md) for configurable numeric ranges,
exact tolerances, context filters, metric extensions and before/after comparisons.

Optional notes can describe distance, height, contact or anything else useful:
“Travelled about 4 metres, reached about 2 metres high, straight ahead.” There is
no spin field. Notes can contain up to 4,096 characters.

Descriptions auto-save after a short typing pause, and **Save description** saves
immediately. You can select an earlier shot in history and edit its description.
**Copy shot summary** copies its description and timing references; **Export selected
shot** saves them as a JSON file. “Load older shots” pages through saved captures
across radar sessions, including after a service restart.

### Delete a shot

Select a shot in history and click **Delete selected shot**. It disappears after
the radar computer acknowledges deletion, and is excluded from future regression
tests. You can also delete unfinished shots from older sessions. End the current
recording before deleting it. Connect to the service to delete a saved shot.

Deletion also clears that shot's local drafts/cache; delayed messages cannot bring
it back. The capture JSON is moved into that session's `deleted-captures/` directory.
Shared raw/event files are retained because they also contain other shots. Saved
test reports remain historical records; deleting a case changes the dataset, so a
new baseline is needed for comparisons involving that case.

### Regression tests inside the game

Click **Regression tests** at the top of Shot notes. The normal radar host/port
connection is reused, and the tool guides you through:

1. **Choose recordings:** select room, ball, radar placement, actual CFG and any
   other recorded conditions from dropdowns, or reuse saved criteria.
2. **Define what passes:** enter numeric minimum/maximum values for the abstract
   labels in your selection, and allowed ± differences for exact measurements.
   Qualitative speed ranges are entered in km/h in this form.
3. **Run and compare:** run the tests; later select a saved result as the baseline
   to restore its conditions/criteria and compare another detector version fairly.

Results show pass/fail/unscored counts, detection recall/precision, false-positive
misses, duplicates, numeric coverage/errors, condition groups and individual shot
details. Select a result's shot to see expected versus actual values and use
**Open this shot in Shot notes** to inspect/edit it. Larger reports load in pages.

Criteria and reports are saved on the radar computer, so another game/computer can
reuse them. Work runs in the background while radar recording remains responsive.
You can leave the screen and return to the running task. Finish a timed shot before
opening tests; shot changes wait until the background task finishes. No testing
commands, JSON files or Python installation are needed on the game computer.

The tool tests the **running radar service's detector and tuning**. Rebuild/restart
that service after algorithm changes. Python 3 and the two regression scripts are
required on the radar computer (included in the source checkout). For a relocated
backend installation, `RADAR_REGRESSION_TOOL` selects `shot_regression_service.py`
and `RADAR_PYTHON` selects the interpreter. See [SHOT_REGRESSION.md](SHOT_REGRESSION.md)
for the optional command-line interface and extensibility details.

## Detector's current estimate

The read-only result above the form updates while recording as soon as a ball is
registered. It shows estimated **speed (m/s and km/h), elevation and left/right
direction**, plus the supporting observation count when available. Short tracks
are marked as approximate. A later unconfirmed movement does not erase an earlier
registered ball from the same window.

Your speed/elevation/direction buttons remain your own independent description;
the detector does not fill them in. A capture without a registered ball says so.
History loads the estimate actually registered at capture time, including old
records created before this display existed. Revised offline replay results are
written to separate analysis reports, preserving the recorded decision for comparison.

## What is recorded

Every pair of presses creates a capture even if the detector finds no swing or
ball. The radar's continuous raw/event recording remains active. During a manual
window its events also carry a `capture_id`.

The radar computer saves one JSON file per capture:

```text
logs/radar-live/<session>/captures/<capture-id>.json
```

It contains:

- Start/end times on the radar service's monotonic log clock and UTC timestamps.
- Start/end event-sequence, raw-byte and frame references, plus actual first/last
  captured frames and frame/point counts.
- The operator's client keypress timestamps for comparison.
- Speed, elevation, direction and optional notes (`null` for unset/None).
- Independent hit/miss (`null` for unknown), an open-ended `context` object and
  numeric `measurements` object. New captures use schema version 2; older version 1
  annotations remain readable with these fields unset/empty.
- Detector attempt counts, confirmed/unconfirmed results and rejection summaries.
- The latest registered detector estimate, observation support and algorithm version
  when available. This remains available after later rejected motion.
- Annotation revision and complete/interrupted state.

`shot_capture_started`, `shot_capture_ended` and `shot_annotation_saved` events
also appear in the session's `events-*.jsonl` files. The form shows the capture
file's full path. Share the capture JSON **and its recording folder** for debugging.
Byte references locate the original continuous stream; a packet can straddle a
boundary, so use the frame/event context rather than assuming a byte slice alone
is a standalone DAT recording.

Timing is the interval when the service receives your two commands. It is an
approximate shot window, not a claim about the exact impact instant. Normal network
latency and buffered serial data still apply. The detector runs during that window;
its verdict remains separate from your description. A missed detection does not
discard the capture. Captures do not launch golf animations or add strokes.

## Interruptions and local drafts

Disconnecting, leaving the screen or replacing the connection ends an unfinished
window as **interrupted**. Reconnect to load the saved state and finish its notes.
An abruptly stopped backend can leave a started capture with no end marker; that
is an unfinished window, and its tagged raw/event data remains available.

Descriptions also have a local backup in Pinewater's user-data directory,
`shot-notes.json`. Unsaved edits remain local when offline and synchronize after
reconnection. A save acknowledgement is required before the form reports that a
description is saved on the radar computer. Records from earlier sessions can
still be edited when their capture file is available under that service's log root.

Use a rebuilt/relaunched game and restart the updated Rust live service. From the
repository root, the developer shortcut is:

```bash
python3 tools/run_range.py --shot-notes
```

Checks cover the Space pair, key-repeat/text-field handling, all preset choices,
local draft recovery, capture timestamps, default None notes, interrupted captures,
annotation revisions and exact links to recorded frames/bytes.
