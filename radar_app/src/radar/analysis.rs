use std::fs::File;
use std::io::{Read, Result};

use crate::radar::protocol::{PacketDecoder, parse_frame};

#[derive(Debug)]
pub struct RecordingSummary {
    pub total_packets: usize,
    pub total_points: usize,
    pub points_with_snr: usize,
    pub first_frame: Option<u32>,
    pub last_frame: Option<u32>,
}

pub fn analyze_recording(path: &str) -> Result<RecordingSummary> {
    let mut file = File::open(path)?;

    let mut decoder = PacketDecoder::new();
    let mut buffer = [0u8; 8192];

    let mut summary = RecordingSummary {
        total_packets: 0,
        total_points: 0,
        points_with_snr: 0,
        first_frame: None,
        last_frame: None,
    };

    loop {
        let bytes_read = file.read(&mut buffer)?;

        if bytes_read == 0 {
            break;
        }

        decoder.push(&buffer[..bytes_read]);

        while let Some(packet) = decoder.next_packet() {
            if let Some(frame) = parse_frame(&packet) {
                if summary.first_frame.is_none() {
                    summary.first_frame = Some(frame.frame_number);
                }
                summary.last_frame = Some(frame.frame_number);
                summary.total_packets += 1;
                summary.total_points += frame.points.len();
                summary.points_with_snr += frame 
                    .points
                    .iter()
                    .filter(|point| point.side_info.is_some())
                    .count();

                println!(
                    "Frame {}: {} detected points",
                    frame.frame_number,
                    frame.points.len()
                );

                for point in &frame.points {
                    println!(
                        "  x={:.2}, y={:.2}, z={:.2}, velocity={:.2} m/s",
                        point.x, point.y, point.z, point.radial_velocity
                    );
                    if let Some(info) = &point.side_info{
                        println!(
                            "  SNR: {:.1} dB | Noise: {:.1} dB",
                            info.snr_db,
                            info.noise_db,
                        );
                    }
                }
            } else {
                eprintln!("Warning: Failed to decode packet");
            }
        }
    }
    Ok(summary)
}
