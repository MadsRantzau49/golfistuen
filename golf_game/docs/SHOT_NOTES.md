# Shot notes — Space to start, Space to end

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
| Speed | Low, Medium, High, Full speed |
| Elevation | Rolling, Very low jumping, Low, Medium, Good swing, Too high, Instant ceiling |
| Direction | Full left, Left, Straight, Right, Full right |

These are your qualitative estimates. They are not converted into invented speeds
or angles. No selection means “Not set”; clicking the selected button again clears
it. Each new capture starts with empty estimates and **Other notes: None**.

Optional notes can describe distance, height, contact or anything else useful:
“Travelled about 4 metres, reached about 2 metres high, straight ahead.” There is
no spin field. Notes can contain up to 4,096 characters.

Descriptions auto-save after a short typing pause, and **Save description** saves
immediately. You can select an earlier shot in history and edit its description.
**Copy shot summary** copies its description and timing references; **Export selected
shot** saves them as a JSON file. “Load older shots” pages through the current radar
session's saved captures.

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
