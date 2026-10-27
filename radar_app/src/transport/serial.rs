use serialport::SerialPort;
use std::time::Duration;

pub fn connect(path: &str, baud_rate: u32) -> Result<Box<dyn SerialPort>, serialport::Error> {
    serialport::new(path, baud_rate)
        .timeout(Duration::from_millis(1000))
        .open()
}
