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

3D view:

```bash
python visualize_points.py --mode 3d --history 30 --xlim -3 3 --ylim 0 5 --zlim -1 2
```

Save a PNG from WSL without opening a GUI:

```bash
python visualize_points.py --history 30 --xlim -3 3 --ylim 0 5 --save data/plots/latest.png
```

Use `--points mmwave_points.csv` when viewing the old root-level capture files.
