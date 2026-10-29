use radar_app::radar::analysis::analyze_recording;
use radar_app::radar::configuration::parse_config;
use radar_app::radar::device::RadarDevice;
use radar_app::processing::shot::SwingConfig;
use radar_app::processing::sensor::SensorModel;
use radar_app::live_logging::LiveLog;
use serde_json::json;
use std::fs::File;
use std::io::Write;
use std::time::{Duration, Instant};
use std::io;
use std::net::TcpListener;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();

    let command = args.get(1).map(String::as_str).unwrap_or("help");

    match command {
        "replay-live" => {
            let directory=args.get(2).ok_or_else(||io::Error::other("Usage: replay-live SESSION [detector.json] [report.json]"))?;
            let config:SwingConfig=match args.get(3) {
                Some(path)=>serde_json::from_str(&std::fs::read_to_string(path)?)?,None=>SwingConfig::default()
            };
            let report=radar_app::radar::replay::replay_session(std::path::Path::new(directory),config)?;
            if let Some(path)=args.get(4) {
                serde_json::to_writer_pretty(File::create(path)?,&report)?;
                eprintln!("Replay diagnostics: {path}");
            }
            let attempts:Vec<_>=report["attempts"].as_array().unwrap().iter().map(|attempt|json!({
                "start_frame":attempt["report"]["start_frame"],"end_frame":attempt["end_frame"],
                "outcome":attempt["report"]["outcome"],"shot":attempt["shot"],
                "original_swing_ids":attempt["overlapping_recorded_swing_ids"],
                "best_hypothesis_rejection":attempt["report"]["tracks"][0]["rejection_reason"]
            })).collect();
            println!("{}",serde_json::to_string_pretty(&json!({"statistics":report["statistics"],"attempts":attempts}))?);
        }
        "live" => {
            // Positional options keep the existing small CLI dependency-free.
            let config_path = args.get(2).map(String::as_str).unwrap_or("configs/golf.cfg");
            let cli_port = args.get(3).map(String::as_str).unwrap_or("/dev/ttyUSB0");
            let data_port = args.get(4).map(String::as_str).unwrap_or("/dev/ttyUSB1");
            let address = args.get(5).map(String::as_str).unwrap_or("0.0.0.0:8765");
            let swing: SwingConfig = match args.get(6) {
                Some(path) => serde_json::from_str(&std::fs::read_to_string(path)?)?,
                None => SwingConfig::default(),
            };
            swing.validate().map_err(io::Error::other)?;
            let config_text = std::fs::read_to_string(config_path)?;
            let commands = parse_config(&config_text);
            let sensor = SensorModel::from_commands(&commands).map_err(io::Error::other)?;
            let mut log = LiveLog::start(json!({
                "config_path":config_path, "command_port":cli_port, "data_port":data_port,
                "bind_address":address, "commands":commands,
                "executable":std::env::current_exe().ok(),
                "detector":radar_app::live::LiveDetector::new(sensor.clone(), swing.clone()).configuration()
            }), &config_text)?;
            let result = (|| -> Result<(), Box<dyn std::error::Error>> {
                let listener = TcpListener::bind(address)?;
                let mut device = RadarDevice::new(cli_port, 115200, data_port, 921600)?;
                log.event("configuration_upload_started", json!({}))?;
                device.upload_config(&commands)?;
                log.event("configuration_upload_completed", json!({}))?;
                device.set_data_timeout(Duration::from_millis(20))?;
                eprintln!("Live radar listening on {}. Select Real in Pinewater; Ctrl+C to exit.", listener.local_addr()?);
                eprintln!("Adaptive flight detection: {:.3} m range bins, {:.3} m/s Doppler bins, {:.1} Hz; separate club/ball evidence required.",
                    sensor.range_resolution_m, sensor.doppler_resolution_mps, 1.0/sensor.frame_period_s);
                let result = radar_app::live::run(&mut device, listener, sensor, swing, &mut log);
                let stopped = device.send_command("sensorStop");
                log.event("sensor_stop", json!({"error":stopped.err().map(|e| e.to_string())}))?;
                result?;
                Ok(())
            })();
            log.event("session_ended", json!({"error":result.as_ref().err().map(ToString::to_string)}))?;
            log.checkpoint()?;
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
            println!("  cargo run -- replay-live SESSION [detector.json] [report.json]");
            println!("  cargo run -- live [config.cfg] [command-port] [data-port] [bind-address:port] [swing.json]");
        }
    }

    Ok(())
}
