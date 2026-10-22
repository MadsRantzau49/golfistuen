# Golfistuen — local radar tools

## One radar application

Everything lives in **`radar_app/`**: the web dashboard, live serial connection, CFG editing, exact-byte recording, saved sessions, replay, and analysis.

The shared decoder and offline export code is in `radar_app/analyzer.py`, and the replay template is in `radar_app/static/viewer.html`. Docker Compose runs the complete application as one service.

## Start with Docker Compose

Install Docker Engine and Docker Compose. The included `.env` already contains this machine's settings; no copying is needed. Ensure the host directories `configs/` and `logs/` exist and are writable by your user.

Plug the radar into USB before starting. The main Compose file includes both USB ports and their access permissions.

`RADAR_UID=1000` and `RADAR_GID=1000` make Docker save files as your Linux user. `RADAR_SERIAL_GID=20` gives the container access to the USB ports through the Linux `dialout` group. These are permission IDs, not passwords. They only need adjusting if you move the project to a machine with different user or device-group IDs.

```bash
docker compose up --build -d --wait
```

Open **http://127.0.0.1:8000**. Docker installs the Python dependencies and starts one backend worker. The dashboard supports live radar, configuration editing, and saved-recording analysis. Select the command and data ports and click **Connect**. Startup does not connect to or configure the radar.

`configs/` and `logs/` are bind-mounted, so edited configurations, imports, and recorded sessions survive container replacement. Put DAT/CFG pairs directly in `logs/` to import them using **Saved sessions**. The optional real-data demo requires `radar_app/example_input/recording.dat` and `profile.cfg`, which are not included in this checkout; use your own paired recording for replay.

```bash
docker compose logs -f radar
docker compose down
```

### Live radar over USB (Linux)

Plug in the board and identify its command and data UARTs:

```bash
ls -ln /dev/ttyUSB*
```

The `.env` is configured for command port `/dev/ttyUSB0`, data port `/dev/ttyUSB1`, and USB group `20`, matching the connected radar's device paths and permissions on this machine. If the paths change, update `RADAR_COMMAND_PORT` and `RADAR_DATA_PORT`. Both UARTs must exist before starting Docker Compose.

```bash
docker compose up --build -d --wait
```

Compose passes those two devices to the container and adds their group. Select the same device paths in the dashboard, connect, and explicitly apply your CFG. Close other programs using those UARTs first. After USB reconnection, check the paths and run `docker compose up -d --force-recreate --wait`. Docker Desktop requires USB forwarding to its Linux VM before these devices are available.

### Resetting the board and switching CFGs

Restarting Docker or reconnecting the UARTs resets the application connection. `sensorStop` stops measurements, and `flushCfg` clears CLI configuration. Neither operation power-cycles the radar.

TI SDK 3.6 latches `channelCfg`, `adcCfg`, and `lowPower` on the first sensor start. Changing them later can halt the firmware. In the installed SDK, `mss/mmw_cli.c:288` is the assertion for a changed channel configuration. The dashboard rejects known changes before sending commands, including after a UART disconnect/reconnect.

To change these settings, unplug the USB-powered board for five seconds, reconnect it, run `docker compose up -d --force-recreate --wait`, then connect in the dashboard and apply the desired CFG first. If the board has external power, it must also be power-cycled. This is required when moving between `default.cfg` (TX mask 5) and `fast_ball.cfg` (TX mask 7).

Hardware troubleshooting on this board found a separate issue: a baseline with three transmitters streamed successfully, but changing only chirp idle time from 567 µs to 7 µs caused the entire USB device to disconnect. `fast_ball.cfg` also failed from a fresh power cycle. Its short-idle settings are therefore not hardware-verified; power delivery is a suspect, not a confirmed cause. `default.cfg` is the verified baseline. Selecting a different CFG in the browser does not change the active settings until **Apply** is clicked.

Run the fixture-independent open-configuration regression checks with:

```bash
python -m unittest tests.test_open_configuration
```

### Offline analyzer in Docker

With an image built by `docker compose build`, analyze a paired recording already placed in `logs/`:

```bash
docker compose run --rm --no-deps radar python -m radar_app.analyzer \
  logs/shot.dat logs/shot.cfg --out logs/shot-analysis
```

Open `logs/shot-analysis/replay.html` for standalone replay. The same directory contains `recording.json`, `summary.json`, `points.csv`, and `frames.csv`.

## Original firmware / Windows setup reference

The following pre-existing instructions are retained for reference. The dashboard assumes your board already has its working standard SDK firmware; it does not flash firmware or change the SDK.

# Setup

Download and install these four things in this order.

## 1. USB Driver

Download the CP210x USB to UART Bridge VCP Drivers from Silicon Labs:

https://www.silabs.com/software-and-tools/usb-to-uart-bridge-vcp-drivers

This makes the board show up as COM ports in Windows.

Click:

`Downloads -> Windows driver`

Install it, then restart your PC if needed.

## 2. TI UniFlash

Download UNIFLASH, also known as CCStudio UniFlash, for most TI microcontrollers and mmWave sensors:

https://www.ti.com/tool/UNIFLASH

This is used to flash firmware to the radar board.

Click:

`Downloads -> UNIFLASH -> Windows installer`

## 3. TI mmWave SDK

Download MMWAVE-SDK, the mmWave software development kit:

https://www.ti.com/tool/MMWAVE-SDK

For IWR6843ISK, use the normal MMWAVE-SDK. Do not use MMWAVE-L-SDK or MMWAVE-MCUPLUS-SDK.

The current SDK page lists support for xWR6843 / IWR6843 and shows version `03.06.02.00-LTS`.

Click:

`Downloads -> MMWAVE-SDK -> Windows installer`

The file name should look like:

`mmwave_sdk_03_06_02_00-LTS-Windows-x86-Install.exe`

## 4. mmWave Demo Visualizer

Download or use mmWave Demo Visualizer version `3.6.0`.

This is important. Do not use version 4.x for an IWR6843ISK with the normal SDK 3.6 demo. TI's gallery shows that Visualizer 3.6.0 is for sensors running mmWave SDK v3.6.0 or later, while 4.x is for the newer MCU+ SDK line.

Go to TI Developer Zone / TI Gallery:

https://dev.ti.com/gallery/

Search for `mmWave Demo Visualizer`, choose version `3.6.0`, then download the Windows runtime/app.

A TI forum answer also confirms that for SDK 03.06, you should use the Visualizer made for 3.6, not the newer 4.x visualizer.

## After Installing

Plug in the board with USB. In Windows Device Manager you should see two COM ports.

Use these port settings:

```text
CFG / command port: 115200 baud
DATA port:          921600 baud
```

## Simple Checklist

1. Install CP210x driver.
2. Install UniFlash.
3. Install MMWAVE-SDK `03.06.02.00-LTS`.
4. Install/open mmWave Demo Visualizer `3.6.0`.
5. Plug in board.
6. Check two COM ports.
7. Flash `xwr68xx_mmw_demo.bin`.
8. Open Visualizer and test live dots.

The firmware file you flash is normally here:

```text
C:\ti\mmwave_sdk_03_06_02_00-LTS\packages\ti\demo\xwr68xx\mmw\xwr68xx_mmw_demo.bin
```
