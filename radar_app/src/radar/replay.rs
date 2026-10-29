//! Deterministic replay of the original decoded observations and arming history.
use crate::processing::sensor::SensorModel;
use crate::processing::shot::{DetectionEvent, ShotDetector, SwingConfig};
use crate::radar::configuration::parse_config;
use crate::radar::frame::{PointSideInfo, RadarFrame, RadarPoint};
use serde_json::{Value, json};
use std::fs::File;
use std::io::{self, BufRead, BufReader};
use std::path::Path;

pub fn replay_session(directory: &Path, config: SwingConfig) -> io::Result<Value> {
    config.validate().map_err(io::Error::other)?;
    let commands = parse_config(&std::fs::read_to_string(directory.join("radar.cfg"))?);
    let sensor = SensorModel::from_commands(&commands).map_err(io::Error::other)?;
    let mut detector = ShotDetector::new(sensor, config);
    let configuration = detector.configuration();
    let mut paths = std::fs::read_dir(directory)?
        .map(|entry| entry.map(|e| e.path()))
        .collect::<io::Result<Vec<_>>>()?;
    paths.retain(|path| {
        path.file_name()
            .and_then(|p| p.to_str())
            .is_some_and(|p| p.starts_with("events-") && p.ends_with(".jsonl"))
    });
    paths.sort();
    if paths.is_empty() {
        return Err(io::Error::other("Session has no event files"));
    }
    let mut originals = Vec::new();
    let mut attempts = Vec::new();
    let mut last_number = None;
    let mut last_arm: Option<String> = None;
    let mut frames = 0;
    let mut armed_frames = 0;
    for path in paths {
        for (line_number, line) in BufReader::new(File::open(&path)?).lines().enumerate() {
            let event: Value = serde_json::from_str(&line?).map_err(|error| {
                io::Error::other(format!("{}:{}: {error}", path.display(), line_number + 1))
            })?;
            if event["type"] == "shot_capture_ended" {
                let capture = &event["data"]["capture"];
                if capture["state"] == "complete" {
                    match detector.finish() {
                        Some(DetectionEvent::BallDetected(shot))=>attempts.push(json!({"end_frame":last_number,"shot":shot,"report":detector.take_report()})),
                        Some(DetectionEvent::NoBallDetected)=>attempts.push(json!({"end_frame":last_number,"report":detector.take_report()})),
                        _=>{}
                    }
                } else if let Some(report) = detector.abort_report(
                    capture["end_reason"]
                        .as_str()
                        .unwrap_or("capture_interrupted"),
                ) {
                    attempts.push(json!({"end_frame":last_number,"report":report}));
                }
                detector.reset();
                last_arm = None;
            }
            // Preserve revocations that occur between radar frames as well as
            // the arm token visible on the next frame (which may be reused).
            if matches!(
                event["type"].as_str(),
                Some(
                    "game_connected"
                        | "game_disconnected"
                        | "arm_changed"
                        | "frame_timeout"
                        | "frame_number_reset"
                        | "service_stopped"
                )
            ) {
                let reason = format!("recorded_{}", event["type"].as_str().unwrap());
                if let Some(report) = detector.abort_report(&reason) {
                    attempts.push(json!({"end_frame":last_number,"report":report}));
                }
                detector.reset();
                last_arm = None;
            }
            if event["type"] == "swing_started" {
                originals.push(json!({"swing_id":event["swing_id"],"start_frame":event["data"]["frame_number"]}));
            }
            if event["type"] != "frame" {
                continue;
            }
            frames += 1;
            let data = &event["data"];
            let diagnostics = &data["diagnostics"];
            let number = diagnostics["frame_number"]
                .as_u64()
                .ok_or_else(|| io::Error::other("Missing recorded frame number"))?
                as u32;
            let arm = data["arm_id"].as_str().map(str::to_owned);
            if arm != last_arm || last_number.is_some_and(|last| number <= last) {
                if let Some(report) = detector.abort_report("recorded_arm_or_frame_reset") {
                    attempts.push(json!({"end_frame":last_number,"report":report}));
                }
                detector.reset();
            }
            last_arm = arm;
            last_number = Some(number);
            if last_arm.is_none() {
                continue;
            }
            armed_frames += 1;
            let mut points = Vec::new();
            for point in diagnostics["points"]
                .as_array()
                .ok_or_else(|| io::Error::other("Missing recorded points"))?
            {
                let numeric = |key: &str| point[key].as_f64().unwrap_or(f64::NAN) as f32;
                points.push(RadarPoint {
                    x: numeric("x"),
                    y: numeric("y"),
                    z: numeric("z"),
                    radial_velocity: numeric("radial_velocity"),
                    side_info: point["snr_db"].as_f64().map(|snr| PointSideInfo {
                        snr_db: snr as f32,
                        noise_db: numeric("noise_db"),
                    }),
                });
            }
            if let Some(event) = detector.update(&RadarFrame {
                frame_number: number,
                points,
            }) {
                match event {
                    DetectionEvent::SwingDetected => {}
                    DetectionEvent::BallDetected(shot) => attempts.push(
                        json!({"end_frame":number,"shot":shot,"report":detector.take_report()}),
                    ),
                    DetectionEvent::NoBallDetected => {
                        attempts.push(json!({"end_frame":number,"report":detector.take_report()}))
                    }
                }
            }
        }
    }
    if let Some(report) = detector.abort_report("recording_ended") {
        attempts.push(json!({"end_frame":last_number,"report":report}));
    }
    for attempt in &mut attempts {
        let start = attempt["report"]["start_frame"].as_u64().unwrap_or(0);
        let end = attempt["end_frame"].as_u64().unwrap_or(start);
        attempt["overlapping_recorded_swing_ids"] = json!(
            originals
                .iter()
                .filter(|original| original["start_frame"]
                    .as_u64()
                    .is_some_and(|frame| frame >= start && frame <= end))
                .map(|original| original["swing_id"].clone())
                .collect::<Vec<_>>()
        );
    }
    let confirmed = attempts.iter().filter(|a| a["shot"].is_object()).count();
    let no_ball = attempts
        .iter()
        .filter(|a| a["report"]["outcome"] == "no_ball_detected")
        .count();
    Ok(json!({"session":directory,"configuration":configuration,
        "statistics":{"frames":frames,"armed_frames":armed_frames,"recorded_swing_triggers":originals.len(),
            "replayed_attempts":attempts.len(),"confirmed_balls":confirmed,"unconfirmed_attempts":no_ball},
        "original_triggers":originals,"attempts":attempts,
        "label_note":"Original swing triggers are not ground-truth ball labels. Replay preserves original observations and arming; it does not simulate game disarming after a newly accepted shot."}))
}
