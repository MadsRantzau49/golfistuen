import argparse
import math
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation
from matplotlib.patches import Circle

from .points import filter_points, group_by_frame, load_points, numeric_range, point_range


DEFAULT_POINTS_PATH = Path("data/processed/mmwave_points.csv")

COLOR_LABELS = {
    "doppler": "doppler (m/s)",
    "range": "range (m)",
    "snr": "snr (dB)",
    "noise": "noise (dB)",
    "frame": "frame number",
}

VIEW_TITLES = {
    "top": "Top view: x/y",
    "side": "Side view: y/z",
    "front": "Front view: x/z",
    "3d": "3D view: x/y/z",
}


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


def view_for_mode(mode):
    return "top" if mode == "2d" else mode


def plane_fields(view):
    if view == "top":
        return "x", "y"

    if view == "side":
        return "y", "z"

    if view == "front":
        return "x", "z"

    raise ValueError(f"Unsupported 2D view: {view}")


def axis_label(field):
    return {
        "x": "x left/right (m)",
        "y": "y forward (m)",
        "z": "z height (m)",
    }[field]


def axis_limit(args, field):
    return {
        "x": args.xlim,
        "y": args.ylim,
        "z": args.zlim,
    }[field]


def color_value(point, color_by):
    if color_by == "range":
        return point_range(point)

    if color_by == "frame":
        return point["frame_number"]

    if color_by == "snr":
        return point.get("snr_db")

    if color_by == "noise":
        return point.get("noise_db")

    return point["doppler"]


def color_values(points, args):
    values = []

    for point in points:
        value = color_value(point, args.color_by)
        values.append(float("nan") if value is None else value)

    return values


def finite_values(values):
    return [value for value in values if value is not None and math.isfinite(value)]


def color_limits(points, args):
    values = finite_values(color_values(points, args))

    if not values:
        return None, None

    if args.color_min is not None or args.color_max is not None:
        low = min(values) if args.color_min is None else args.color_min
        high = max(values) if args.color_max is None else args.color_max
        return low, high

    if args.color_by == "doppler":
        if args.doppler_limit is not None:
            limit = abs(args.doppler_limit)
        else:
            limit = max(max(abs(value) for value in values), 0.1)

        return -limit, limit

    low = min(values)
    high = max(values)

    if low == high:
        padding = abs(low) * 0.05 or 1.0
        low -= padding
        high += padding

    return low, high


def scatter_latest_2d(ax, points, x_field, y_field, args, all_points):
    if not points:
        return None

    values = color_values(points, args)
    finite = finite_values(values)
    vmin, vmax = color_limits(all_points, args)

    kwargs = {
        "s": args.point_size,
        "edgecolors": "black",
        "linewidths": 0.3,
        "label": "latest frame",
    }

    if finite:
        kwargs.update({"c": values, "cmap": args.cmap, "vmin": vmin, "vmax": vmax})
    else:
        kwargs.update({"c": "tab:blue"})

    return ax.scatter(
        [point[x_field] for point in points],
        [point[y_field] for point in points],
        **kwargs,
    )


def scatter_latest_3d(ax, points, args, all_points):
    if not points:
        return None

    values = color_values(points, args)
    finite = finite_values(values)
    vmin, vmax = color_limits(all_points, args)

    kwargs = {
        "s": args.point_size,
        "edgecolors": "black",
        "linewidths": 0.3,
        "label": "latest frame",
    }

    if finite:
        kwargs.update({"c": values, "cmap": args.cmap, "vmin": vmin, "vmax": vmax})
    else:
        kwargs.update({"c": "tab:blue"})

    return ax.scatter(
        [point["x"] for point in points],
        [point["y"] for point in points],
        [point["z"] for point in points],
        **kwargs,
    )


