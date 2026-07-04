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
