# Golfistuen — local radar tools

## Pinewater — native golf application

**Pinewater** is a stylized alpine golf game with a loading screen, main menu,
persistent settings, a playable driving range, and an integrated custom-hole
builder. Paint surfaces, sculpt terrain, place trees/cup/tee, save designs and
play them with configurable no-putting scoring. It runs independently of the
radar backend in **Debug** mode, or accepts live radar shots in **Real** mode.

### Play

Open the native application from a release package; no Python or Godot installation
is required. Locally built applications are available at:

- **Linux:** `dist/pinewater/0.2.0/Pinewater-linux/Pinewater`
- **Windows:** `dist/pinewater/0.2.0/Pinewater-windows/Pinewater.exe`

Choose **Enter the range** in the main menu. Press **Space** or click **Launch shot**.
Use **1 / 2 / 3** for driver, iron, and wedge, **R** to reset,
**P** to replay, **Escape** to pause, and **F11** for fullscreen.
The shot camera always follows from behind the aiming line.

### Develop and build

```bash
python3 tools/run_range.py
python3 tools/build_range.py --target linux windows
```

The developer launcher downloads a verified Godot 4.5.1 engine if needed. The
release builder runs checks and creates native executable packages with embedded
game assets, player instructions, licenses and checksums. No pip packages are needed.

See [`golf_game/README.md`](golf_game/README.md) for architecture, the shot contract,
checks, and live radar integration.
See [`golf_game/docs/HOLE_STUDIO.md`](golf_game/docs/HOLE_STUDIO.md) for hole editing,
custom-hole play and automatic green scoring.

## Play with live radar (Rust)

The Rust app in **`radar_app/`** now detects shots continuously from the data UART
and sends JSON straight to Pinewater over TCP. From the repository root:

```bash
# Stop the legacy dashboard first if it is using the radar UARTs.
docker compose stop radar

cargo run --release --manifest-path radar_app/Cargo.toml -- live \
  radar_app/configs/golf.cfg /dev/ttyUSB0 /dev/ttyUSB1 0.0.0.0:8765
```

In another terminal, start the game with `python3 tools/run_range.py`, then open
the range or a local round. In **The next shot**, select **Real · live radar**.
Enter `127.0.0.1` if the Rust app is on the same computer, or the radar computer's
LAN IP (for example `192.168.50.100`) if playing elsewhere. Use port **8765** and
click **Connect / reconnect**. Wait for **READY — SHOOT NOW**, then hit the real
ball: a detected shot launches automatically. Wait for the next ready indication
before the next swing. Local golf applies the shot to the highlighted player.

The Rust command uploads the selected CFG and starts the sensor. Change the port
arguments for your device (Windows accepts `COM3`, `COM4`, etc.). The frame period
is taken from that CFG. Only one game should use the live service at a time.
The game reconnects automatically; paused/busy/disconnected shots are not saved
for a future turn. Debug mode keeps the sliders and Space-to-launch controls.

`spin_rpm` remains zero because the current Rust estimator does not measure spin.
Speed/direction/elevation come from a joint position/Doppler flight fit on live
frames. The default physical target line is radar +Y; in-game aim rotates that launch line.

Shot detection requires **swing → separate ball flight**. The game shows
**SWING DETECTED · checking for ball…**, then either plays the confirmed ball or
shows **NO BALL DETECTED · ready for another swing**. A practice swing leaves the
same turn armed and adds no stroke.

The detector derives measurement scales and frame timing from the actual radar
CFG. It reconstructs outgoing paths backwards, fits position and Doppler jointly
with sensor uncertainty, and chooses the furthest coherent path with independent
evidence that it separates from the observed club envelope. Late tails can qualify
after the club slows/disappears; short visible flights need concurrent separation
evidence. It has no fixed tee distance, ball-only range/lane, maximum XYZ residual
in metres, or arrival deadline from the first club motion. Quiet/missing frames
resolve attempts; configurable resource bounds limit persistent clutter.

