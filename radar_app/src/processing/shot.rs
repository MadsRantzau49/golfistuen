//! Collect a stroke, then search its outgoing paths backwards against club reach.
use super::backward::{self, BackwardAnalysis};
use super::estimation::ShotOutput;
use super::flight::{Sample, dot, norm, unit};
use super::sensor::SensorModel;
use crate::radar::frame::{RadarFrame, RadarPoint};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, VecDeque};
use std::time::Instant;

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct SwingConfig {
    pub motion_sigma: f64,
    pub association_sigma: f64,
    pub fit_sigma: f64,
    pub fit_iterations: usize,
    pub separation_sigma: f64,
    pub measurement_uncertainty_scale: f64,
    pub azimuth_resolution_sine: f64,
    pub elevation_resolution_sine: f64,
    pub forward_axis: [f64; 3],
    pub up_axis: [f64; 3],
    pub ball_diameter_m: f64,
    pub ball_mass_kg: f64,
    pub air_density_kg_m3: f64,
    pub drag_coefficient: f64,
    pub min_track_observations: usize,
    pub min_swing_observations: usize,
    pub min_separation_frames: usize,
    pub max_missed_frames: u32,
    pub quiet_frames: u32,
    pub max_event_frames: u32,
    pub context_frames: u32,
    pub background_samples: usize,
    pub hypotheses_per_endpoint: usize,
    pub max_hypotheses: usize,
    pub max_event_observations: usize,
    pub max_backward_fits: usize,
}

impl Default for SwingConfig {
    fn default() -> Self {
        Self {
            motion_sigma: 4.0,
            association_sigma: 4.0,
            fit_sigma: 3.0,
            fit_iterations: 5,
            separation_sigma: 3.0,
            measurement_uncertainty_scale: 1.0,
            azimuth_resolution_sine: 2.0 / 8.0,
            elevation_resolution_sine: 2.0 / 4.0,
            forward_axis: [0.0, 1.0, 0.0],
            up_axis: [0.0, 0.0, 1.0],
            ball_diameter_m: 0.04267,
            ball_mass_kg: 0.04593,
            air_density_kg_m3: 1.225,
            drag_coefficient: 0.25,
            min_track_observations: 3,
            min_swing_observations: 3,
            min_separation_frames: 3,
            max_missed_frames: 4,
            quiet_frames: 5,
            max_event_frames: 150,
            context_frames: 50,
            background_samples: 256,
            hypotheses_per_endpoint: 4,
            max_hypotheses: 256,
            max_event_observations: 4096,
            max_backward_fits: 8192,
        }
    }
}

impl SwingConfig {
    pub fn validate(&self) -> Result<(), &'static str> {
        let positive = [
            self.motion_sigma,
            self.association_sigma,
            self.fit_sigma,
            self.separation_sigma,
            self.measurement_uncertainty_scale,
            self.azimuth_resolution_sine,
            self.elevation_resolution_sine,
            self.ball_diameter_m,
            self.ball_mass_kg,
            self.air_density_kg_m3,
            self.drag_coefficient,
        ];
        if positive
            .iter()
            .any(|value| !value.is_finite() || *value <= 0.0)
            || self
                .forward_axis
                .iter()
                .chain(&self.up_axis)
                .any(|value| !value.is_finite())
            || norm(self.forward_axis) <= f64::EPSILON
            || norm(self.up_axis) <= f64::EPSILON
            || norm(super::flight::cross(self.forward_axis, self.up_axis)) <= f64::EPSILON
            || self.fit_iterations == 0
            || self.min_track_observations < 3
            || self.min_swing_observations < 2
            || self.min_separation_frames < 2
            || self.quiet_frames == 0
            || self.context_frames == 0
            || self.background_samples == 0
            || self.hypotheses_per_endpoint == 0
            || self.max_hypotheses < self.hypotheses_per_endpoint
            || self.max_event_frames < self.min_track_observations as u32
            || self.max_event_observations < self.min_track_observations
            || self.max_backward_fits == 0
        {
            return Err(
                "Invalid statistical, sensor-array, ball-model or resource settings in detector JSON",
            );
        }
        Ok(())
    }
    pub fn drag_acceleration(&self, speed: f64) -> f64 {
        let area = std::f64::consts::PI * self.ball_diameter_m.powi(2) / 4.0;
        self.air_density_kg_m3 * self.drag_coefficient * area * speed.powi(2)
            / (2.0 * self.ball_mass_kg)
    }
}

