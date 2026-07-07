change com ports to WSL:
``& "C:\Program Files\usbipd-win\usbipd.exe" attach --wsl --busid 2-3``


run program:

python log_mmwave_packets.py 
  --config-port /dev/ttyUSB0 
  --config-file ../configs/default.cfg 
  --data-port /dev/ttyUSB1
