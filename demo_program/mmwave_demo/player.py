import argparse
import math
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.colors import Normalize
from matplotlib.patches import Circle
from matplotlib.widgets import Button, Slider

from .points import filter_points, group_by_frame, load_points, numeric_range, point_range


DEFAULT_POINTS_PATH = Path("data/processed/mmwave_points.csv")

COLOR_LABELS = {
    "doppler": "doppler (m/s)",
    "range": "range (m)",
    "snr": "snr (dB)",
    "noise": "noise (dB)",
    "frame": "frame number",
}

VIEW_FIELDS = {
    "top": ("x", "y"),
    "side": ("y", "z"),
    "front": ("x", "z"),
}


def axis_label(field):
    return {
        "x": "x left/right (m)",
        "y": "y forward (m)",
        "z": "z height (m)",
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


def finite_values(values):
    return [value for value in values if value is not None and math.isfinite(value)]


def color_limits(points, args):
    values = finite_values([color_value(point, args.color_by) for point in points])

    if not values:
        return 0.0, 1.0

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


def point_offsets(points, x_field, y_field):
    if not points:
        return np.empty((0, 2))

    return np.column_stack((
        [point[x_field] for point in points],
        [point[y_field] for point in points],
    ))


def point_colors(points, color_by):
    values = []

    for point in points:
        value = color_value(point, color_by)
        values.append(np.nan if value is None else value)

    return np.asarray(values, dtype=float)


def padded_limit(low, high):
    if low is None or high is None:
        return -1.0, 1.0

    if low == high:
        padding = abs(low) * 0.1 or 1.0
        return low - padding, high + padding

    padding = (high - low) * 0.08
    return low - padding, high + padding


def axis_limit(points, field, explicit_limit):
    if explicit_limit:
        return explicit_limit

    return padded_limit(*numeric_range(points, field))


class PointPlayer:
    def __init__(self, points, args):
        self.points = points
        self.args = args
        self.frames = group_by_frame(points)
        self.frame_numbers = sorted(self.frames)
        self.index = 0
        self.playing = not args.paused
        self._updating_slider = False
        self.x_field, self.y_field = VIEW_FIELDS[args.mode]

        self.fig, self.ax = plt.subplots(figsize=(10, 7))
        self.fig.subplots_adjust(bottom=0.18)
        self.configure_axes()

        self.history_scatter = self.ax.scatter(
            [],
            [],
            c="lightgray",
            s=max(6, args.point_size * 0.35),
            alpha=args.history_alpha,
            label="history",
        )
        self.latest_scatter = self.ax.scatter(
            [],
            [],
            c=[],
            cmap=args.cmap,
            norm=Normalize(*color_limits(points, args)),
            s=args.point_size,
            edgecolors="black",
            linewidths=0.3,
            label="current frame",
        )
        self.fig.colorbar(self.latest_scatter, ax=self.ax, label=COLOR_LABELS[args.color_by])
        self.ax.legend(loc="upper right")

        slider_ax = self.fig.add_axes([0.15, 0.08, 0.70, 0.03])
        self.slider = Slider(
            slider_ax,
            "Frame",
            0,
            max(0, len(self.frame_numbers) - 1),
            valinit=0,
            valstep=1,
            valfmt="%0.0f",
        )
        self.slider.on_changed(self.on_slider)

        play_ax = self.fig.add_axes([0.15, 0.025, 0.12, 0.04])
        prev_ax = self.fig.add_axes([0.30, 0.025, 0.10, 0.04])
        next_ax = self.fig.add_axes([0.42, 0.025, 0.10, 0.04])
        self.play_button = Button(play_ax, "Pause" if self.playing else "Play")
        self.prev_button = Button(prev_ax, "Prev")
        self.next_button = Button(next_ax, "Next")
        self.play_button.on_clicked(self.toggle_play)
        self.prev_button.on_clicked(lambda _event: self.step(-1))
        self.next_button.on_clicked(lambda _event: self.step(1))

        self.fig.canvas.mpl_connect("key_press_event", self.on_key)
        self.timer = self.fig.canvas.new_timer(interval=args.interval)
        self.timer.add_callback(self.on_timer)
        self.timer.start()
        self.update_plot(draw_now=True)

    def configure_axes(self):
        self.ax.set_xlabel(axis_label(self.x_field))
        self.ax.set_ylabel(axis_label(self.y_field))
        self.ax.grid(True, alpha=0.3)
        self.ax.set_aspect("equal", adjustable="box")
        self.ax.set_xlim(axis_limit(self.points, self.x_field, getattr(self.args, f"{self.x_field}lim")))
        self.ax.set_ylim(axis_limit(self.points, self.y_field, getattr(self.args, f"{self.y_field}lim")))
        self.ax.scatter([0], [0], c="black", marker="^", s=80, label="radar")

        if self.args.mode == "top" and self.args.range_rings:
            x_max = max(abs(value) for value in self.ax.get_xlim())
            y_max = max(abs(value) for value in self.ax.get_ylim())
            max_radius = int(max(x_max, y_max))

            for radius in range(1, max_radius + 1):
                self.ax.add_patch(Circle((0, 0), radius, fill=False, linestyle="--", linewidth=0.5, alpha=0.25))

    def frame_points(self):
        start = max(0, self.index - self.args.history + 1)
        previous = []

        for frame_number in self.frame_numbers[start:self.index]:
            previous.extend(self.frames[frame_number])

        frame_number = self.frame_numbers[self.index]

        return frame_number, previous, self.frames[frame_number]

    def update_plot(self, draw_now=False):
        frame_number, previous, latest = self.frame_points()
        self.history_scatter.set_offsets(point_offsets(previous, self.x_field, self.y_field))
        self.latest_scatter.set_offsets(point_offsets(latest, self.x_field, self.y_field))
        self.latest_scatter.set_array(point_colors(latest, self.args.color_by))
        self.ax.set_title(
            f"{self.args.mode} view | frame {frame_number} | "
            f"{self.index + 1}/{len(self.frame_numbers)} | points={len(latest)} | "
            f"interval={self.timer.interval} ms"
        )

        self._updating_slider = True
        self.slider.set_val(self.index)
        self._updating_slider = False

        if draw_now:
            self.fig.canvas.draw()
        else:
            self.fig.canvas.draw_idle()

    def on_timer(self):
        if self.playing:
            self.step(self.args.frame_step, wrap=True)

        return True

    def on_slider(self, value):
        if self._updating_slider:
            return

        self.index = int(value)
        self.update_plot()

    def step(self, amount, wrap=False):
        new_index = self.index + amount

        if wrap:
            new_index %= len(self.frame_numbers)
        else:
            new_index = max(0, min(len(self.frame_numbers) - 1, new_index))

        if new_index != self.index:
            self.index = new_index
            self.update_plot()

    def toggle_play(self, _event=None):
        self.playing = not self.playing
        self.play_button.label.set_text("Pause" if self.playing else "Play")
        self.fig.canvas.draw_idle()

    def set_interval(self, interval):
        self.timer.interval = max(5, int(interval))
        self.update_plot()

    def on_key(self, event):
        if event.key == " ":
            self.toggle_play()
        elif event.key == "right":
            self.step(1)
        elif event.key == "left":
            self.step(-1)
        elif event.key == "home":
            self.index = 0
            self.update_plot()
        elif event.key == "end":
            self.index = len(self.frame_numbers) - 1
            self.update_plot()
        elif event.key in {"+", "="}:
            self.set_interval(self.timer.interval * 0.75)
        elif event.key in {"-", "_"}:
            self.set_interval(self.timer.interval * 1.25)


def print_3d_hint(points, mode):
    if mode not in {"side", "front"}:
        return

    z_min, z_max = numeric_range(points, "z")

    if z_min is not None and abs(z_max - z_min) < 1e-6:
        print("Note: all z values are the same. This capture is effectively 2D.")


def build_parser():
    parser = argparse.ArgumentParser(description="Fast interactive player for mmWave point CSV files")
    parser.add_argument("--points", type=Path, default=DEFAULT_POINTS_PATH)
    parser.add_argument("--mode", choices=["top", "side", "front"], default="top")
    parser.add_argument("--interval", type=int, default=50, help="Playback delay in milliseconds")
    parser.add_argument("--frame-step", type=int, default=1, help="Advance this many frames per tick")
    parser.add_argument("--history", type=int, default=1, help="Number of frames shown at once")
    parser.add_argument("--paused", action="store_true", help="Open paused instead of playing immediately")
    parser.add_argument("--start-frame", type=int)
    parser.add_argument("--end-frame", type=int)
    parser.add_argument("--min-range", type=float)
    parser.add_argument("--max-range", type=float)
    parser.add_argument("--min-abs-doppler", type=float)
    parser.add_argument("--min-snr", type=float)
    parser.add_argument("--xlim", type=float, nargs=2, metavar=("MIN", "MAX"))
    parser.add_argument("--ylim", type=float, nargs=2, metavar=("MIN", "MAX"))
    parser.add_argument("--zlim", type=float, nargs=2, metavar=("MIN", "MAX"))
    parser.add_argument("--color-by", choices=["doppler", "range", "snr", "noise", "frame"], default="doppler")
    parser.add_argument("--color-min", type=float)
    parser.add_argument("--color-max", type=float)
    parser.add_argument("--cmap", default="coolwarm")
    parser.add_argument("--doppler-limit", type=float)
    parser.add_argument("--point-size", type=float, default=45)
    parser.add_argument("--history-alpha", type=float, default=0.25)
    parser.add_argument("--no-range-rings", dest="range_rings", action="store_false")
    parser.set_defaults(range_rings=True)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.history < 1:
        raise SystemExit("--history must be at least 1")

    if args.frame_step < 1:
        raise SystemExit("--frame-step must be at least 1")

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

    if not points:
        raise SystemExit(f"No points found in {args.points}")

    print_3d_hint(points, args.mode)
    print("Controls: space=play/pause, left/right=step, +/-=speed, home/end=jump")
    PointPlayer(points, args)
    plt.show()