#[derive(Debug)]
pub enum DetectionEvent {
    SwingDetected,
    BallDetected(ShotOutput),
    NoBallDetected,
}

pub struct ShotDetector {
    sensor: SensorModel,
    config: SwingConfig,
    observations: Vec<Sample>,
    background: VecDeque<f64>,
    swing_start: Option<u32>,
    rearming: bool,
    quiet_count: u32,
    next_sample: u64,
    next_track: u64,
    pub total_candidates: usize,
    last_report: Option<Value>,
    swing_frames: usize,
    swing_points: usize,
    swing_candidates: usize,
    dropped_observations: usize,
    point_rejections: BTreeMap<&'static str, usize>,
}

fn median(values: impl Iterator<Item = f64>) -> f64 {
    let mut values: Vec<_> = values.collect();
    if values.is_empty() {
        return 0.0;
    }
    values.sort_by(f64::total_cmp);
    let middle = values.len() / 2;
    if values.len() % 2 == 0 {
        (values[middle - 1] + values[middle]) / 2.0
    } else {
        values[middle]
    }
}

impl ShotDetector {
    pub fn new(sensor: SensorModel, config: SwingConfig) -> Self {
        Self {
            sensor,
            config,
            observations: Vec::new(),
            background: VecDeque::new(),
            swing_start: None,
            rearming: false,
            quiet_count: 0,
            next_sample: 0,
            next_track: 0,
            total_candidates: 0,
            last_report: None,
            swing_frames: 0,
            swing_points: 0,
            swing_candidates: 0,
            dropped_observations: 0,
            point_rejections: BTreeMap::new(),
        }
    }
    pub fn reset(&mut self) {
        self.observations.clear();
        self.swing_start = None;
        self.rearming = false;
        self.quiet_count = 0;
        self.last_report = None;
        self.clear_counts();
    }
    fn clear_counts(&mut self) {
        self.swing_frames = 0;
        self.swing_points = 0;
        self.swing_candidates = 0;
        self.dropped_observations = 0;
        self.point_rejections.clear();
    }
    pub fn total_tracks_created(&self) -> u64 {
        self.next_track
    }
    pub fn configuration(&self) -> Value {
        json!({"algorithm":"backward_outgoing_club_reach_v2","selection":"furthest_valid_outgoing_path","sensor":self.sensor,
            "tracking":{"frame_period_s":self.sensor.frame_period_s},"swing":self.config,
            "range_sigma_m":self.sensor.range_sigma(),"doppler_sigma_mps":self.sensor.doppler_sigma(),"motion_threshold_mps":self.motion_threshold()})
    }
    fn motion_threshold(&self) -> f64 {
        let center = median(self.background.iter().copied());
        let mad = median(self.background.iter().map(|value| (value - center).abs()));
        center
            + self.config.motion_sigma
                * (mad / 0.6744897501960817).max(self.sensor.doppler_sigma())
                * self.config.measurement_uncertainty_scale
    }
    pub fn ball_rejection_reason(&self, point: &RadarPoint) -> Option<&'static str> {
        let position = [point.x as f64, point.y as f64, point.z as f64];
        if position.iter().any(|value| !value.is_finite()) || !point.radial_velocity.is_finite() {
            return Some("non_finite_point");
        }
        let range = norm(position);
        if range <= 0.0 || range < self.sensor.min_range_m || range > self.sensor.max_range_m {
            return Some("outside_sensor_range_fov");
        }
        if (point.radial_velocity as f64).abs() <= self.motion_threshold() {
            return Some("indistinguishable_from_background_motion");
        }
        None
    }
    pub fn frame_diagnostics(&self, frame: &RadarFrame) -> Value {
        json!({"frame_number":frame.frame_number,"radar_time_s":frame.frame_number as f64*self.sensor.frame_period_s,
            "swing_start_frame":self.swing_start,"motion_threshold_mps":self.motion_threshold(),
            "phase":if self.rearming {"waiting_for_quiet"} else if self.swing_start.is_some() {"collecting_stroke_for_backward_search"} else {"waiting_for_swing"},
            "points":frame.points.iter().map(|point|json!({"x":point.x,"y":point.y,"z":point.z,"radial_velocity":point.radial_velocity,
                "range_m":point.x.hypot(point.y).hypot(point.z),"snr_db":point.side_info.as_ref().map(|s|s.snr_db),
                "noise_db":point.side_info.as_ref().map(|s|s.noise_db),"ball_rejection":self.ball_rejection_reason(point)})).collect::<Vec<_>>()})
    }
    pub fn take_report(&mut self) -> Option<Value> {
        self.last_report.take()
    }
    fn analyze(&self, next_track: &mut u64) -> BackwardAnalysis {
        if self.dropped_observations > 0 {
            return BackwardAnalysis {
                candidates: Vec::new(),
                club_strokes: Vec::new(),
                selected_index: None,
                fit_evaluations: 0,
                search_budget_exhausted: true,
            };
        }
        backward::analyze(&self.observations, &self.sensor, &self.config, next_track)
    }
    fn report(
        &self,
        start: u32,
        outcome: &str,
        reason: Option<&str>,
        analysis: &BackwardAnalysis,
    ) -> Value {
        json!({"start_frame":start,"outcome":outcome,"abort_reason":reason,"algorithm":"backward_outgoing_club_reach_v2",
            "selection":"furthest_valid_outgoing_path","frames_evaluated":self.swing_frames,"points_evaluated":self.swing_points,
            "ball_candidates":self.swing_candidates,"point_rejections":self.point_rejections,"motion_threshold_mps":self.motion_threshold(),
            "tracks":analysis.candidates,"club_strokes":analysis.club_strokes,"backward_fit_evaluations":analysis.fit_evaluations,
            "search_budget_exhausted":analysis.search_budget_exhausted,"discarded_observations":self.dropped_observations})
    }
    pub fn abort_report(&self, reason: &str) -> Option<Value> {
        let start = self.swing_start?;
        let analysis = self.analyze(&mut self.next_track.clone());
        Some(self.report(start, "aborted", Some(reason), &analysis))
    }
    pub fn update(&mut self, frame: &RadarFrame) -> Option<DetectionEvent> {
        let threshold = self.motion_threshold();
        let mut samples = Vec::new();
        let mut rejected = BTreeMap::new();
        for point in &frame.points {
            if let Some(reason) = self.ball_rejection_reason(point) {
                *rejected.entry(reason).or_insert(0) += 1;
                if self.swing_start.is_none()
                    && point.radial_velocity.is_finite()
                    && (point.radial_velocity as f64).abs() <= threshold
                {
                    self.background
                        .push_back((point.radial_velocity as f64).abs());
                    while self.background.len() > self.config.background_samples {
                        self.background.pop_front();
                    }
                }
            } else {
                self.next_sample += 1;
                samples.push(Sample::new(self.next_sample, frame.frame_number, point));
            }
        }
        if samples.is_empty() {
            self.quiet_count = self.quiet_count.saturating_add(1);
        } else {
            self.quiet_count = 0;
        }
        if self.rearming {
            if self.quiet_count >= self.config.quiet_frames {
                self.rearming = false;
                self.observations.clear();
            }
            return None;
        }
        let mut started = false;
        if self.swing_start.is_none() {
            if samples.is_empty() {
                return None;
            }
            self.swing_start = Some(frame.frame_number);
            self.clear_counts();
            self.observations.clear();
            started = true;
        }
        self.swing_frames += 1;
        self.swing_points += frame.points.len();
        self.swing_candidates += samples.len();
        self.total_candidates += samples.len();
        for (reason, count) in rejected {
            *self.point_rejections.entry(reason).or_default() += count;
        }
        let available = self
            .config
            .max_event_observations
            .saturating_sub(self.observations.len());
        self.dropped_observations += samples.len().saturating_sub(available);
        self.observations
            .extend(samples.into_iter().take(available));
        // Wait for stroke context, not the first short clean club fragment.
        if !started
            && (self.quiet_count >= self.config.quiet_frames
                || self.dropped_observations > 0
                || frame.frame_number.saturating_sub(self.swing_start.unwrap())
                    >= self.config.max_event_frames)
        {
            return self.finish();
        }
        // Unrelated moving people must not hold an otherwise finished stroke
        // open. Both the chosen flight and its observed club envelope must have
        // stopped extending for the configured association-gap horizon.
        if !started
            && self.swing_frames % self.config.quiet_frames as usize == 0
            && self.observations.len()
                >= self.config.min_track_observations + self.config.min_swing_observations
        {
            let begin = Instant::now();
            let mut next = self.next_track;
            let analysis = self.analyze(&mut next);
            let closed = analysis.selected_index.is_some_and(|index| {
                let candidate = &analysis.candidates[index];
                let last_ball = candidate.observations.last().unwrap().frame_number;
                let last_club = candidate
                    .club_evidence
                    .as_ref()
                    .and_then(|proof| {
                        proof
                            .club_envelope_samples
                            .iter()
                            .map(|sample| sample.frame_number)
                            .max()
                    })
                    .unwrap_or(frame.frame_number);
                frame.frame_number.saturating_sub(last_ball) > self.config.max_missed_frames
                    && frame.frame_number.saturating_sub(last_club) > self.config.max_missed_frames
            });
            if closed {
                return self.complete(analysis, next, begin.elapsed().as_secs_f64() * 1000.0);
            }
        }
        started.then_some(DetectionEvent::SwingDetected)
    }
    pub fn finish(&mut self) -> Option<DetectionEvent> {
        self.swing_start?;
        let begin = Instant::now();
        let mut next = self.next_track;
        let analysis = self.analyze(&mut next);
        self.complete(analysis, next, begin.elapsed().as_secs_f64() * 1000.0)
    }
    fn complete(
        &mut self,
        analysis: BackwardAnalysis,
        next: u64,
        elapsed_ms: f64,
    ) -> Option<DetectionEvent> {
        let start = self.swing_start.take()?;
        self.next_track = next;
        let best = analysis
            .selected_index
            .map(|index| &analysis.candidates[index]);
        let shot = best.map(|candidate| {
            let fit = candidate.fit.as_ref().unwrap();
            let forward = unit(self.config.forward_axis);
            let up = unit(self.config.up_axis);
            let right = unit(super::flight::cross(forward, up));
            let vertical = dot(fit.velocity, up);
            let longitudinal = dot(fit.velocity, forward);
            let lateral = dot(fit.velocity, right);
            ShotOutput {
                shot_id: format!("shot-{}", candidate.track_id),
                speed_mps: norm(fit.velocity) as f32,
                direction_deg: lateral.atan2(longitudinal).to_degrees() as f32,
                elevation_deg: vertical.atan2(longitudinal.hypot(lateral)).to_degrees() as f32,
                spin_rpm: 0.0,
            }
        });
        let mut report = self.report(
            start,
            if shot.is_some() {
                "ball_detected"
            } else {
                "no_ball_detected"
            },
            None,
            &analysis,
        );
        report["selected_fit"] = json!(best.and_then(|candidate| candidate.fit.as_ref()));
        report["selected_club_evidence"] =
            json!(best.and_then(|candidate| candidate.club_evidence.as_ref()));
        report["selected_hypothesis_id"] = json!(best.map(|candidate| candidate.track_id));
        report["selected_observations"] = json!(best.map(|candidate| &candidate.observations));
        report["selected_furthest_range_m"] =
            json!(best.map(|candidate| candidate.furthest_range_m));
        report["analysis_elapsed_ms"] = json!(elapsed_ms);
        self.last_report = Some(report);
        self.observations.clear();
        self.rearming = self.quiet_count < self.config.quiet_frames;
        Some(match shot {
            Some(shot) => DetectionEvent::BallDetected(shot),
            None => DetectionEvent::NoBallDetected,
        })
    }
}

#[cfg(test)]
#[path = "shot_tests.rs"]
mod tests;
