#!/usr/bin/env python3
"""Inspect all saved points around live attempts, including rejected/cooldown data.

This is a diagnostic report, not ground-truth ball/club labelling. No external deps.
"""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import statistics


def events(directory):
    for path in sorted(directory.glob("events-*.jsonl")):
        with path.open() as stream:
            for number, line in enumerate(stream, 1):
                try:
                    yield json.loads(line)
                except json.JSONDecodeError as error:
                    raise ValueError(f"{path}:{number}: incomplete/invalid event: {error}") from error


def summarize(directory, before, after, min_speed=None):
    metadata = json.loads((directory / "session.json").read_text())
    detector = metadata["settings"]["detector"]
    period = detector.get("tracking", {}).get("frame_period_s", 0.02)
    if min_speed is None:
        min_speed = detector.get("motion_threshold_mps", detector.get("detection", {}).get("min_radial_speed_mps", 0.0))
    records = list(events(directory))
    frames = [event["data"] for event in records if event["type"] == "frame"]
    attempts = []
    outcomes = {event["swing_id"]: event["data"] for event in records if event["type"] == "swing_completed"}
    velocities = sorted({abs(point["radial_velocity"]) for frame in frames
                         for point in frame["diagnostics"]["points"] if point["radial_velocity"] is not None})
    steps = [b - a for a, b in zip(velocities, velocities[1:]) if b > a]
    for event in records:
        if event["type"] != "swing_started":
            continue
        start = event["data"]["frame_number"]
        selected = [frame for frame in frames
                    if -before <= (frame["diagnostics"]["frame_number"] - start) * period <= after]
        moving = []
        rejected = Counter()
        for frame in selected:
            diagnostics = frame["diagnostics"]
            for point in diagnostics["points"]:
                velocity = point["radial_velocity"]
                if velocity is None or not math.isfinite(velocity) or abs(velocity) < min_speed:
                    continue
                rejected[point.get("ball_rejection") or "accepted_by_point_gate"] += 1
                moving.append({"frame": diagnostics["frame_number"],
                    "delay_s": round((diagnostics["frame_number"] - start) * period, 6),
                    "xyz": [point[axis] for axis in ("x", "y", "z")],
                    "radial_velocity": velocity, "snr_db": point.get("snr_db"),
                    "old_point_rejection": point.get("ball_rejection"),
                    "phase": diagnostics.get("phase"), "armed": bool(frame.get("arm_id"))})
        attempts.append({"swing_id": event["swing_id"], "start_frame": start,
            "old_result": outcomes.get(event["swing_id"]), "moving_points": moving,
            "moving_point_rejections_in_context": dict(rejected)})
    return {"session": str(directory.resolve()), "metadata": metadata,
        "event_counts": dict(Counter(event["type"] for event in records)),
        "frames": len(frames), "points": sum(len(frame["diagnostics"]["points"]) for frame in frames),
        "frame_period_s": period, "minimum_motion_for_report_mps": min_speed,
        "observed_doppler_steps_mps": sorted(set(round(step, 6) for step in steps)),
        "median_doppler_step_mps": statistics.median(steps) if steps else None,
        "attempts": attempts}


