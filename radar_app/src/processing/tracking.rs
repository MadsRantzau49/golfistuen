//! Reusable observation and track types; no tracking algorithm is implemented.

use crate::radar::frame::RadarPoint;

#[derive(Debug, Clone)]
pub struct TrackObservation {
    pub frame_number: u32,
    pub time_s: f64,
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub radial_velocity: f32,
}

impl TrackObservation {
    pub fn from_point(point: &RadarPoint, frame_number: u32, time_s: f64) -> Self {
        Self {
            frame_number,
            time_s,
            x: point.x,
            y: point.y,
            z: point.z,
            radial_velocity: point.radial_velocity,
        }
    }

    pub fn distance_to(&self, other: &Self) -> f32 {
        let dx = self.x - other.x;
        let dy = self.y - other.y;
        let dz = self.z - other.z;

        dx.hypot(dy).hypot(dz)
    }
}

#[derive(Debug)]
pub struct BallTrack {
    pub id: u64,
    pub observations: Vec<TrackObservation>,
}

#[derive(Debug, Clone)]
pub struct TrackingConfig {
    pub max_speed_mps: f32,
    pub position_tolerance_m: f32,
    pub max_missed_frames: u32,
    pub frame_period_s: f64,
}

impl Default for TrackingConfig {
    fn default() -> Self {
        Self {
            max_speed_mps: 50.0,
            position_tolerance_m: 0.15,
            max_missed_frames: 2,
            frame_period_s: 0.020,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calculates_distance_between_observations() {
        let first = TrackObservation {
            frame_number: 1,
            time_s: 0.020,
            x: 0.0,
            y: 1.0,
            z: 0.0,
            radial_velocity: 10.0,
        };

        let second = TrackObservation {
            frame_number: 2,
            time_s: 0.040,
            x: 0.0,
            y: 1.2,
            z: 0.0,
            radial_velocity: 10.0,
        };

        assert!((first.distance_to(&second) - 0.2).abs() < 0.0001);
    }

    #[test]
    fn creates_observation_from_radar_point() {
        let point = RadarPoint {
            x: 0.5,
            y: 2.0,
            z: 0.3,
            radial_velocity: 15.0,
            side_info: None,
        };

        let observation = TrackObservation::from_point(&point, 42, 0.84);

        assert_eq!(observation.frame_number, 42);
        assert_eq!(observation.time_s, 0.84);
        assert_eq!(observation.x, 0.5);
        assert_eq!(observation.y, 2.0);
        assert_eq!(observation.z, 0.3);
        assert_eq!(observation.radial_velocity, 15.0);
    }
}
