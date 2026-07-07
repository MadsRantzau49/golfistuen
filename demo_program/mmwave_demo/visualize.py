import argparse
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation
from matplotlib.patches import Circle

from .points import filter_points, group_by_frame, load_points


DEFAULT_POINTS_PATH = Path("data/processed/mmwave_points.csv")


def frame_window(frame_numbers, current_frame, history):
    index = frame_numbers.index(current_frame)
    start = max(0, index - history + 1)

    return frame_numbers[start:index + 1]


def split_latest_and_history(frames, frame_numbers, current_frame, history):
    window = frame_window(frame_numbers, current_frame, history)
    previous = []

    for frame_number in window[:-1]:
        previous.extend(frames[frame_number])

    return previous, frames[current_frame]


def configure_2d_axes(ax, args):
    ax.set_xlabel("x left/right (m)")
    ax.set_ylabel("y forward (m)")
    ax.grid(True, alpha=0.3)
    ax.set_aspect("equal", adjustable="box")

    if args.xlim:
        ax.set_xlim(args.xlim)

    if args.ylim:
        ax.set_ylim(args.ylim)

    ax.scatter([0], [0], c="black", marker="^", s=80, label="radar")

    if args.range_rings:
        x_max = max(abs(value) for value in ax.get_xlim())
        y_max = max(abs(value) for value in ax.get_ylim())
        max_radius = int(max(x_max, y_max))

        for radius in range(1, max_radius + 1):
            ax.add_patch(Circle((0, 0), radius, fill=False, linestyle="--", linewidth=0.5, alpha=0.25))


def configure_3d_axes(ax, args):
    ax.set_xlabel("x left/right (m)")
    ax.set_ylabel("y forward (m)")
    ax.set_zlabel("z height (m)")

    if args.xlim:
        ax.set_xlim(args.xlim)

    if args.ylim:
        ax.set_ylim(args.ylim)

    if args.zlim:
        ax.set_zlim(args.zlim)

    ax.scatter([0], [0], [0], c="black", marker="^", s=80, label="radar")


def doppler_limits(points, args):
    if args.doppler_limit is not None:
        limit = abs(args.doppler_limit)
        return -limit, limit

    max_abs = max((abs(point["doppler"]) for point in points), default=1.0)
    max_abs = max(max_abs, 0.1)

    return -max_abs, max_abs


def plot_frame(ax, frames, frame_numbers, current_frame, args, all_points):
    previous, latest = split_latest_and_history(frames, frame_numbers, current_frame, args.history)
    vmin, vmax = doppler_limits(all_points, args)
    ax.clear()

    if args.mode == "3d":
        if previous:
            ax.scatter(
                [point["x"] for point in previous],
                [point["y"] for point in previous],
                [point["z"] for point in previous],
                c="lightgray",
                s=12,
                alpha=0.25,
                label="history",
            )

        scatter = None

        if latest:
            scatter = ax.scatter(
                [point["x"] for point in latest],
                [point["y"] for point in latest],
                [point["z"] for point in latest],
                c=[point["doppler"] for point in latest],
                cmap="coolwarm",
                vmin=vmin,
                vmax=vmax,
                s=45,
                edgecolors="black",
                linewidths=0.3,
                label="latest frame",
            )

        configure_3d_axes(ax, args)
    else:
        if previous:
            ax.scatter(
                [point["x"] for point in previous],
                [point["y"] for point in previous],
                c="lightgray",
                s=12,
                alpha=0.25,
                label="history",
            )

        scatter = None

        if latest:
            scatter = ax.scatter(
                [point["x"] for point in latest],
                [point["y"] for point in latest],
                c=[point["doppler"] for point in latest],
                cmap="coolwarm",
                vmin=vmin,
                vmax=vmax,
                s=45,
                edgecolors="black",
                linewidths=0.3,
                label="latest frame",
            )

        configure_2d_axes(ax, args)

    ax.set_title(f"Frame {current_frame} | points={len(latest)} | history={args.history}")
    ax.legend(loc="upper right")

    return scatter


def build_parser():
    parser = argparse.ArgumentParser(description="Visualize mmWave detected points from mmwave_points.csv")
    parser.add_argument("--points", type=Path, default=DEFAULT_POINTS_PATH)
    parser.add_argument("--mode", choices=["2d", "3d"], default="2d")
    parser.add_argument("--frame", type=int, help="Frame number to plot. Defaults to latest frame.")
    parser.add_argument("--animate", action="store_true", help="Animate frames instead of plotting one frame")
    parser.add_argument("--interval", type=int, default=100, help="Animation delay in milliseconds")
    parser.add_argument("--history", type=int, default=1, help="Number of frames to show at once")
    parser.add_argument("--start-frame", type=int)
    parser.add_argument("--end-frame", type=int)
    parser.add_argument("--min-range", type=float, help="Ignore points closer than this many meters")
    parser.add_argument("--max-range", type=float, help="Ignore points farther than this many meters")
    parser.add_argument("--xlim", type=float, nargs=2, metavar=("MIN", "MAX"))
    parser.add_argument("--ylim", type=float, nargs=2, metavar=("MIN", "MAX"))
    parser.add_argument("--zlim", type=float, nargs=2, metavar=("MIN", "MAX"))
    parser.add_argument("--doppler-limit", type=float, help="Use symmetric color limits, for example 1.0")
    parser.add_argument("--no-range-rings", dest="range_rings", action="store_false")
    parser.add_argument("--save", type=Path, help="Save a PNG instead of opening a window. Static plots only.")
    parser.set_defaults(range_rings=True)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.history < 1:
        raise SystemExit("--history must be at least 1")

    points = load_points(args.points)
    points = filter_points(
        points,
        start_frame=args.start_frame,
        end_frame=args.end_frame,
        min_range=args.min_range,
        max_range=args.max_range,
    )

    if not points:
        raise SystemExit(f"No points found in {args.points}")

    frames = group_by_frame(points)
    frame_numbers = sorted(frames)

    if args.frame is not None and args.frame not in frames:
        raise SystemExit(f"Frame {args.frame} was not found in {args.points}")

    if args.save and args.animate:
        raise SystemExit("--save is only supported for static plots. Remove --animate.")

    fig = plt.figure(figsize=(9, 7))
    ax = fig.add_subplot(111, projection="3d" if args.mode == "3d" else None)

    if args.animate:
        animation = FuncAnimation(
            fig,
            lambda frame_number: plot_frame(ax, frames, frame_numbers, frame_number, args, points),
            frames=frame_numbers,
            interval=args.interval,
            repeat=True,
        )
        # Keep a reference alive until plt.show() returns.
        fig._mmwave_animation = animation
        plt.show()

        return

    frame_number = args.frame if args.frame is not None else frame_numbers[-1]
    scatter = plot_frame(ax, frames, frame_numbers, frame_number, args, points)

    if scatter is not None:
        fig.colorbar(scatter, ax=ax, label="doppler (m/s)")

    fig.tight_layout()

    if args.save:
        args.save.parent.mkdir(parents=True, exist_ok=True)
        fig.savefig(args.save, dpi=160)
        print(f"Saved {args.save}")
    else:
        plt.show()
