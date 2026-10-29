//! Sensor-normalized flight hypotheses plus independent, diverging club evidence.
use super::estimation::ShotOutput;
use super::flight::{
    FlightFit, GRAVITY_MPS2, Sample, basis, dot, fit_flight, norm, sigmas, spatial_error, sub, unit,
};
use super::sensor::SensorModel;
use crate::radar::frame::{RadarFrame, RadarPoint};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, VecDeque};

/// Statistical settings and sensor-array calibration, never a tee/ball distance gate.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct SwingConfig {
    pub motion_sigma: f64,
    pub association_sigma: f64,
    pub fit_sigma: f64,
    pub fit_iterations: usize,
    pub separation_sigma: f64,
    pub measurement_uncertainty_scale: f64,
    /// Sine-space angular resolution of the array, not a shot direction limit.
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
            // IWR6843ISK: eight virtual azimuth and four elevation elements.
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
        if positive.iter().any(|v| !v.is_finite() || *v <= 0.0)
            || self
                .forward_axis
                .iter()
                .chain(&self.up_axis)
                .any(|v| !v.is_finite())
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

#[derive(Debug, Clone)]
struct Hypothesis {
    id: u64,
    samples: Vec<Sample>,
    fit: Option<FlightFit>,
}

impl Hypothesis {
    fn quality(&self) -> f64 {
        self.samples.len() as f64 / (1.0 + self.fit.as_ref().map_or(0.0, |f| f.reduced_chi_squared))
    }
    fn last(&self) -> &Sample {
        self.samples.last().unwrap()
    }
}

#[derive(Debug, Serialize)]
struct ClubEvidence {
    launch_frame: Option<u32>,
    simultaneous_frames: usize,
    parent_samples: Vec<Sample>,
    relative_velocity_gain_mps: f64,
    required_velocity_gain_mps: f64,
    separation_distance_gain_m: f64,
    required_distance_gain_m: f64,
}

