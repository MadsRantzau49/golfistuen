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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    parser.add_argument("--before-s", type=float, default=0.2)
    parser.add_argument("--after-s", type=float, default=1.0)
    parser.add_argument("--min-speed-mps", type=float)
    parser.add_argument("--out", type=Path, help="Save the full JSON point report")
    parser.add_argument("--summary-only", action="store_true")
    parser.add_argument("--replay-report", type=Path, help="Compare a Rust replay-live JSON report")
    args = parser.parse_args()
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