def summarize_captures(directory, minimum=None):
    """Join operator labels to all original returns and their recorded decisions."""
    metadata = json.loads((directory / "session.json").read_text())
    if minimum is None:
        minimum = metadata["settings"]["detector"].get("motion_threshold_mps", 0.0)
    captures = sorted((json.loads(path.read_text()) for path in (directory / "captures").glob("*.json")),
                      key=lambda capture: capture["started"]["elapsed_s"])
    by_id = {capture["capture_id"]: {"capture": capture, "moving_points": [], "paths": [], "frames": []} for capture in captures}
    for event in events(directory):
        result = by_id.get(event.get("capture_id"))
        if result is None:
            continue
        if event["type"] == "frame":
            diagnostics = event["data"]["diagnostics"]
            result["frames"].append({"frame_number": diagnostics["frame_number"], "points": diagnostics["points"]})
            for point in diagnostics["points"]:
                velocity = point.get("radial_velocity")
                if velocity is None or not math.isfinite(velocity) or abs(velocity) < minimum:
                    continue
                position = [point[axis] for axis in ("x", "y", "z")]
                if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in position):
                    continue
                result["moving_points"].append({"frame": diagnostics["frame_number"], "time_s": event["elapsed_s"],
                    "xyz": position, "range_m": math.sqrt(sum(value * value for value in position)),
                    "radial_velocity": velocity, "snr_db": point.get("snr_db"),
                    "old_point_rejection": point.get("ball_rejection"), "phase": diagnostics.get("phase")})
        elif event["type"] == "swing_completed":
            report = event["data"]["report"]
            for track in report.get("tracks", []):
                observations = track.get("observations", [])
                if not observations:
                    continue
                positions = [sample.get("position", [sample.get(axis, 0) for axis in ("x", "y", "z")]) for sample in observations]
                ranges = [math.sqrt(sum(value * value for value in position)) for position in positions]
                result["paths"].append({"id": track.get("track_id"), "selected": track.get("track_id") == report.get("selected_hypothesis_id"),
                    "samples": len(observations), "first_frame": observations[0]["frame_number"], "last_frame": observations[-1]["frame_number"],
                    "start_range_m": ranges[0], "end_range_m": ranges[-1], "max_range_m": max(ranges),
                    "first_xyz": positions[0], "last_xyz": positions[-1],
                    "median_doppler_mps": statistics.median(sample["radial_velocity"] for sample in observations),
                    "fit": track.get("fit"), "rejection": track.get("rejection_reason"), "club_evidence": track.get("club_evidence")})
            result["selected_observations"] = report.get("selected_observations") or result.get("selected_observations", [])
    return {"session": str(directory.resolve()), "sensor": metadata["settings"]["detector"].get("sensor"),
            "minimum_motion_for_report_mps": minimum, "captures": list(by_id.values())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    parser.add_argument("--before-s", type=float, default=0.2)
    parser.add_argument("--after-s", type=float, default=1.0)
    parser.add_argument("--min-speed-mps", type=float)
    parser.add_argument("--out", type=Path, help="Save the full JSON point report")
    parser.add_argument("--summary-only", action="store_true")
    parser.add_argument("--replay-report", type=Path, help="Compare a Rust replay-live JSON report")
    parser.add_argument("--captures", action="store_true", help="Inspect operator-labelled Space-to-Space windows")
    parser.add_argument("--capture-id", help="Limit --captures to one capture ID or its final numeric suffix")
    parser.add_argument("--fixture-out", type=Path, help="Export compact labelled frame fixtures (requires --ball-labels)")
    parser.add_argument("--ball-labels", type=Path, help="Manual independent ball-return labels for a regression fixture")
    args = parser.parse_args()
    if args.captures:
        report = summarize_captures(args.session, args.min_speed_mps)
        replay = json.loads(args.replay_report.read_text()) if args.replay_report else None
        if args.fixture_out:
            if not args.ball_labels:
                parser.error("--fixture-out requires independently supplied --ball-labels")
            labels = json.loads(args.ball_labels.read_text())
            fixture = {"schema_version": 1, "sensor": report["sensor"], "captures": []}
            for item in report["captures"]:
                capture = item["capture"]
                suffix = capture["capture_id"].rsplit("-", 1)[-1]
                label = labels[suffix]
                frames = []
                for frame in item["frames"]:
                    points = []
                    for point in frame["points"]:
                        if not all(isinstance(point.get(axis), (float, int)) for axis in ("x", "y", "z", "radial_velocity")):
                            continue
                        is_ball = (label["first_frame"] <= frame["frame_number"] <= label["last_frame"]
                                   and label["min_radial_speed_mps"] <= point["radial_velocity"] <= label["max_radial_speed_mps"])
                        points.append([point["x"], point["y"], point["z"], point["radial_velocity"], point.get("snr_db"), is_ball])
                    frames.append({"frame_number": frame["frame_number"], "points": points})
                fixture["captures"].append({"name": "capture_" + str(len(fixture["captures"]) + 1),
                    "annotation": {key: capture["annotation"][key] for key in ("speed", "elevation", "direction")}, "frames": frames})
            args.fixture_out.write_text(json.dumps(fixture, separators=(",", ":")) + "\n")
        if args.out:
            args.out.write_text(json.dumps(report, indent=2) + "\n")
        for index, item in enumerate(report["captures"], 1):
            capture = item["capture"]
            if args.capture_id and args.capture_id not in (capture["capture_id"], capture["capture_id"].rsplit("-", 1)[-1]):
                continue
            print(f"\nCAPTURE {index}: {capture['capture_id']} {capture['annotation']} old balls={capture['confirmed_balls']}")
            print(f"Frames {capture['first_frame']}–{capture['last_frame']}; moving returns={len(item['moving_points'])}")
            if replay:
                revised = [attempt for attempt in replay["attempts"] if attempt.get("shot") and
                           capture["first_frame"] <= attempt["report"]["start_frame"] <= capture["last_frame"]]
                for attempt in revised:
                    proof = attempt["report"].get("selected_club_evidence") or {}
                    print(f"  REPLAY speed={attempt['shot']['speed_mps']:.2f} m/s direction={attempt['shot']['direction_deg']:.2f}° "
                          f"elevation={attempt['shot']['elevation_deg']:.2f}° mode={proof.get('validation_mode')} "
                          f"club_reach={proof.get('observed_club_reach_m')} ball_extent={proof.get('candidate_extent_m')} "
                          f"reach_sigma={proof.get('beyond_club_reach_sigma')} concurrent_sigma={proof.get('concurrent_frontier_significance')} "
                          f"analysis_ms={attempt['report'].get('analysis_elapsed_ms'):.2f}")
            if not args.summary_only:
                for point in item["moving_points"]:
                    x, y, z = point["xyz"]
                    print(f"  {point['frame']:6} xyz=({x:+.3f},{y:.3f},{z:+.3f}) r={point['range_m']:.3f} "
                          f"v={point['radial_velocity']:+.3f} snr={point['snr_db']} {point['old_point_rejection'] or ''}")
            paths = [path for path in item["paths"] if path["samples"] >= 3]
            paths.sort(key=lambda path: (path["max_range_m"], path["samples"]), reverse=True)
            shown = set()
            for path in paths[:12] + [path for path in paths if path["selected"]]:
                if path["id"] in shown:
                    continue
                shown.add(path["id"])
                fit = path["fit"] or {}
                print(f"  PATH {path['id']} {'SELECTED' if path['selected'] else ''}: {path['samples']} points "
                      f"{path['first_frame']}–{path['last_frame']} r={path['start_range_m']:.3f}→{path['end_range_m']:.3f} "
                      f"v={path['median_doppler_mps']:.3f} chi={fit.get('reduced_chi_squared')} "
                      f"limit={fit.get('chi_squared_limit')} reason={path['rejection']}")
        return
    report = summarize(args.session, args.before_s, args.after_s, args.min_speed_mps)
    if args.out:
        args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Session: {report['session']}")
    print(f"Frames: {report['frames']}; points: {report['points']}; events: {report['event_counts']}")
    print(f"Doppler steps (m/s): {report['observed_doppler_steps_mps']}")
    for attempt in report["attempts"]:
        print(f"\nSwing {attempt['swing_id']} at frame {attempt['start_frame']}: {attempt['moving_point_rejections_in_context']}")
        if args.summary_only:
            continue
        for point in attempt["moving_points"]:
            x, y, z = point["xyz"]
            print(f"  {point['frame']:6} {point['delay_s']:+.3f}s xyz=({x:+.3f},{y:.3f},{z:+.3f}) "
                  f"v={point['radial_velocity']:+.3f} snr={point['snr_db']} gate={point['old_point_rejection']}")
    if args.replay_report:
        replay = json.loads(args.replay_report.read_text())
        print(f"\nAdaptive replay: {replay['statistics']}")
        for attempt in replay["attempts"]:
            if not attempt.get("shot"):
                continue
            result = attempt["report"]
            fit = result["selected_fit"]
            samples = result.get("selected_observations") or next(
                track["observations"] for track in result["tracks"]
                if track["track_id"] == result["selected_hypothesis_id"])
            print(f"  Original {attempt['overlapping_recorded_swing_ids']}: {attempt['shot']['speed_mps']:.2f} m/s, "
                  f"{len(samples)} samples frames {samples[0]['frame_number']}–{samples[-1]['frame_number']}; "
                  f"chi2/dof={fit['reduced_chi_squared']:.3f} limit={fit['chi_squared_limit']:.3f}; "
                  f"velocity std={fit['velocity_std_mps']}; max XYZ residual={fit['max_position_residual_m']:.3f} m")


if __name__ == "__main__":
    main()
