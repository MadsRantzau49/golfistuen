# mmWave Demo Program

This folder is split into capture, data handling, visualization, configs, and generated data.

```text
capture.py                 clean capture entry point
analyze_points.py          quick CSV summary tool
visualize_points.py        2D/3D point-cloud viewer
play_points.py             fast interactive playback viewer
track_motion.py            one-row-per-frame motion summary
log_mmwave_packets.py      compatibility wrapper for capture.py
visualize_mmwave_points.py compatibility wrapper for visualize_points.py
mmwave_demo/               reusable implementation modules
configs/                   Visualizer .cfg files
data/raw/                  raw binary packet captures
data/processed/            decoded CSV files
data/plots/                saved debug plots
```

## Capture

## WSL vs Windows

You can do the normal development loop in WSL:

```text
capture serial data
send .cfg files
write raw packets and CSV files
run analysis scripts
generate 2D/3D plots and GIFs
iterate on Python code
```

Windows is still useful, or sometimes required, for:

```text
installing/binding the USB device with usbipd-win
flashing radar firmware with UniFlash
using TI mmWave Demo Visualizer as the reference UI
exporting new Visualizer .cfg files
```

After the USB device is attached with `usbipd`, you can stay in WSL for capture and visualization.

WSL USB mapping for the CP2105 board:

```text
/dev/ttyUSB0 = command/config port, 115200 baud
/dev/ttyUSB1 = data port, 921600 baud
```

Put a Visualizer config in `configs/default.cfg`, then run:

```bash
python capture.py --config-port /dev/ttyUSB0 --config-file configs/default.cfg --data-port /dev/ttyUSB1
```

Default outputs:

```text
data/raw/mmwave_raw_packets.bin
data/processed/mmwave_frames.csv
data/processed/mmwave_points.csv
```

For a short test capture:

```bash
python capture.py --config-port /dev/ttyUSB0 --config-file configs/default.cfg --data-port /dev/ttyUSB1 --max-frames 50
```

Try the SDK sample 3D/elevation profile:

```bash
python capture.py --config-port /dev/ttyUSB0 --config-file configs/profile_3d.cfg --data-port /dev/ttyUSB1 --max-frames 100
```

Then check whether `z` is still flat:

```bash
python analyze_points.py
python visualize_points.py --mode multi --history 30 --xlim -3 3 --ylim 0 5 --zlim -1 2
```

Hand/debug 3D profile for slow movement and coordinate sanity checks:

```bash
python capture.py --config-port /dev/ttyUSB0 --config-file configs/hand_debug_3d.cfg --data-port /dev/ttyUSB1
```

View mostly moving points only:

```bash
python visualize_points.py --mode multi --history 20 --min-abs-doppler 0.2 --xlim -2 2 --ylim 0 5 --zlim -1 2
```

Golf ball short-range/high-speed profile:

```bash
python capture.py --config-port /dev/ttyUSB0 --config-file configs/golf_ball_fast_2d.cfg --data-port /dev/ttyUSB1
```

This profile limits detection to 5 m and prioritizes velocity by using one TX antenna. It is not a true 3D/elevation profile.

If the fast profile stops after one frame, use the conservative profile first:

```bash
python capture.py --config-port /dev/ttyUSB0 --config-file configs/golf_ball_stable_2d.cfg --data-port /dev/ttyUSB1
```

If the command port stops answering after a bad config, press the board reset button or power-cycle it, then reattach with `usbipd` if needed.

## Hand vs Golf Ball Testing

A moving hand is a good sanity test for:

```text
USB/serial pipeline
coordinate orientation
range limits
visualization
whether z/elevation is present
```

A moving hand is not a good test for final golf-ball velocity because a hand is large, slow, non-rigid, and produces many radar points. A golf ball is small, fast, and may appear as only one or a few points.

Use `configs/hand_debug_3d.cfg` for hand tests. Use `configs/golf_ball_fast_2d.cfg` for fast short-range ball tests.

The golf-ball fast config is intentionally 2D. `z=0` is expected because it uses one TX antenna to maximize velocity. The fast profile also has coarse Doppler bins, so slow hand movement can appear quantized or jumpy.

For hand movement, move directly toward or away from the radar along the `y` direction. Sideways hand motion is mostly angle change, not radial Doppler, so it is harder to interpret.

## Analyze

```bash
python analyze_points.py
```

Or analyze an older root-level capture:

```bash
python analyze_points.py --points mmwave_points.csv
```

Per-frame motion summary, useful for hand tests:

```bash
python track_motion.py --select strongest --min-abs-doppler 0.2 --limit 30
```

Track the fastest point per frame:

```bash
python track_motion.py --select fastest --min-abs-doppler 0.2
```

## Visualize

Fast interactive playback, recommended instead of GIF while debugging:

```bash
python play_points.py --history 20 --min-abs-doppler 0.2 --xlim -2 2 --ylim 0 5 --interval 40
```

Useful controls:

```text
space       play/pause
left/right  previous/next frame
+/-         faster/slower playback
home/end    first/last frame
slider      scrub through frames
```

Side-view playback for checking `z`:

```bash
python play_points.py --mode side --history 20 --ylim 0 5 --zlim -1 2 --interval 40
```

Top-down 2D view:

```bash
python visualize_points.py --history 30 --xlim -3 3 --ylim 0 5
```

Side view, useful for checking height/elevation data:

```bash
python visualize_points.py --mode side --history 30 --ylim 0 5 --zlim -1 2
```

Front view:

```bash
python visualize_points.py --mode front --history 30 --xlim -3 3 --zlim -1 2
```

3D view:

```bash
python visualize_points.py --mode 3d --history 30 --xlim -3 3 --ylim 0 5 --zlim -1 2
```

Multi-view dashboard:

```bash
python visualize_points.py --mode multi --history 30 --xlim -3 3 --ylim 0 5 --zlim -1 2
```

Color by signal strength when using a new capture with SNR/noise columns:

```bash
python visualize_points.py --color-by snr --history 30 --xlim -3 3 --ylim 0 5
```

Color by distance:

```bash
python visualize_points.py --color-by range --history 30 --xlim -3 3 --ylim 0 5
```

Save a PNG from WSL without opening a GUI:

```bash
python visualize_points.py --history 30 --xlim -3 3 --ylim 0 5 --save data/plots/latest.png
```

Save an animated GIF from WSL:

```bash
python visualize_points.py --mode multi --history 30 --xlim -3 3 --ylim 0 5 --zlim -1 2 --save-animation data/plots/movement.gif
```

Faster but less detailed GIF, using every fifth frame:

```bash
python visualize_points.py --history 20 --frame-step 5 --interval 40 --xlim -2 2 --ylim 0 5 --save-animation data/plots/movement_fast.gif
```

Use `--points mmwave_points.csv` when viewing the old root-level capture files.

If the script prints that all `z` values are the same, the capture is effectively 2D. Use a 3D/elevation Visualizer config if you expect height data.
