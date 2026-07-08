# mmWave Demo Program

This folder is split into capture, data handling, visualization, configs, and generated data.

```text
capture.py                 clean capture entry point
analyze_points.py          quick CSV summary tool
visualize_points.py        2D/3D point-cloud viewer
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

## Analyze

```bash
python analyze_points.py
```

Or analyze an older root-level capture:

```bash
python analyze_points.py --points mmwave_points.csv
```

## Visualize

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

Use `--points mmwave_points.csv` when viewing the old root-level capture files.

If the script prints that all `z` values are the same, the capture is effectively 2D. Use a 3D/elevation Visualizer config if you expect height data.
