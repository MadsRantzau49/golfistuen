import argparse
from pathlib import Path

from .points import filter_points, group_by_frame, load_points, numeric_range, point_range


DEFAULT_POINTS_PATH = Path("data/processed/mmwave_points.csv")


def build_parser():
    parser = argparse.ArgumentParser(description="Print a quick summary of mmWave point CSV data")
    parser.add_argument("--points", type=Path, default=DEFAULT_POINTS_PATH)
    parser.add_argument("--start-frame", type=int)
    parser.add_argument("--end-frame", type=int)
    parser.add_argument("--min-range", type=float)
    parser.add_argument("--max-range", type=float)
    parser.add_argument("--min-abs-doppler", type=float, help="Ignore static/slow points below this absolute doppler")
    parser.add_argument("--min-snr", type=float, help="Ignore points below this SNR in dB, when SNR exists")

    return parser


def fmt_range(label, values, unit=""):
    low, high = values

    if low is None:
        return f"{label}: n/a"

    return f"{label}: {low:.3f}{unit} .. {high:.3f}{unit}"


def summarize(points):
    frames = group_by_frame(points)
    frame_numbers = sorted(frames)

    print(f"points: {len(points)}")
    print(f"frames: {len(frame_numbers)}")

    if not points:
        return

    print(f"first_frame: {frame_numbers[0]}")
    print(f"last_frame: {frame_numbers[-1]}")
    print(fmt_range("x", numeric_range(points, "x"), " m"))
    print(fmt_range("y", numeric_range(points, "y"), " m"))
    print(fmt_range("z", numeric_range(points, "z"), " m"))
    print(fmt_range("doppler", numeric_range(points, "doppler"), " m/s"))
    print(fmt_range("snr", numeric_range(points, "snr_db"), " dB"))
    print(fmt_range("noise", numeric_range(points, "noise_db"), " dB"))

    ranges = [point_range(point) for point in points]
    print(f"range: {min(ranges):.3f} m .. {max(ranges):.3f} m")

    busiest_frame = max(frame_numbers, key=lambda frame_number: len(frames[frame_number]))
    print(f"max_points_in_frame: {len(frames[busiest_frame])} at frame {busiest_frame}")


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
    summarize(points)
