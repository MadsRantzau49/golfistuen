# Local golf and the clubhouse

## Start a round

**Play local golf** opens players, then course/rules. Add one to six people, choose
names and unique colours, and optionally import a local PNG/JPEG/WebP photo. Photos
are centre-cropped to 256 × 256 PNG, cached locally and applied to the square head's
front face. Default portraits and character geometry are original procedural art.
A preview supports swing playback. Actual shots launch at swing contact, 0.43 s
after the input is accepted; scores reserve the stroke once at input time.

First-tee order is the agreed roster order, or randomly drawn. Courses contain
1–36 ordered hole snapshots. Add/repeat/reorder library favourites or generate
seeded par-3/4/5 layouts with differing terrain, fairways, ponds, bunkers, trees and
cup positions. The seed and cup diameter reproduce the generated layouts. Saving
a course preserves its full layouts independently of later library edits.

## Scoring and turn order

- Every player owns a separate `HoleRound`, ball position, previous stroke lie and
  scorecard. The camera addresses only the selected player's ball.
- Everyone's initial tee stroke precedes any second stroke, including an OOB
  re-tee. Thereafter the farthest unfinished ball from the cup plays next. Equal
  distances retain tee-order priority. There is no round-robin rotation.
- Later honours follow the previous hole's gross scores. Ties retain the preceding
  tee order. DNF goes behind classified hole results.
- **Maximum Score**: the round announces double par, par + 5, or fixed 12. Actual
  shots, penalties, automatic strokes and pickup adjustments cannot exceed that
  maximum. Pickup records the maximum, following the competition model of Rule 21.2.
- **Ordinary stroke play**: no cap. Failure to finish records DNF, making the round
  unclassified; that player cannot win on an incomplete low total. They may still
  play the remaining holes.
- A stopped green ball adds the announced 0–3 automatic strokes, default +2. A
  captured cup entry adds none. This replaces putting.
- Water/OOB count the shot plus one penalty and return to the previous safe lie.
  Water uses simplified stroke-and-distance rather than selectable red/yellow
  penalty-area relief. The no-putting, water and fairway-rescue policies are
  simulator rules; this is a defined golf competition subset, not all official rulings.
- Live strip totals include provisional current-hole strokes. To-par figures and
  scorecard totals count completed holes; current-hole cells use `*`. `P` marks a
  maximum-score pickup. Equal classified final totals share the win.

All players finish the hole before **Next hole** becomes available. **Give up
hole** asks for confirmation and records the announced maximum or DNF. **Replay**
is non-scoring and does not change turn order. Scorecard and application pause
freeze an in-flight simulation. Round rules are fixed at setup; subsequent global
preference changes affect presentation, not the announced competition.

## Course guide during shots

The collapsible left-side guide stays visible at address and during flight. It
uses the actual painted layout, terrain shading and placed trees, with tee/pin,
current ball and numbered other-player markers. North stays up and the overview
stays stable while the ball moves; an off-map shot is indicated at the map edge.
Gold dashes show aim, the gold trail shows the actual shot and rings measure from
the shot's starting lie. Pin distance updates with the moving ball. Front/back
estimates use only the cup's connected green on the 2 m paint grid.

Hover to measure or click to keep a lay-up point: the guide displays distance from
the lie to that point and onward to the pin. Right-click clears it. Measurements
do not aim or launch shots. Metres/yards follow the existing distance preference;
all figures are horizontal plan distances. Player changes and relief refresh the
lie and clear old measurements. Practice uses the same guide with actual range
targets rather than a competition pin.

## Relief options

**Relief / drop** shows painted surfaces, tree positions, the old lie and selected
drop. Click to select, wheel to zoom, right-drag to pan. Invalid candidates cannot
be confirmed. A virtual club-length is 1.2 m.

| Option | Cost | Placement |
| --- | --- | --- |
| Stroke and distance, 19.2a | +1 | Previous stroke position |
| Lateral, 19.2c | +1 | Within 2.4 m; no nearer cup |
| Back on line, 19.2b | +1 | Behind original lie on cup-to-ball line |
| Outside bunker, 19.3b | +2 | Back on line, outside sand |
| Fairway rescue, simulator house rule | +2 | Painted fairway, no nearer cup; optional at setup |

One-stroke lateral/back-on-line bunker relief must stay in the same connected
bunker. Back-on-line candidates near the line snap onto it. Relief uses a selected
deterministic rest point rather than animating a physical drop. Water/OOB cannot
be selected as relief destinations. Voluntary relief retains the already-selected
player's turn, ordered from the original lie (Rule 6.4d). On-green relief uses the
same announced automatic-green policy. Fairway rescue is expressly not free
standard relief. No handicap, match-play concession or referee system is present.

Rule references: [R&A Rule 6](https://www.randa.org/en/rog/the-rules-of-golf/rule-6),
[Rule 19](https://www.randa.org/en/rog/the-rules-of-golf/rule-19),
[Rule 21](https://www.randa.org/en/rog/the-rules-of-golf/rule-21).

## Persistence and implementation

Under `user://clubhouse/`:

```text
players.json                  Reusable local roster
portraits/<player-id>.png      Bounded square images, max 16 MB source
courses/<course-id>.json       Complete ordered favourite layouts
courses/_catalog.json          Lightweight course listing
layouts/<round-id>.json        Active round's immutable terrain snapshot
active_round.json              Players, rules, scores, lies, turn and pending shot
rounds/<round-id>.json         Completed round result with layout reference
last_round.json                Latest completed result
```

JSON saves use a temporary file and previous-file backup. Large terrain snapshots
are written once per active-round ID; turn checkpoints contain lightweight state.
Checkpoint before the swing stores one counted in-flight stroke and its launch
payload/origin/yaw. A cold resume re-simulates that payload from launch and resolves
it once, preserving score accounting. Last-shot replay payloads are saved per player.
One active round is supported; starting another replaces its resume checkpoint.
Completed results are archived and clear the active-round checkpoint. Data is local
to the OS user; there are no network accounts or synchronisation.

`LocalGolfMatch`, `GolfCourse`, `GolfPlayer`, `GolfRelief` and `HoleRound` contain
domain state independent of rendering. `MatchPlay` adapts the existing hole solver,
HUD, ball and follow camera. `HoleWorkspace` shares terrain/backdrop between solo
authoring tests and competitive play. `MatchSetup`, `ScoreboardBar`,
`MatchScorecard`, `ReliefDialog` and `GolferCharacter` provide presentation.

## Verification

`python3 tools/run_range.py --check` includes domain and application match suites.
The checked release build also runs packaged six-player gameplay/save-resume:

```bash
Pinewater --headless -- --smoke-match
Pinewater -- --capture-app /tmp/players.png --capture-setup
Pinewater -- --capture-app /tmp/course.png --capture-setup --course-step
Pinewater -- --capture-app /tmp/match.png --capture-match
Pinewater --resolution 1100x720 -- --capture-app /tmp/relief.png --capture-match --capture-relief
Pinewater -- --capture-app /tmp/scorecard.png --capture-match --capture-scorecard
```

Capture/smoke paths use isolated clubhouse data. Captures require a graphical
desktop; tests/docs are excluded from native exports.
