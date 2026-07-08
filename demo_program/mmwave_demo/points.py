import csv
import math
from pathlib import Path


def optional_float(value):
    if value in (None, ""):
        return None

    return float(value)


def load_points(path: Path):
    points = []

    with path.open(newline="") as file:
        reader = csv.DictReader(file)

        for row in reader:
            try:
                point = {
                    "timestamp": float(row["timestamp"]),
                    "frame_number": int(row["frame_number"]),
                    "point_index": int(row["point_index"]),
                    "x": float(row["x"]),
                    "y": float(row["y"]),
                    "z": float(row["z"]),
                    "doppler": float(row["doppler"]),
                    "snr_db": optional_float(row.get("snr_db")),
                    "noise_db": optional_float(row.get("noise_db")),
                }
            except (KeyError, TypeError, ValueError):
                continue

            points.append(point)

    return points


def group_by_frame(points):
    frames = {}

    for point in points:
        frames.setdefault(point["frame_number"], []).append(point)

    return frames


def point_range(point):
    return math.sqrt(point["x"] ** 2 + point["y"] ** 2 + point["z"] ** 2)


def filter_points(points, start_frame=None, end_frame=None, min_range=None, max_range=None):
    filtered = []

    for point in points:
        if start_frame is not None and point["frame_number"] < start_frame:
            continue

        if end_frame is not None and point["frame_number"] > end_frame:
            continue

        distance = point_range(point)

        if min_range is not None and distance < min_range:
            continue

        if max_range is not None and distance > max_range:
            continue

        filtered.append(point)

    return filtered


def numeric_range(points, field):
    values = [point[field] for point in points if point.get(field) is not None]

    if not values:
        return None, None

    return min(values), max(values)
