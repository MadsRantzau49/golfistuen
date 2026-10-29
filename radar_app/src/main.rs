use radar_app::radar::analysis::analyze_recording;
use radar_app::radar::configuration::parse_config;
use radar_app::radar::device::RadarDevice;
use std::fs::File;
use std::io::Write;
use std::time::{Duration, Instant};
use std::io;
use std::error::Error;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();

    let command = args.get(1).map(String::as_str).unwrap_or("help");

    match command {
        "analyze" => {
            let path = args.get(2).map(String::as_str).unwrap_or("recording.dat");

            let summary = analyze_recording(path)?;

            let shot = summary.shot.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "No valid shot found in recording",
                )
            })?;

            println!("{}", serde_json::to_string_pretty(&shot)?);
        }

        "record" => {
            let config_text = std::fs::read_to_string("configs/golf.cfg")?;
            let commands = parse_config(&config_text);

            let mut radar_device =
                RadarDevice::new("/dev/ttyUSB0", 115200, "/dev/ttyUSB1", 921600)?;

            radar_device.upload_config(&commands)?;

            println!("Recording started!");

            let mut file = File::create("recording.dat")?;
            let mut buffer = [0u8; 8192];

            let start = Instant::now();
            let duration = Duration::from_secs(5);
            let mut total_bytes = 0usize;

            while start.elapsed() < duration {
                match radar_device.read_data(&mut buffer) {
                    Ok(number_of_bytes) if number_of_bytes > 0 => {
                        file.write_all(&buffer[..number_of_bytes])?;
                        total_bytes += number_of_bytes;
                    }

                    Err(e) if e.kind() == io::ErrorKind::TimedOut => {
                        // No data currently
                    }

                    Err(e) => return Err(e.into()),

                    _ => {}
                }
            }

            file.flush()?;
            radar_device.send_command("sensorStop")?;

            println!("Recorded {total_bytes} bytes!");
        }

        _ => {
            println!("Usage:");
            println!("  cargo run -- record");
            println!("  cargo run -- analyze [file.dat]");
        }
    }

    Ok(())
}
