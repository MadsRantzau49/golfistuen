use std::fs::File;
use std::io::{Read, Result};

use crate::processing::detection::{detect_candidates, DetectionConfig};
use crate::processing::estimation::{estimate_shot, ShotOutput};
use crate::processing::tracking::{BallTrack, BallTracker, TrackingConfig};
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

pub(crate) fn select_shot(tracks: &[BallTrack]) -> Option<ShotOutput> {
    tracks
        .iter()
        .filter_map(|track| {
            let shot = estimate_shot(track)?;

            let first = track.observations.first()?;
            let last = track.observations.last()?;

            let displacement = (last.x - first.x)
                .hypot(last.y - first.y)
                .hypot(last.z - first.z);

            let score = displacement * track.observations.len() as f32;

            Some((score, shot))
        })
        .max_by(|a, b| a.0.total_cmp(&b.0))
        .map(|(_, shot)| shot)
}

pub fn analyze_recording(path: &str) -> Result<RecordingSummary> {
    let mut file = File::open(path)?;
    let mut decoder = PacketDecoder::new();
    let mut buffer = [0u8; 8192];

    let detection_config = DetectionConfig {
        min_distance_m: 0.2,
        max_distance_m: 4.0,
        min_radial_speed_mps: 2.0,
        min_snr_db: 10.0,
    };

    let tracking_config = TrackingConfig {
        max_speed_mps: 50.0,
        position_tolerance_m: 0.15,
        max_missed_frames: 2,
        frame_period_s: 0.020,
    };

    let mut tracker = BallTracker::new();
    let mut completed_tracks = Vec::new();

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

            let candidates = detect_candidates(&frame, &detection_config);

            summary.total_candidates += candidates.len();

            tracker.update(&frame, &candidates, &tracking_config);

            completed_tracks.extend(tracker.take_completed_tracks());
        }
    }

    tracker.finish();
    completed_tracks.extend(tracker.take_completed_tracks());

    summary.total_tracks_created = tracker.total_tracks_created() as usize;
    summary.shot = select_shot(&completed_tracks);

    Ok(summary)
}