`radar_app/configs/swing.json` contains statistical confidence/evidence settings,
sensor-array calibration, physical ball parameters and resource limits. Pass it
as the final argument:

```bash
cargo run --release --manifest-path radar_app/Cargo.toml -- live \
  radar_app/configs/golf.cfg /dev/ttyUSB0 /dev/ttyUSB1 0.0.0.0:8765 \
  radar_app/configs/swing.json
```

Defaults describe an IWR6843ISK with +Y forward/+Z up. The array uncertainty and
mounting axes are explicit settings; adjust them for other hardware/mounting.
See [`radar_app/DETECTION.md`](radar_app/DETECTION.md) for the model, configuration
assumptions, recorded-shot analysis, replay commands and measurement limitations.
Rebuild/relaunch the game to include the detection status text in older packages.

### Always-on live debugging

Every Rust `live` launch automatically creates a new recording directory and
prints its **absolute path** at startup:

```text
Always-on radar debug recording: /.../logs/radar-live/<session>/
```

The default is `logs/radar-live/` relative to the directory where you launch the
command. Set `RADAR_LOG_DIR` to choose a fixed location, for example:

```bash
RADAR_LOG_DIR=/home/rantzau/golfistuen/logs/radar-live \
cargo run --release --manifest-path radar_app/Cargo.toml -- live \
  radar_app/configs/golf.cfg /dev/ttyUSB0 /dev/ttyUSB1 0.0.0.0:8765 \
  radar_app/configs/swing.json
```

Each session contains:

- **`raw-000001.dat`, …:** exact incoming data-UART bytes, including noise,
  malformed packets, club returns and points rejected by every filter. Recording
  continues through cooldowns and while the game is disconnected or unarmed.
  This provides continuous before/after-swing context, rather than saving only
  successful shots. Segments concatenate in numeric order to recover the stream.
- **`events-000001.jsonl`, …:** timestamped UART reads, every decoded frame and all
  its XYZ/Doppler/SNR/noise values, point-gate rejection reasons, swing IDs, arm IDs,
  successful shots, and every `no_ball_detected` result. Completed swings include
  point rejection counts, complete candidate-track observations and each track's
  rejection reason (for example `insufficient_independent_observations`,
  `no_independent_braking_club_and_launch_connection`, or
  `flight_model_inconsistent_with_sensor_uncertainty`). The selected fit includes
  its normalized residual, velocity uncertainty and club-detachment evidence. Connections,
  arm changes, frame gaps/timeouts, decode failures and service errors are logged.
  Attempts interrupted by reconnects, disarming or frame loss are saved as
  `aborted` with their partial tracks and reset reason.
- **`session.json` and `radar.cfg`:** the actual detector/tracker settings,
  frame period, rejection thresholds, ports and radar configuration for that run.

`no_ball_detected` is the detector's decision, **not proof that no ball was hit**.
Use the raw data and rejection reasons to investigate missed real hits. The
terminal also prints a per-swing summary with candidate counts and rejection
reasons. Share the whole session directory when reporting a detection problem.

Raw and event files rotate at 64 MiB without overwriting older segments or sessions;
old recordings are retained until you remove/archive them. Files are written
without userspace buffering and synced at completed/aborted swings, so normal
Ctrl+C/SIGTERM termination retains written frames and bytes. An abruptly stopped
attempt may have a `swing_started` event without a final result; its radar data is
still recorded. A recording-write failure is reported as a service error.

Software checks (no radar required):

```bash
cargo test --manifest-path radar_app/Cargo.toml
python3 -m unittest tests.test_rust_live   # Linux emulated serial UARTs -> Rust -> TCP
python3 tools/run_range.py --check        # Includes live TCP -> game checks
```