def configure_2d_axes(ax, args, view):
    x_field, y_field = plane_fields(view)
    ax.set_xlabel(axis_label(x_field))
    ax.set_ylabel(axis_label(y_field))
    ax.grid(True, alpha=0.3)
    ax.set_aspect("equal", adjustable="box")

    xlim = axis_limit(args, x_field)
    ylim = axis_limit(args, y_field)

    if xlim:
        ax.set_xlim(xlim)

    if ylim:
        ax.set_ylim(ylim)

    ax.scatter([0], [0], c="black", marker="^", s=80, label="radar")

    if view == "top" and args.range_rings:
        x_max = max(abs(value) for value in ax.get_xlim())
        y_max = max(abs(value) for value in ax.get_ylim())
        max_radius = int(max(x_max, y_max))

        for radius in range(1, max_radius + 1):
            ax.add_patch(Circle((0, 0), radius, fill=False, linestyle="--", linewidth=0.5, alpha=0.25))


def configure_3d_axes(ax, args):
    ax.set_xlabel(axis_label("x"))
    ax.set_ylabel(axis_label("y"))
    ax.set_zlabel(axis_label("z"))

    if args.xlim:
        ax.set_xlim(args.xlim)

    if args.ylim:
        ax.set_ylim(args.ylim)

    if args.zlim:
        ax.set_zlim(args.zlim)

    ax.scatter([0], [0], [0], c="black", marker="^", s=80, label="radar")


def plot_2d_view(ax, view, previous, latest, current_frame, args, all_points):
    x_field, y_field = plane_fields(view)
    ax.clear()

    if previous:
        ax.scatter(
            [point[x_field] for point in previous],
            [point[y_field] for point in previous],
            c="lightgray",
            s=max(6, args.point_size * 0.35),
            alpha=args.history_alpha,
            label="history",
        )

    scatter = scatter_latest_2d(ax, latest, x_field, y_field, args, all_points)
    configure_2d_axes(ax, args, view)
    ax.set_title(f"{VIEW_TITLES[view]} | frame {current_frame} | points={len(latest)}")
    ax.legend(loc="upper right")

    return scatter


def plot_3d_view(ax, previous, latest, current_frame, args, all_points):
    ax.clear()

    if previous:
        ax.scatter(
            [point["x"] for point in previous],
            [point["y"] for point in previous],
            [point["z"] for point in previous],
            c="lightgray",
            s=max(6, args.point_size * 0.35),
            alpha=args.history_alpha,
            label="history",
        )

    scatter = scatter_latest_3d(ax, latest, args, all_points)
    configure_3d_axes(ax, args)
    ax.set_title(f"{VIEW_TITLES['3d']} | frame {current_frame} | points={len(latest)}")
    ax.legend(loc="upper right")

    return scatter


def draw_frame(axes, frames, frame_numbers, current_frame, args, all_points):
    previous, latest = split_latest_and_history(frames, frame_numbers, current_frame, args.history)
    first_colorable = None

    for view, ax in axes:
        if view == "3d":
            scatter = plot_3d_view(ax, previous, latest, current_frame, args, all_points)
        else:
            scatter = plot_2d_view(ax, view, previous, latest, current_frame, args, all_points)

        if first_colorable is None and scatter is not None and scatter.get_array() is not None:
            first_colorable = scatter

    return first_colorable


def create_figure(args):
    if args.mode == "multi":
        fig = plt.figure(figsize=(13, 9), constrained_layout=True)
        axes = [
            ("top", fig.add_subplot(2, 2, 1)),
            ("side", fig.add_subplot(2, 2, 2)),
            ("front", fig.add_subplot(2, 2, 3)),
            ("3d", fig.add_subplot(2, 2, 4, projection="3d")),
        ]
        return fig, axes

    view = view_for_mode(args.mode)
    fig = plt.figure(figsize=(9, 7), constrained_layout=True)
    ax = fig.add_subplot(111, projection="3d" if view == "3d" else None)

    return fig, [(view, ax)]


