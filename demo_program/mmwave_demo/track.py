import argparse
import csv
import sys
from pathlib import Path

from .points import filter_points, group_by_frame, load_points, point_range


DEFAULT_POINTS_PATH = Path("data/processed/mmwave_points.csv")


def build_parser():
    parser = argparse.ArgumentParser(description="Print one motion/debug row per mmWave frame")
    parser.add_argument("--points", type=Path, default=DEFAULT_POINTS_PATH)
    parser.add_argument("--select", choices=["strongest", "fastest", "nearest", "farthest", "centroid"], default="strongest")
    parser.add_argument("--start-frame", type=int)
    parser.add_argument("--end-frame", type=int)
    parser.add_argument("--min-range", type=float)
    parser.add_argument("--max-range", type=float)
    parser.add_argument("--min-abs-doppler", type=float, default=0.0, help="Ignore points below this absolute doppler")
    parser.add_argument("--min-snr", type=float, help="Ignore points below this SNR in dB, when SNR exists")
    parser.add_argument("--limit", type=int, help="Maximum number of frame rows to print")

    return parser


def point_score(point, mode):
    if mode == "fastest":
        return abs(point["doppler"])

    if mode == "nearest":
        return -point_range(point)

    if mode == "farthest":
        return point_range(point)

    return point.get("snr_db") if point.get("snr_db") is not None else abs(point["doppler"])


def select_point(points, mode):
    if mode == "centroid":
        count = len(points)
        return {
            "x": sum(point["x"] for point in points) / count,
            "y": sum(point["y"] for point in points) / count,
            "z": sum(point["z"] for point in points) / count,
            "doppler": sum(point["doppler"] for point in points) / count,
            "snr_db": None,
            "noise_db": None,
        }

    return max(points, key=lambda point: point_score(point, mode))


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    points = load_points(args.points)
    points = filter_points(
        points,
        start_frame=args.start_frame,
        end_frame=args.end_frame,
        min_range=args.min_range,
        max_range=args.max_range,
        min_abs_doppler=args.min_abs_doppler,
        min_snr=args.min_snr,
    )

    frames = group_by_frame(points)
    writer = csv.DictWriter(
        sys.stdout,
        fieldnames=[
            "frame_number",
            "points_in_frame",
            "selected",
            "x",
            "y",
            "z",
            "range",
            "doppler",
            "snr_db",
            "noise_db",
        ],
    )
    writer.writeheader()

    rows_written = 0

    for frame_number in sorted(frames):
        frame_points = frames[frame_number]

        if not frame_points:
            continue

        point = select_point(frame_points, args.select)
        writer.writerow({
            "frame_number": frame_number,
            "points_in_frame": len(frame_points),
            "selected": args.select,
            "x": point["x"],
            "y": point["y"],
            "z": point["z"],
            "range": point_range(point),
            "doppler": point["doppler"],
            "snr_db": point.get("snr_db"),
            "noise_db": point.get("noise_db"),
        })

        rows_written += 1

        if args.limit and rows_written >= args.limit:
            break


if __name__ == "__main__":
    main()
