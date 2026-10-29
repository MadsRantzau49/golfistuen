use radar_app::radar::analysis::analyze_recording;
use radar_app::radar::configuration::parse_config;
use radar_app::radar::device::RadarDevice;
use std::fs::File;
use std::io::Write;
use std::time::{Duration, Instant};
use std::io;
use std::net::TcpListener;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();

    let command = args.get(1).map(String::as_str).unwrap_or("help");

    match command {
        "live" => {
            // Positional options keep the existing small CLI dependency-free.
            let config_path = args.get(2).map(String::as_str).unwrap_or("configs/golf.cfg");
            let cli_port = args.get(3).map(String::as_str).unwrap_or("/dev/ttyUSB0");
            let data_port = args.get(4).map(String::as_str).unwrap_or("/dev/ttyUSB1");
            let address = args.get(5).map(String::as_str).unwrap_or("0.0.0.0:8765");
            let config_text = std::fs::read_to_string(config_path)?;
            let commands = parse_config(&config_text);
            let frame_period_s = commands.iter().find_map(|command| {
                let parts: Vec<_> = command.split_whitespace().collect();
                if parts.first() == Some(&"frameCfg") {
                    parts.get(5)?.parse::<f64>().ok().map(|ms| ms / 1000.0)
                } else { None }
            }).filter(|period| period.is_finite() && *period > 0.0)
                .ok_or_else(|| io::Error::other("Live mode requires a valid frameCfg period"))?;
            let listener = TcpListener::bind(address)?;
            let mut device = RadarDevice::new(cli_port, 115200, data_port, 921600)?;
            device.upload_config(&commands)?;
            device.set_data_timeout(Duration::from_millis(20))?;
            eprintln!("Live radar listening on {}. Select Real in Pinewater; Ctrl+C to exit.", listener.local_addr()?);
            let result = radar_app::live::run(&mut device, listener, frame_period_s);
            let _ = device.send_command("sensorStop");
            result?;
        }
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
            println!("  cargo run -- live [config.cfg] [command-port] [data-port] [bind-address:port]");
        }
    }

    Ok(())
}
