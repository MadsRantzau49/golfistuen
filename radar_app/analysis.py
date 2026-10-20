"""Explicit manual selection, interval statistics and least-squares motion estimates."""
from __future__ import annotations

import csv
import io
import math
import statistics


def selected_points(recording: dict, selection: dict, manual_only=False):
    start, end = selection.get("from_s", 0), selection.get("to_s", recording["summary"]["duration_s"])
    refs = {tuple(p) for p in selection.get("points", [])}
    filters = selection.get("filters", {})
    for i, f in enumerate(recording["frames"]):
        if not start <= f["t"] <= end:
            continue
        for j, p in enumerate(f["points"]):
            if manual_only and (i, j) not in refs:
                continue
            if not filters.get("rmin", 0) <= p["range"] <= filters.get("rmax", math.inf):
                continue
            if not filters.get("vmin", 0) <= abs(p["v"]) <= filters.get("vmax", math.inf):
                continue
            direction = filters.get("direction", "all")
            if (direction == "away" and p["v"] <= 0) or (direction == "toward" and p["v"] >= 0):
                continue
            if p["snr"] is not None and p["snr"] < filters.get("snr", -math.inf):
                continue
            yield i, j, f, p


def statistics_for(rows, duration):
    result = dict(detection_count=len(rows), duration_s=duration)
    for field, label in (("range", "range_m"), ("snr", "snr_db"), ("v", "reported_radial_velocity_mps")):
        values = [p[field] for _, _, _, p in rows if p[field] is not None]
        result[label] = dict(min=min(values), max=max(values), mean=statistics.mean(values), median=statistics.median(values)) if values else None
    return result


def inspect(recording: dict, selection: dict) -> dict:
    start = selection.get("from_s", 0)
    end = selection.get("to_s", recording["summary"]["duration_s"])
    if not all(math.isfinite(x) for x in (start, end)) or start < 0 or end < start:
        raise ValueError("Select a valid interval in seconds.")
    all_rows = list(selected_points(recording, selection))
    manual = list(selected_points(recording, selection, True))
    result = dict(all_detections_in_interval=statistics_for(all_rows, end - start),
                  manually_selected_ball_candidates=statistics_for(manual, end - start), motion_estimate=None)
    # One manually chosen point per distinct frame: no implicit association or averaging.
    if len(manual) >= 4 and len({i for i, _, _, _ in manual}) == len(manual):
        times = [f["t"] for _, _, f, _ in manual]
        mean_t = statistics.mean(times)
        denominator = sum((t - mean_t) ** 2 for t in times)
        if denominator > 1e-12:
            slopes, residuals = [], []
            for axis in ("x", "y", "z"):
                values = [p[axis] for _, _, _, p in manual]
                mean = statistics.mean(values)
                slope = sum((t - mean_t) * (v - mean) for t, v in zip(times, values)) / denominator
                slopes.append(slope)
                residuals.append([v - mean - slope * (t - mean_t) for t, v in zip(times, values)])
            speed = math.hypot(*slopes)
            residual_norms = [math.hypot(*r) for r in zip(*residuals)]
            result["motion_estimate"] = dict(label="Estimated mean 3D velocity in radar coordinates over the selected interval; not launch speed",
                velocity_xyz_mps=slopes, mean_speed_mps=speed,
                direction_unit_xyz=[v / speed for v in slopes] if speed > 1e-12 else None,
                rms_position_residual_m=math.sqrt(statistics.mean(r*r for r in residual_norms)),
                max_position_residual_m=max(residual_norms), residuals_m=residual_norms,
                duration_s=max(times)-min(times), point_count=len(manual))
    return result


def export_csv(recording: dict, selection: dict, manual_only=False) -> str:
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(["frame_number", "time_s", "point_index", "x_m", "y_m", "z_m", "range_m", "radial_velocity_mps", "snr_db", "noise_db"])
    for _, j, f, p in selected_points(recording, selection, manual_only):
        writer.writerow([f["number"], f["t"], j, p["x"], p["y"], p["z"], p["range"], p["v"], p["snr"], p["noise"]])
    return output.getvalue()
