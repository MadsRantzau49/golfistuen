//! Shot payload shared with the game; no shot estimator is implemented.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct ShotOutput {
    pub shot_id: String,
    pub speed_mps: f32,
    pub direction_deg: f32,
    pub elevation_deg: f32,
    pub spin_rpm: f32,
}
