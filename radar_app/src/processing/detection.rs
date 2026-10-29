use crate::radar::frame::{RadarFrame, RadarPoint};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct DetectionConfig {
    pub min_distance_m: f32,
    pub max_distance_m: f32,
    pub min_radial_speed_mps: f32,
    pub min_snr_db: f32,
}

pub fn detect_candidates<'a>(
    frame: &'a RadarFrame,
    config: &DetectionConfig,
) -> Vec<&'a RadarPoint> {
    frame
        .points
        .iter()
        .filter(|point| candidate_rejection_reason(point, config).is_none())
        .collect()
}

/// The same gate is used by detection and persistent diagnostics.
pub fn candidate_rejection_reason(
    point: &RadarPoint,
    config: &DetectionConfig,
) -> Option<&'static str> {
    if !point.x.is_finite()
        || !point.y.is_finite()
        || !point.z.is_finite()
        || !point.radial_velocity.is_finite()
    {
        return Some("non_finite_point");
    }
    let distance = point.x.hypot(point.y).hypot(point.z);
    if distance < config.min_distance_m {
        return Some("below_min_range");
    }
    if distance > config.max_distance_m {
        return Some("above_max_range");
    }
    if point.radial_velocity.abs() < config.min_radial_speed_mps {
        return Some("below_min_radial_speed");
    }
    if let Some(info) = &point.side_info {
        if !info.snr_db.is_finite() || info.snr_db < config.min_snr_db {
            return Some("low_or_invalid_snr");
        }
    }
    None
}
