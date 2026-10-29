use crate::radar::frame::{RadarFrame, RadarPoint};

#[derive(Debug, Clone)]
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
    let mut candidates = Vec::new();

    for point in &frame.points {
	let distance = point.x.hypot(point.y).hypot(point.z);
        if distance < config.min_distance_m 
            || distance > config.max_distance_m {
                continue
        }

        if point.radial_velocity.abs() < config.min_radial_speed_mps {
            continue
        }

        if let Some(info) = &point.side_info {
            if info.snr_db < config.min_snr_db {
                continue 
            }
        }

        candidates.push(point);

    }
    candidates
}



