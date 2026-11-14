//! Retained configuration type; no detection algorithm is implemented.

#[derive(Debug, Clone)]
pub struct DetectionConfig {
    pub min_distance_m: f32,
    pub max_distance_m: f32,
    pub min_radial_speed_mps: f32,
    pub min_snr_db: f32,
}