def print_3d_hint(points, args):
    if args.mode not in {"3d", "side", "front", "multi"}:
        return

    z_min, z_max = numeric_range(points, "z")

    if z_min is None:
        return

    if abs(z_max - z_min) < 1e-6:
        print(
            "Note: all z values are the same. This capture is effectively 2D. "
            "Use a 3D/elevation Visualizer config if you expect height data."
        )


def build_parser():
    parser = argparse.ArgumentParser(description="Visualize mmWave detected points from mmwave_points.csv")
    parser.add_argument("--points", type=Path, default=DEFAULT_POINTS_PATH)
    parser.add_argument("--mode", choices=["2d", "top", "side", "front", "3d", "multi"], default="2d")
    parser.add_argument("--frame", type=int, help="Frame number to plot. Defaults to latest frame.")
    parser.add_argument("--animate", action="store_true", help="Animate frames instead of plotting one frame")
    parser.add_argument("--save-animation", type=Path, help="Save an animated GIF. Works well in headless WSL.")
    parser.add_argument("--interval", type=int, default=100, help="Animation delay in milliseconds")
    parser.add_argument("--history", type=int, default=1, help="Number of frames to show at once")
    parser.add_argument("--start-frame", type=int)
    parser.add_argument("--end-frame", type=int)
    parser.add_argument("--min-range", type=float, help="Ignore points closer than this many meters")
    parser.add_argument("--max-range", type=float, help="Ignore points farther than this many meters")
    parser.add_argument("--xlim", type=float, nargs=2, metavar=("MIN", "MAX"))
    parser.add_argument("--ylim", type=float, nargs=2, metavar=("MIN", "MAX"))
    parser.add_argument("--zlim", type=float, nargs=2, metavar=("MIN", "MAX"))
    parser.add_argument("--color-by", choices=["doppler", "range", "snr", "noise", "frame"], default="doppler")
    parser.add_argument("--color-min", type=float)
    parser.add_argument("--color-max", type=float)
    parser.add_argument("--cmap", default="coolwarm")
    parser.add_argument("--doppler-limit", type=float, help="Use symmetric doppler color limits, for example 1.0")
    parser.add_argument("--point-size", type=float, default=45)
    parser.add_argument("--history-alpha", type=float, default=0.25)
    parser.add_argument("--no-range-rings", dest="range_rings", action="store_false")
    parser.add_argument("--save", type=Path, help="Save a PNG instead of opening a window. Static plots only.")
    parser.set_defaults(range_rings=True)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.history < 1:
        raise SystemExit("--history must be at least 1")

    if args.save and (args.animate or args.save_animation):
        raise SystemExit("--save is only supported for static plots. Use --save-animation for animation.")

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

    print_3d_hint(points, args)

    frames = group_by_frame(points)
    frame_numbers = sorted(frames)

    if args.frame is not None and args.frame not in frames:
        raise SystemExit(f"Frame {args.frame} was not found in {args.points}")

    fig, axes = create_figure(args)

    if args.animate or args.save_animation:
        animation = FuncAnimation(
            fig,
            lambda frame_number: draw_frame(axes, frames, frame_numbers, frame_number, args, points),
            frames=frame_numbers,
            interval=args.interval,
            repeat=True,
        )
        # Keep a reference alive until plt.show() or save() returns.
        fig._mmwave_animation = animation

        if args.save_animation:
            args.save_animation.parent.mkdir(parents=True, exist_ok=True)
            fps = max(1, round(1000 / args.interval))
            animation.save(args.save_animation, writer="pillow", fps=fps)
            print(f"Saved {args.save_animation}")
        else:
            plt.show()

        return

    frame_number = args.frame if args.frame is not None else frame_numbers[-1]
    scatter = draw_frame(axes, frames, frame_numbers, frame_number, args, points)

    if scatter is not None:
        fig.colorbar(scatter, ax=[ax for _, ax in axes], label=COLOR_LABELS[args.color_by])

    if args.save:
        args.save.parent.mkdir(parents=True, exist_ok=True)
        fig.savefig(args.save, dpi=160)
        print(f"Saved {args.save}")
    else:
        plt.show()
