# Radar backend

Inside this directory:

```bash
cargo run
```

Starts live radar using `configs/golf.cfg`, command UART `/dev/ttyUSB0` at 115200,
data UART `/dev/ttyUSB1` at 921600, and TCP `0.0.0.0:8765`. The default CFG is
resolved relative to this crate. Launch `golf_game` separately, select **Real**,
and connect to the radar computer on port 8765.

```bash
cargo run -- live [config.cfg] [command-port] [data-port] [bind-address:port]
cargo run -- record                 # Overwrites recording.dat with five seconds
cargo run -- analyze [file.dat]     # Defaults to recording.dat
```

## Code path

```text
transport/serial.rs       Open UARTs
radar/device.rs           Upload CFG and read bytes
radar/protocol.rs         Assemble packets and decode frames
processing/detection.rs  Filter candidate points
processing/tracking.rs   Associate nearby points between frames
processing/estimation.rs Estimate speed, direction and elevation
live.rs                  Select a shot and send it to the game's ready turn
```

This restores the first processing draft from `19408b5`, with the early live
connection from `1b34105`. The decoder's later serial-noise recovery fix is retained.

Candidate defaults are 0.2–4 m range, at least 2 m/s absolute radial speed, and
at least 10 dB SNR when available. Tracking uses nearest-distance matches, a
50 m/s maximum matching speed, 0.15 m position tolerance and a two-frame gap limit.
Estimation needs three observations, at least 0.3 m displacement, forward motion,
and a speed of 2–80 m/s. It uses first-to-last positions, with +Y forward and +Z up;
spin is always zero.

Live input uses the CFG's frame period. A burst ends when its tracks expire or
after 0.5 seconds, and the track with the largest displacement × observation count
wins. Offline `analyze` retains the original 20 ms frame period and chooses one
track across the recording. This draft does not separate club and ball motion.

The game connection uses newline-delimited JSON and its existing readiness/turn
IDs. Partial tracks reset when a turn changes, the game disconnects, or frames
stop. Each turn can receive only one shot.

## Checks

```bash
cargo test
```

From the repository root, `python3 -m unittest tests.test_rust_live` exercises CFG
upload, fragmented serial input, shot delivery, turn IDs, frame loss and reconnects
with emulated UARTs. No hardware is needed for these checks.
