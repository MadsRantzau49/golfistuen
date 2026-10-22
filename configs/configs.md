# IWR6843 golf-shot debug configuration

This configuration is for the IWR6843ISK out-of-box mmWave SDK 3.6 demo. It keeps all four receivers and all three transmitters enabled, so the processed point cloud can contain range, radial velocity, horizontal angle, and elevation information.

The configuration is intentionally kept close to the current working test. The controlled change is the Doppler CFAR threshold: it is `15` dB here instead of the `2` dB used in the last capture. A higher threshold should reject more weak stationary artifacts, but it can also reject a weak foam ball.

## How to load it

1. Stop the radar before sending a new configuration.
2. Send the file from top to bottom through the mmWave Visualizer or your serial tool.
3. Save the resulting raw `.dat` stream and the exact `.cfg` file together.
4. For a controlled comparison, keep the radar position, ball, lighting, and shot direction the same.

If the board was already running, `sensorStop` and `flushCfg` are the first two commands. Changing the RF channel or ADC format can require a real power reset; this file does not change those settings from the current setup.

## Configuration reference

### Startup and channel selection

| Command | Meaning |
|---|---|
| `sensorStop` | Stops the current measurement before settings are changed. |
| `flushCfg` | Clears the old CLI configuration from firmware memory. It does not power-cycle the board. |
| `dfeDataOutputMode 1` | Selects normal repeating frame measurements. |
| `channelCfg 15 7 0` | Enables all 4 receive antennas (`15` = binary `1111`) and all 3 transmit antennas (`7` = binary `111`). The last `0` means this is a single, non-cascaded radar. |
| `adcCfg 2 1` | Selects the demo's ADC output format. This controls how the ADC samples are represented, not the number of samples. |
| `adcbufCfg -1 0 1 1 1` | Selects how ADC samples are placed in the radar's internal buffer so the DSP can read them. Keep it matched to the ADC format. |

### Chirp profile

`profileCfg` defines the common waveform and sampling settings for every chirp:

```text
profileCfg 0 60 3.5 4 10.5 0 0 150 1 64 12500 0 0 158
```

| Position | Value | Meaning |
|---:|---:|---|
| 1 | `0` | Profile ID. The chirps below refer to profile 0. |
| 2 | `60` | Starting RF frequency, approximately 60 GHz. |
| 3 | `3.5` | Idle time before the next chirp's useful timing, in microseconds. It gives the RF hardware time between chirps. |
| 4 | `4` | ADC start time after the chirp begins, in microseconds. |
| 5 | `10.5` | End of the frequency ramp, in microseconds. Together with the slope this defines the chirp bandwidth. |
| 6 | `0` | Transmit output-power backoff setting. `0` means no extra backoff in this profile. |
| 7 | `0` | Transmit phase-shifter setting. `0` means no extra phase shift. |
| 8 | `150` | Frequency slope, in MHz per microsecond. A larger slope gives more bandwidth and finer range resolution, but requires valid RF/ADC timing. |
| 9 | `1` | Transmit start-time adjustment. |
| 10 | `64` | ADC samples captured for each receive channel during each chirp. More samples improve range processing detail but increase work and memory. |
| 11 | `12500` | ADC sample rate in ksample/s: 12.5 million complex samples/s. |
| 12 | `0` | First analog high-pass filter selection. |
| 13 | `0` | Second analog high-pass filter selection. |
| 14 | `158` | Receiver gain code. It is an internal gain value, not 158 dB. |

This short profile is tuned for a high speed limit. It is not a promise that every 100 km/h shot will be detected; the ball must also produce a strong enough echo and remain inside the antenna field of view.

### Transmit chirps

| Command | Meaning |
|---|---|
| `chirpCfg 0 0 0 0 0 0 0 1` | Defines chirp 0 and enables TX1 (`001`). |
| `chirpCfg 1 1 0 0 0 0 0 4` | Defines chirp 1 and enables TX3 (`100`). |
| `chirpCfg 2 2 0 0 0 0 0 2` | Defines chirp 2 and enables TX2 (`010`). |

The first two numbers are the start and end chirp indexes. Since they are equal, each line applies to one chirp only. The last number is the TX antenna bit mask. Using three different TX chirps provides the spatial information needed for horizontal angle and elevation on the IWR6843ISK.

### Frame timing

```text
frameCfg 0 2 128 0 20 1 0
```

