use radar_app::debug::frame::print_frames;
use radar_app::radar::configuration::parse_config;
use radar_app::radar::device::RadarDevice;
use std::fs::File;
use std::io::{self, Write};
use std::net::TcpListener;
use std::path::Path;
use std::time::{Duration, Instant};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let command = args.get(1).map(String::as_str).unwrap_or("live");
    let default_config = Path::new(env!("CARGO_MANIFEST_DIR")).join("configs/rughaven.cfg");

    match command {
        "live" => {
            let config_path = args.get(2).map(Path::new).unwrap_or(&default_config);
            let cli_port = args.get(3).map(String::as_str).unwrap_or("/dev/ttyUSB0");
            let data_port = args.get(4).map(String::as_str).unwrap_or("/dev/ttyUSB1");
            let address = args.get(5).map(String::as_str).unwrap_or("0.0.0.0:8765");
            let commands = parse_config(&std::fs::read_to_string(config_path)?);
            let listener = TcpListener::bind(address)?;
            let mut device = RadarDevice::new(cli_port, 115200, data_port, 921600)?;
            device.upload_config(&commands)?;
            let result = (|| {
                device.set_data_timeout(Duration::from_millis(20))?;
                eprintln!(
                    "Radar acquiring frames; status service on {}. Detection is disabled; Ctrl+C to exit.",
                    listener.local_addr()?
                );
                radar_app::live::run(&mut device, listener)
            })();
            let stopped = device.send_command("sensorStop");
            result?;
            stopped?;
        }
        "record" => {
            let commands = parse_config(&std::fs::read_to_string(default_config)?);
            let mut device: RadarDevice =
                RadarDevice::new("/dev/ttyUSB0", 115200, "/dev/ttyUSB1", 921600)?;
            device.upload_config(&commands)?;
            let result = (|| -> io::Result<usize> {
                let mut file = File::create("recording.dat")?;
                let mut buffer = [0; 8192];
                let start = Instant::now();
                let mut total_bytes = 0;
                println!("Recording started!");
                while start.elapsed() < Duration::from_secs(5) {
                    match device.read_data(&mut buffer) {
                        Ok(n) => {
                            file.write_all(&buffer[..n])?;
                            total_bytes += n;
                        }
                        Err(e) if e.kind() == io::ErrorKind::TimedOut => {}
                        Err(e) => return Err(e),
                    }
                }
                file.flush()?;
                Ok(total_bytes)
            })();
            let stopped = device.send_command("sensorStop");
            let total_bytes = result?;
            stopped?;
            println!("Recorded {total_bytes} bytes!");
        }

        "debug" => {
            let min_velocity: f32 = args
                .get(2)
                .and_then(|s| s.parse::<f32>().ok())
                .unwrap_or(5.0);
            let commands = parse_config(&std::fs::read_to_string(default_config)?);
            let mut device: RadarDevice =
                RadarDevice::new("/dev/ttyUSB0", 115200, "/dev/ttyUSB1", 921600)?;
            device.upload_config(&commands)?;

            println!("Printing radar frames. Ctrl+C to exit.");
            print_frames(&mut device, min_velocity)?;
        }
        "help" | "--help" | "-h" => print_usage(),
        _ => {
            print_usage();
            return Err(io::Error::other(format!("Unknown command: {command}")).into());
        }
    }
    Ok(())
}

fn print_usage() {
    println!("Usage:");
    println!("  cargo run                         Receive live frames (no detection)");
    println!("  cargo run -- live [config.cfg] [command-port] [data-port] [bind-address:port]");
    println!("  cargo run -- record               Record five seconds to recording.dat");
}
