use radar_app::radar::analysis::analyze_recording;
use radar_app::radar::configuration::parse_config;
use radar_app::radar::device::RadarDevice;
use std::fs::File;
use std::io::Write;
use std::time::{Duration, Instant};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let summary = analyze_recording("recording.dat")?;
    println!("{:?}", summary);
    // return Ok(());
    let config_text = std::fs::read_to_string("configs/golf.cfg")?;

    let commands = parse_config(&config_text);

    let mut radar_device = RadarDevice::new("/dev/ttyUSB0", 115200, "/dev/ttyUSB1", 921600)?;

    radar_device.upload_config(&commands)?;

    println!("Succes");

    let mut file = File::create("recording.dat")?;
    let mut buffer = [0u8; 8192];

    let start = Instant::now();
    let duration = Duration::from_secs(10);
    let mut total_bytes = 0usize;

    while start.elapsed() < duration {
        match radar_device.read_data(&mut buffer) {
            Ok(number_of_bytes) if number_of_bytes > 0 => {
                file.write_all(&buffer[0..number_of_bytes])?;
                total_bytes += number_of_bytes;
            }

            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                // No data currently
            }
            Err(e) => return Err(e.into()),
            _ => {}
        }
    }
    file.flush()?;

    radar_device.send_command("sensorStop")?;

    println!("Recorded {total_bytes} bytes!");

    Ok(())
}