pub struct ShotDetector {
    sensor: SensorModel,
    config: SwingConfig,
    active: Vec<Hypothesis>,
    completed: Vec<Hypothesis>,
    context: VecDeque<Vec<Sample>>,
    background: VecDeque<f64>,
    swing_start: Option<u32>,
    last_motion: Option<u32>,
    rearming: bool,
    quiet_count: u32,
    next_sample: u64,
    next_track: u64,
    pub total_candidates: usize,
    last_report: Option<Value>,
    swing_frames: usize,
    swing_points: usize,
    swing_candidates: usize,
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
            active: Vec::new(),
            completed: Vec::new(),
            context: VecDeque::new(),
            background: VecDeque::new(),
            swing_start: None,
            last_motion: None,
            rearming: false,
            quiet_count: 0,
            next_sample: 0,
            next_track: 0,
            total_candidates: 0,
            last_report: None,
            swing_frames: 0,
            swing_points: 0,
            swing_candidates: 0,
            point_rejections: BTreeMap::new(),
        }
    }

    pub fn reset(&mut self) {
        self.active.clear();
        self.completed.clear();
        self.context.clear();
        self.swing_start = None;
        self.last_motion = None;
        self.rearming = false;
        self.quiet_count = 0;
        self.last_report = None;
        // Background calibration and monotonically increasing IDs survive turn changes.
        self.clear_counts();
    }

    fn clear_counts(&mut self) {
        self.swing_frames = 0;
        self.swing_points = 0;
        self.swing_candidates = 0;
        self.point_rejections.clear();
    }

    pub fn total_tracks_created(&self) -> u64 {
        self.next_track
    }
    pub fn configuration(&self) -> Value {
        json!({"algorithm":"sensor_normalized_ballistic_split_v1","sensor":self.sensor,
            "tracking":{"frame_period_s":self.sensor.frame_period_s},"swing":self.config,
            "range_sigma_m":self.sensor.range_sigma(),"doppler_sigma_mps":self.sensor.doppler_sigma(),
            "motion_threshold_mps":self.motion_threshold()})
    }

    fn motion_threshold(&self) -> f64 {
        let center = median(self.background.iter().copied());
        let mad = median(self.background.iter().map(|v| (v - center).abs()));
        // Normal-consistent MAD; the waveform quantization sets the uncertainty floor.
        center
            + self.config.motion_sigma
                * (mad / 0.6744897501960817).max(self.sensor.doppler_sigma())
                * self.config.measurement_uncertainty_scale
    }

    pub fn ball_rejection_reason(&self, point: &RadarPoint) -> Option<&'static str> {
        let position = [point.x as f64, point.y as f64, point.z as f64];
        if position.iter().any(|v| !v.is_finite()) || !point.radial_velocity.is_finite() {
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
            "phase":if self.rearming { "waiting_for_quiet" } else if self.swing_start.is_some() { "evaluating_separate_flight" } else { "waiting_for_swing" },
            "points":frame.points.iter().map(|p| json!({"x":p.x,"y":p.y,"z":p.z,"radial_velocity":p.radial_velocity,
                "range_m":p.x.hypot(p.y).hypot(p.z),"snr_db":p.side_info.as_ref().map(|v|v.snr_db),
                "noise_db":p.side_info.as_ref().map(|v|v.noise_db),"ball_rejection":self.ball_rejection_reason(p)})).collect::<Vec<_>>()})
    }

    pub fn take_report(&mut self) -> Option<Value> {
        self.last_report.take()
    }
    pub fn abort_report(&self, reason: &str) -> Option<Value> {
        self.swing_start
            .map(|start| self.report(start, "aborted", Some(reason)))
    }

    fn club_evidence(&self, track: &Hypothesis, fit: &FlightFit) -> ClubEvidence {
        let threshold = self.motion_threshold();
        let velocity_sigma =
            self.sensor.doppler_sigma() * self.config.measurement_uncertainty_scale;
        let required_gap = self.config.separation_sigma * 2.0_f64.sqrt() * velocity_sigma;
        let first = &track.samples[0];
        let mut launch_frame = None;
        for sample in self
            .context
            .iter()
            .flatten()
            .filter(|s| s.frame_number <= first.frame_number && s.id != first.id)
        {
            if sample.radial_velocity.abs() <= threshold {
                continue;
            }
            let (predicted, _) = fit.at(sample.frame_number, self.sensor.frame_period_s);
            if spatial_error(predicted, sample, &self.sensor, &self.config)
                <= self.config.association_sigma
            {
                launch_frame = Some(sample.frame_number);
            }
        }
        let mut parents = Vec::new();
        let mut gaps = Vec::new();
        let mut distances = Vec::new();
        for child in &track.samples {
            let (_, velocity) = fit.at(child.frame_number, self.sensor.frame_period_s);
            let radial = dot(unit(child.position), velocity);
            let parent = self
                .context
                .iter()
                .flatten()
                .filter(|parent| {
                    if parent.frame_number != child.frame_number
                        || parent.id == child.id
                        || parent.radial_velocity.abs() <= threshold
                        || radial - parent.radial_velocity <= required_gap
                    {
                        return false;
                    }
                    // A parent is a co-located angular cluster, not a fixed-width launch lane.
                    let angle_difference = norm(sub(unit(parent.position), unit(child.position)));
                    let angular_sigma = (self.config.azimuth_resolution_sine.powi(2)
                        + self.config.elevation_resolution_sine.powi(2))
                    .sqrt()
                        / 12.0_f64.sqrt();
                    angle_difference
                        <= self.config.association_sigma * 2.0_f64.sqrt() * angular_sigma
                        && parent.range()
                            <= child.range()
                                + self.config.association_sigma
                                    * 2.0_f64.sqrt()
                                    * self.sensor.range_sigma()
                })
                .min_by(|a, b| {
                    norm(sub(a.position, child.position))
                        .total_cmp(&norm(sub(b.position, child.position)))
                });
            if let Some(parent) = parent {
                let difference = sub(child.position, parent.position);
                let distance = norm(difference);
                if distance > f64::EPSILON {
                    let direction = unit(difference);
                    let variance = [child, parent]
                        .iter()
                        .map(|sample| {
                            basis(sample.position, unit(self.config.up_axis))
                                .iter()
                                .zip(sigmas(sample.range(), &self.sensor, &self.config))
                                .map(|(axis, sigma)| (dot(*axis, direction) * sigma).powi(2))
                                .sum::<f64>()
                        })
                        .sum::<f64>();
                    distances.push((distance, variance));
                }
                parents.push(parent.clone());
                gaps.push(radial - parent.radial_velocity);
            }
        }
        let gain = match (gaps.first(), gaps.last()) {
            (Some(a), Some(b)) => b - a,
            _ => 0.0,
        };
        let (distance_gain, distance_sigma) = match (distances.first(), distances.last()) {
            (Some(a), Some(b)) => (b.0 - a.0, (a.1 + b.1).sqrt()),
            _ => (0.0, f64::INFINITY),
        };
        ClubEvidence {
            launch_frame,
            simultaneous_frames: parents.len(),
            parent_samples: parents,
            relative_velocity_gain_mps: gain,
            required_velocity_gain_mps: self.config.separation_sigma * 2.0 * velocity_sigma,
            separation_distance_gain_m: distance_gain,
            required_distance_gain_m: self.config.separation_sigma * distance_sigma,
        }
    }

    fn assess(&self, track: &Hypothesis) -> (Option<&'static str>, Option<ClubEvidence>) {
        if track.samples.len() < self.config.min_track_observations {
            return (Some("insufficient_independent_observations"), None);
        }
        let Some(fit) = &track.fit else {
            return (Some("unobservable_flight_model"), None);
        };
        if fit.reduced_chi_squared > fit.chi_squared_limit {
            return (
                Some("flight_model_inconsistent_with_sensor_uncertainty"),
                None,
            );
        }
        let first = &track.samples[0];
        let last = track.last();
        let travel = last.range() - first.range();
        if travel
            <= self.config.separation_sigma
                * 2.0_f64.sqrt()
                * self.sensor.range_sigma()
                * self.config.measurement_uncertainty_scale
        {
            return (Some("outward_travel_not_statistically_resolved"), None);
        }
        let forward = unit(self.config.forward_axis);
        let forward_std = dot(forward.map(|v| v * v), fit.velocity_std_mps.map(|v| v * v)).sqrt();
        if dot(fit.velocity, forward) <= self.config.separation_sigma * forward_std {
            return (Some("forward_flight_not_statistically_resolved"), None);
        }
        let evidence = self.club_evidence(track, fit);
        let preceding = self.preceding_motion_frames(first.frame_number);
        let reason = if preceding < self.config.min_swing_observations {
            Some("insufficient_preceding_swing_evidence")
        } else if evidence.launch_frame.is_none() {
            Some("no_observed_launch_connection")
        } else if evidence.simultaneous_frames < self.config.min_separation_frames {
            Some("no_independent_club_and_ball_tracks")
        } else if evidence.relative_velocity_gain_mps <= evidence.required_velocity_gain_mps
            && evidence.separation_distance_gain_m <= evidence.required_distance_gain_m
        {
            Some("no_resolved_detachment_from_club")
        } else {
            None
        };
        (reason, Some(evidence))
    }

    fn preceding_motion_frames(&self, first: u32) -> usize {
        self.context
            .iter()
            .filter(|points| points.first().is_some_and(|p| p.frame_number < first))
            .filter(|points| {
                points
                    .iter()
                    .any(|p| p.radial_velocity.abs() > self.motion_threshold())
            })
            .count()
    }

    fn report(&self, start: u32, outcome: &str, reason: Option<&str>) -> Value {
        let mut tracks: Vec<_> = self.completed.iter().chain(&self.active).collect();
        tracks.sort_by(|a, b| b.quality().total_cmp(&a.quality()));
        let tracks: Vec<_> = tracks
            .into_iter()
            .take(self.config.max_hypotheses)
            .map(|track| {
                let (rejection, evidence) = self.assess(track);
                json!({"track_id":track.id,"observations":track.samples,"fit":track.fit,
                "quality":track.quality(),"rejection_reason":rejection,"club_evidence":evidence})
            })
            .collect();
        json!({"start_frame":start,"outcome":outcome,"abort_reason":reason,"algorithm":"sensor_normalized_ballistic_split_v1",
            "frames_evaluated":self.swing_frames,"points_evaluated":self.swing_points,"ball_candidates":self.swing_candidates,
            "point_rejections":self.point_rejections,"motion_threshold_mps":self.motion_threshold(),"tracks":tracks})
    }

    fn compatible(&self, track: &Hypothesis, next: &Sample) -> bool {
        let last = track.last();
        let gap = next.frame_number.saturating_sub(last.frame_number);
        if gap == 0 || gap - 1 > self.config.max_missed_frames {
            return false;
        }
        let dt = gap as f64 * self.sensor.frame_period_s;
        let sigma = self.config.measurement_uncertainty_scale;
        let range_error = (next.range()
            - last.range()
            - (next.radial_velocity + last.radial_velocity) * dt / 2.0)
            .abs();
        if range_error
            > self.config.association_sigma * 2.0_f64.sqrt() * self.sensor.range_sigma() * sigma
        {
            return false;
        }
        let speed = track
            .fit
            .as_ref()
            .map_or(last.radial_velocity.abs(), |fit| norm(fit.velocity));
        let max_change = (GRAVITY_MPS2 + self.config.drag_acceleration(speed)) * dt
            + self.config.association_sigma * 2.0_f64.sqrt() * self.sensor.doppler_sigma() * sigma;
        if (next.radial_velocity - last.radial_velocity).abs() > max_change {
            return false;
        }
        let predicted = if let Some(fit) = &track.fit {
            fit.at(next.frame_number, self.sensor.frame_period_s).0
        } else {
            std::array::from_fn(|i| {
                last.position[i] + unit(last.position)[i] * last.radial_velocity * dt
            })
        };
        spatial_error(predicted, next, &self.sensor, &self.config) <= self.config.association_sigma
    }

    fn track(&mut self, samples: &[Sample], frame: u32) {
        let previous = std::mem::take(&mut self.active);
        let mut proposals = Vec::new();
        for track in previous {
            for sample in samples {
                if self.compatible(&track, sample) {
                    let mut extended = track.clone();
                    extended.samples.push(sample.clone());
                    self.next_track += 1;
                    extended.id = self.next_track;
                    extended.fit = fit_flight(&extended.samples, &self.sensor, &self.config);
                    proposals.push(extended);
                }
            }
            if frame.saturating_sub(track.last().frame_number) <= self.config.max_missed_frames {
                // Keep a missed-return alternative even when a distractor can match.
                proposals.push(track);
            } else {
                self.completed.push(track);
            }
        }
        for sample in samples {
            self.next_track += 1;
            proposals.push(Hypothesis {
                id: self.next_track,
                samples: vec![sample.clone()],
                fit: None,
            });
        }
        proposals.sort_by(|a, b| b.quality().total_cmp(&a.quality()));
        let mut endpoints: BTreeMap<u64, Vec<Hypothesis>> = BTreeMap::new();
        for track in proposals {
            endpoints.entry(track.last().id).or_default().push(track);
        }
        let mut proposals = Vec::new();
        for group in endpoints.into_values() {
            // Preserve distinct launch hypotheses: a long club prefix must not
            // erase a newly detached, shorter ball path at the same endpoint.
            let best_model = group
                .iter()
                .enumerate()
                .filter(|(_, track)| track.fit.is_some())
                .min_by(|(_, a), (_, b)| {
                    a.fit
                        .as_ref()
                        .unwrap()
                        .reduced_chi_squared
                        .total_cmp(&b.fit.as_ref().unwrap().reduced_chi_squared)
                })
                .map(|(index, _)| index);
            let newest = group
                .iter()
                .enumerate()
                .max_by_key(|(_, track)| track.samples[0].frame_number)
                .map(|(i, _)| i);
            let launch_compatible = group
                .iter()
                .enumerate()
                .find(|(_, track)| {
                    self.preceding_motion_frames(track.samples[0].frame_number)
                        >= self.config.min_swing_observations
                        && track.fit.as_ref().is_some_and(|fit| {
                            self.club_evidence(track, fit).launch_frame.is_some()
                        })
                })
                .map(|(index, _)| index);
            let mut priorities = vec![0];
            priorities.extend(best_model);
            priorities.extend(launch_compatible);
            priorities.extend(newest);
            priorities.extend(0..group.len());
            let mut selected = Vec::new();
            for index in priorities {
                if !selected.contains(&index) {
                    selected.push(index);
                }
                if selected.len() >= self.config.hypotheses_per_endpoint {
                    break;
                }
            }
            for index in selected {
                proposals.push(group[index].clone());
            }
        }
        proposals.sort_by(|a, b| b.quality().total_cmp(&a.quality()));
        proposals.truncate(self.config.max_hypotheses);
        self.active = proposals;
        self.completed
            .sort_by(|a, b| b.quality().total_cmp(&a.quality()));
        self.completed.truncate(self.config.max_hypotheses);
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
                self.context.clear();
            }
            return None;
        }
        self.context.push_back(samples.clone());
        while self.context.front().is_some_and(|points| {
            points.first().is_some_and(|p| {
                frame.frame_number.saturating_sub(p.frame_number) > self.config.context_frames
            })
        }) || self.context.len() > self.config.context_frames as usize
        {
            self.context.pop_front();
        }
        let mut started = false;
        if self.swing_start.is_none() {
            if samples.is_empty() {
                return None;
            }
            self.swing_start = Some(frame.frame_number);
            self.clear_counts();
            started = true;
        }
        if !samples.is_empty() {
            self.last_motion = Some(frame.frame_number);
        }
        self.swing_frames += 1;
        self.swing_points += frame.points.len();
        self.swing_candidates += samples.len();
        self.total_candidates += samples.len();
        for (reason, count) in rejected {
            *self.point_rejections.entry(reason).or_default() += count;
        }
        self.track(&samples, frame.frame_number);
        if !started {
            let best_finished = self
                .completed
                .iter()
                .any(|track| self.assess(track).0.is_none());
            if best_finished
                || self.quiet_count >= self.config.quiet_frames
                || frame.frame_number.saturating_sub(self.swing_start.unwrap())
                    >= self.config.max_event_frames
            {
                return self.finish();
            }
        }
        started.then_some(DetectionEvent::SwingDetected)
    }

    pub fn finish(&mut self) -> Option<DetectionEvent> {
        let start = self.swing_start.take()?;
        let best = self
            .completed
            .iter()
            .chain(&self.active)
            .filter(|track| self.assess(track).0.is_none())
            .max_by(|a, b| a.quality().total_cmp(&b.quality()));
        let selected_fit = best.and_then(|track| track.fit.clone());
        let selected_evidence =
            best.and_then(|track| track.fit.as_ref().map(|fit| self.club_evidence(track, fit)));
        let selected_id = best.map(|track| track.id);
        let selected_observations = best.map(|track| &track.samples);
        let shot = best.map(|track| {
            let fit = track.fit.as_ref().unwrap();
            let forward = unit(self.config.forward_axis);
            let up = unit(self.config.up_axis);
            let right = unit(super::flight::cross(forward, up));
            let vertical = dot(fit.velocity, up);
            let longitudinal = dot(fit.velocity, forward);
            let lateral = dot(fit.velocity, right);
            ShotOutput {
                shot_id: format!("shot-{}", track.id),
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
        );
        report["selected_fit"] = json!(selected_fit);
        report["selected_club_evidence"] = json!(selected_evidence);
        report["selected_hypothesis_id"] = json!(selected_id);
        // Always retain the chosen path, even if higher-scoring rejected paths
        // exhaust the bounded diagnostic hypothesis list.
        report["selected_observations"] = json!(selected_observations);
        self.last_report = Some(report);
        self.active.clear();
        self.completed.clear();
        self.rearming = self.quiet_count < self.config.quiet_frames;
        if !self.rearming {
            self.context.clear();
        }
        Some(match shot {
            Some(shot) => DetectionEvent::BallDetected(shot),
            None => DetectionEvent::NoBallDetected,
        })
    }
}

#[cfg(test)]
#[path = "shot_tests.rs"]
mod tests;