See [the live connection contract](golf_game/README.md#live-radar-connection) for
readiness, framing and reconnect details. Existing packaged executables must be
rebuilt to include the new input modes.

## Shot notes — timed attempts for debugging

Choose **Shot notes · timed capture** in Pinewater's main menu. Press **Space**
before taking a real shot and **Space** again afterwards. Each attempt gets its
own saved log window, even when no ball is detected. Then click your estimates:

- Speed: **Low / Medium / High / Full speed**
- Elevation: **Rolling / Very low jumping / Low / Medium / Good swing / Too high / Instant ceiling**
- Direction: **Full left / Left / Straight / Right / Full right**

Other notes are optional and default to **None**. Descriptions auto-save and can
be edited in shot history. Each JSON record includes timing, frame/byte references,
the description and a detector-result summary. Local drafts survive disconnections.
The form also shows the registered detector estimate live: speed, elevation and
direction, independently of your own labels. Registered estimates persist in history
and remain visible if later movement is unconfirmed.

```bash
python3 tools/run_range.py --shot-notes
```

See [`golf_game/docs/SHOT_NOTES.md`](golf_game/docs/SHOT_NOTES.md) for controls,
saved file locations and the debugging workflow.
Restart the updated Rust service and rebuild/relaunch older packaged games.

## Legacy Python radar dashboard

**`radar_app_python/`** contains the web dashboard, live serial connection, CFG
editing, exact-byte recording, saved sessions, replay, and analysis.
Docker Compose runs that application and a Raspberry Pi 5 USB-power helper.

## Start with Docker Compose

Install Docker Engine and Docker Compose. The included `.env` already contains this machine's settings; no copying is needed. Ensure the host directories `configs/` and `logs/` exist and are writable by your user.

Plug the radar into USB before starting. The main Compose file includes both USB ports and their access permissions. This Pi's `.env` enables the `pi5-usb-power` Compose profile for the USB-power helper; disable that profile on other machines unless they have the same USB root-hub device paths.

`RADAR_UID=1000` and `RADAR_GID=1003` make Docker save files as your Linux user on this machine. `RADAR_SERIAL_GID=20` gives the container access to the USB ports through the Linux `dialout` group. These are permission IDs, not passwords. They only need adjusting if you move the project to a machine with different user or device-group IDs.

```bash
docker compose up --build -d --wait
```

Open **http://127.0.0.1:8000** on the Pi or **http://192.168.50.100:8000** from another device on the LAN. `RADAR_LAN_HOST` in `.env` sets the Pi address accepted by the app and published by Docker; update it if the Pi's address changes. Docker installs the Python dependencies and starts one backend worker. The dashboard supports live radar, configuration editing, and saved-recording analysis. Select the command and data ports and click **Connect**. Startup does not connect to or configure the radar.

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

To change these settings on this Pi 5, stop recording, then click **Radar power off** in the dashboard. Verify that its LED goes out. Click **Radar power on** (the app waits five seconds before restoring power), reconnect the two UARTs and apply the desired CFG first. The app clears its latched-configuration guard only after a completed off/on cycle. Alternatively, unplug the radar's USB cable until its LED goes out, wait five seconds, reconnect it and run `docker compose up -d --force-recreate --wait`. This is required when moving between `default.cfg` (TX mask 5) and `fast_ball.cfg` (TX mask 7).

**Pi 5 USB power:** toggling only the USB2 hubs made the CP2105 UARTs disappear but left the radar LED blinking. The verified power-cycle sequence on this Pi uses `uhubctl -e -l HUB -a off` for hubs **5, 4, 3, 2** in that order, and the same order with `-a on`. The helper does exactly this; it considers the board reset only when *all* hub ports were off before restoring them. All four USB-A sockets lose power, so do not use USB storage on them while cycling the radar. The helper only has access to these root hubs and has no port published on the LAN. If Docker was stopped while power was off and cannot start because `/dev/ttyUSB*` are missing, start just the helper with `docker compose up -d usb_power`, restore power with `docker compose exec usb_power python -c "import urllib.request; urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8765/power/on', method='POST')).read()"`, then run `docker compose up -d --wait`.

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
