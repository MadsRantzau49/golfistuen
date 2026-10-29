use std::fs::File;
use std::io::{Read, Result};

use crate::processing::estimation::ShotOutput;
use crate::processing::shot::{DetectionEvent, ShotDetector, SwingConfig};
use crate::processing::sensor::SensorModel;
use crate::radar::configuration::parse_config;
use crate::radar::protocol::{parse_frame, PacketDecoder};

#[derive(Debug)]
pub struct RecordingSummary {
    pub total_packets: usize,
    pub total_points: usize,
    pub points_with_snr: usize,
    pub total_candidates: usize,
    pub total_tracks_created: usize,
    pub first_frame: Option<u32>,
    pub last_frame: Option<u32>,
    pub shot: Option<ShotOutput>,
}

pub fn analyze_recording(path: &str) -> Result<RecordingSummary> {
    let mut file = File::open(path)?;
    let mut decoder = PacketDecoder::new();
    let mut buffer = [0u8; 8192];

    let path = std::path::Path::new(path);
    let sidecar = path.with_extension("cfg");
    let session_config = path.parent().unwrap_or_else(|| std::path::Path::new(".")).join("radar.cfg");
    let config_path = if sidecar.exists() { sidecar } else if session_config.exists() { session_config }
        else { std::path::PathBuf::from("configs/golf.cfg") };
    let sensor = SensorModel::from_commands(&parse_config(&std::fs::read_to_string(config_path)?))
        .map_err(std::io::Error::other)?;
    let mut detector = ShotDetector::new(sensor, SwingConfig::default());

    let mut summary = RecordingSummary {
        total_packets: 0,
        total_points: 0,
        points_with_snr: 0,
        total_candidates: 0,
        total_tracks_created: 0,
        first_frame: None,
        last_frame: None,
        shot: None,
    };

    loop {
        let bytes_read = file.read(&mut buffer)?;

        if bytes_read == 0 {
            break;
        }

        decoder.push(&buffer[..bytes_read]);

        while let Some(packet) = decoder.next_packet() {
            let Some(frame) = parse_frame(&packet) else {
                eprintln!("Failed to decode packet");
                continue;
            };

            summary.total_packets += 1;
            summary.total_points += frame.points.len();

            summary.points_with_snr += frame
                .points
                .iter()
                .filter(|point| point.side_info.is_some())
                .count();

            if summary.first_frame.is_none() {
                summary.first_frame = Some(frame.frame_number);
            }

            summary.last_frame = Some(frame.frame_number);

            if let Some(DetectionEvent::BallDetected(shot)) = detector.update(&frame) {
                // Preserve the CLI's single-shot output; only confirmed balls qualify.
                if summary.shot.is_none() {
                    summary.shot = Some(shot);
                }
            }
        }
    }

    if let Some(DetectionEvent::BallDetected(shot)) = detector.finish() {
        if summary.shot.is_none() {
            summary.shot = Some(shot);
        }
    }
    summary.total_candidates = detector.total_candidates;
    summary.total_tracks_created = detector.total_tracks_created() as usize;

    Ok(summary)
}