| Position | Value | Meaning |
|---:|---:|---|
| 1 | `0` | First chirp index in the loop. |
| 2 | `2` | Last chirp index in the loop. The loop is TX1, TX3, TX2. |
| 3 | `128` | Number of loop repetitions. Each loop has 3 chirps, so one frame has 384 chirps. |
| 4 | `0` | Continuous operation. |
| 5 | `20` | Frame period in milliseconds: 50 frames/s. |
| 6 | `1` | Software-triggered frame mode. |
| 7 | `0` | No trigger delay. |

The 20 ms period is a processing and update-rate choice. It does not by itself set the maximum target speed; the chirp timing and number of chirps determine the Doppler measurement limit.

### Detection and output

| Command | Meaning |
|---|---|
| `lowPower 0 0` | Uses the normal ADC/RF power mode. |
| `guiMonitor -1 1 0 0 0 0 0` | Sends detected points and their side information to the host; optional extra visualizations remain disabled. |
| `cfarCfg -1 0 2 8 4 3 0 12 1` | Range CFAR detector. The `12` is the range detection threshold in dB. Lower values find weaker objects but increase false detections. |
| `cfarCfg -1 1 0 4 2 3 1 15 1` | Doppler CFAR detector. The `15` is the Doppler detection threshold in dB. This is the controlled change from the last capture, where it was `2`. |
| `multiObjBeamForming -1 1 0.5` | Allows additional angle-separated detections within the same range/velocity cell. |
| `clutterRemoval -1 1` | Subtracts the average stationary signal. This can reduce desk/wall reflections, but a stopped or very slow ball can also be removed. |
| `calibDcRangeSig -1 0 -5 8 256` | Leaves DC/antenna-coupling calibration disabled. |
| `extendedMaxVelocity -1 0` | Leaves the optional extended-velocity processing disabled. |
| `bpmCfg -1 0 0 1` | Leaves binary phase modulation disabled. This file uses ordinary time-division multiplexed TX chirps. |
| `lvdsStreamCfg -1 0 0 0` | Disables LVDS raw streaming; the normal USB serial output is used. |

### Calibration and monitoring

| Command | Meaning |
|---|---|
| `compRangeBiasAndRxChanPhase ...` | Uses neutral range-bias and RX phase corrections because no measured calibration values were supplied. |
| `measureRangeBiasAndRxChanPhase 0 1.5 0.2` | Does not start a measurement. The `1.5` and `0.2` are calibration-procedure parameters. |
| `CQRxSatMonitor 0 3 5 121 0` | Configures the receive saturation monitor; the final `0` leaves its reporting disabled. |
| `CQSigImgMonitor 0 127 4` | Configures the signal/image quality monitor. |
| `analogMonitor 0 0` | Disables the optional analog monitors. |
| `aoaFovCfg -1 -90 90 -90 90` | Allows the full configured horizontal and vertical angle field of view. |

### Output filters and shutdown/start

| Command | Meaning |
|---|---|
| `cfarFovCfg -1 0 0 7` | Keeps range detections from 0 to 7 metres. This filters output; it does not increase RF sensitivity. |
| `cfarFovCfg -1 1 0 29` | Keeps positive radial velocities from 0 to 29 m/s, meaning motion away from the radar in this setup. This is an output filter, not the fundamental Doppler limit. |
| `calibData 0 0 0` | Does not save or restore RF calibration data. |
| `sensorStart` | Starts repeating measurements using the configuration above. |

## Which settings depend on each other?

- `channelCfg`, `adcCfg`, `adcbufCfg`, the number of ADC samples, and the number of enabled TX antennas determine memory layout and processing workload.
- `profileCfg` timing, chirp count, and loop count determine the Doppler speed limit, velocity resolution, and processor workload.
- `freqSlopeConst`, ADC sample rate, and ADC sample count determine bandwidth and range resolution.
- `cfarCfg` decides which peaks become detections; `cfarFovCfg` removes detections outside the requested distance or velocity range afterward.
- `chirpCfg` and `frameCfg` must agree: every chirp index used by `frameCfg` must have a matching `chirpCfg` line.
- `aoaFovCfg` only limits accepted angles; it cannot recover angle information that was not measured by the antenna/TX arrangement.

## Controlled test for this version

Record a few seconds with the room still, then make one similar foam-ball shot. Compare the stationary false-detection rate with the previous file. If near-zero-metre detections decrease, the earlier `2 dB` Doppler threshold was allowing weak artifacts through. If they remain, leave the threshold at 15 and investigate timing, antenna coupling, and calibration next.
