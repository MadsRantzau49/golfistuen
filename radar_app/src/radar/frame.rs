#[derive(Debug, PartialEq)]
pub struct PointSideInfo {
    pub snr_db: f32,
    pub noise_db: f32,
}

#[derive(Debug, PartialEq)]
pub struct RadarPoint {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub radial_velocity: f32,
    pub side_info: Option<PointSideInfo>,
}

#[derive(Debug)]
pub struct RadarFrame {
    pub frame_number: u32,
    pub points: Vec<RadarPoint>,
}
