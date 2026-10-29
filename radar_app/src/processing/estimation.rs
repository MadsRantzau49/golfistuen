use serde::Serialize;

use crate::processing::tracking::BallTrack;

#[derive(Debug, Clone, Serialize)]
pub struct ShotOutput {
    pub shot_id: String,
    pub speed_mps: f32,
    pub direction_deg: f32,
    pub elevation_deg: f32,
    pub spin_rpm: f32,
}

pub fn estimate_shot(track: &BallTrack) -> Option<ShotOutput> {
    if track.observations.len() < 3 {
        return None;
    }

    let first = track.observations.first()?;
    let last = track.observations.last()?;

    let dt = last.time_s - first.time_s;

    if dt <= 0.0 {
        return None;
    }

    let vx = (last.x - first.x) / dt as f32;
    let vy = (last.y - first.y) / dt as f32;
    let vz = (last.z - first.z) / dt as f32;

    let horizontal_speed = vx.hypot(vy);
    let speed = horizontal_speed.hypot(vz);

    if !speed.is_finite() || !(2.0..=80.0).contains(&speed) {
        return None;
    }

    if vy <= 0.0 {
        return None;
    }

    let displacement = (last.x - first.x)
        .hypot(last.y - first.y)
        .hypot(last.z - first.z);

    if displacement < 0.3 {
        return None;
    }

    let direction = vx.atan2(vy).to_degrees();
    let elevation = vz.atan2(horizontal_speed).to_degrees();

    Some(ShotOutput {
        shot_id: format!("shot-{:03}", track.id + 1),
        speed_mps: speed,
        direction_deg: direction,
        elevation_deg: elevation,
        spin_rpm: 0.0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::processing::tracking::TrackObservation;

    fn observation(frame_number: u32, x: f32, y: f32, z: f32) -> TrackObservation {
        TrackObservation {
            frame_number,
            time_s: frame_number as f64 * 0.020,
            x,
            y,
            z,
            radial_velocity: 10.0,
        }
    }

    #[test]
    fn estimates_straight_shot() {
        let track = BallTrack {
            id: 0,
            observations: vec![
                observation(1, 0.0, 1.0, 0.0),
                observation(2, 0.0, 1.2, 0.0),
                observation(3, 0.0, 1.4, 0.0),
            ],
        };

        let shot = estimate_shot(&track).unwrap();

        assert!((shot.speed_mps - 10.0).abs() < 0.001);
        assert!(shot.direction_deg.abs() < 0.001);
        assert!(shot.elevation_deg.abs() < 0.001);
    }

    #[test]
    fn rejects_short_tracks() {
        let track = BallTrack {
            id: 0,
            observations: vec![
                observation(1, 0.0, 1.0, 0.0),
                observation(2, 0.0, 1.2, 0.0),
            ],
        };

        assert!(estimate_shot(&track).is_none());
    }

    #[test]
    fn estimates_positive_elevation() {
        let track = BallTrack {
            id: 0,
            observations: vec![
                observation(1, 0.0, 1.0, 0.0),
                observation(2, 0.0, 1.2, 0.1),
                observation(3, 0.0, 1.4, 0.2),
            ],
        };

        let shot = estimate_shot(&track).unwrap();

        assert!((shot.speed_mps - 11.18034).abs() < 0.001);
        assert!((shot.elevation_deg - 26.56505).abs() < 0.001);
    }
}
