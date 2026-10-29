//! Retrospective outgoing-path search and an independently observed club envelope.
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

use super::flight::{
    FlightFit, GRAVITY_MPS2, Sample, basis, dot, fit_flight, norm, sigmas, sub, unit,
};
use super::sensor::SensorModel;
use super::shot::SwingConfig;

#[derive(Debug, Clone, Serialize)]
pub struct Candidate {
    pub track_id: u64,
    pub observations: Vec<Sample>,
    pub fit: Option<FlightFit>,
    pub quality: f64,
    pub furthest_range_m: f64,
    pub furthest_forward_m: f64,
    pub rejection_reason: Option<&'static str>,
    pub club_evidence: Option<ClubEvidence>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ClubStroke {
    pub observations: Vec<Sample>,
    pub peak_frame: u32,
    pub braking_significance: f64,
    pub max_range_m: f64,
    pub max_forward_m: f64,
    pub mean_edge_error: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ClubEvidence {
    pub validation_mode: Option<&'static str>,
    pub launch_frame: Option<u32>,
    pub observed_origin: Option<[f64; 3]>,
    pub simultaneous_frames: usize,
    pub independent_frames: usize,
    pub parent_samples: Vec<Sample>,
    pub club_envelope_samples: Vec<Sample>,
    pub club_braking_significance: f64,
    pub observed_club_reach_m: f64,
    pub candidate_extent_m: f64,
    pub beyond_club_reach_m: f64,
    pub beyond_club_reach_sigma: f64,
    pub concurrent_frontier_significance: f64,
    pub relative_velocity_gain_mps: f64,
    pub required_velocity_gain_mps: f64,
    pub separation_distance_gain_m: f64,
    pub required_distance_gain_m: f64,
}

#[derive(Debug, Serialize)]
pub struct BackwardAnalysis {
    pub candidates: Vec<Candidate>,
    pub club_strokes: Vec<ClubStroke>,
    pub selected_index: Option<usize>,
    pub fit_evaluations: usize,
    pub search_budget_exhausted: bool,
}

#[derive(Clone)]
struct Path {
    samples: Vec<Sample>,
    fit: Option<FlightFit>,
    cost: f64,
}

impl Path {
    fn quality(&self) -> f64 {
        self.samples.len() as f64
            / (1.0 + self.fit.as_ref().map_or(0.0, |fit| fit.reduced_chi_squared))
    }
    fn last(&self) -> &Sample {
        self.samples.last().unwrap()
    }
}

fn forward_variance(sample: &Sample, sensor: &SensorModel, config: &SwingConfig) -> f64 {
    let forward = unit(config.forward_axis);
    basis(sample.position, unit(config.up_axis))
        .iter()
        .zip(sigmas(sample.range(), sensor, config))
        .map(|(axis, sigma)| (dot(*axis, forward) * sigma).powi(2))
        .sum()
}

/// Range integration is independent of noisy elevation/azimuth estimates.
fn edge(
    earlier: &Sample,
    later: &Sample,
    sensor: &SensorModel,
    config: &SwingConfig,
    flight: bool,
) -> Option<f64> {
    let gap = later.frame_number.checked_sub(earlier.frame_number)?;
    if gap == 0 || gap - 1 > config.max_missed_frames {
        return None;
    }
    let dt = gap as f64 * sensor.frame_period_s;
    let scale = config.measurement_uncertainty_scale;
    let error = later.range()
        - earlier.range()
        - (earlier.radial_velocity + later.radial_velocity) * dt / 2.0;
    let variance = 2.0 * (sensor.range_sigma() * scale).powi(2)
        + (sensor.doppler_sigma() * scale * dt).powi(2) / 2.0;
    let radial_error = error.abs() / variance.sqrt();
    if radial_error > config.association_sigma {
        return None;
    }
    if flight {
        let speed = earlier
            .radial_velocity
            .abs()
            .max(later.radial_velocity.abs());
        let allowed = (GRAVITY_MPS2 + config.drag_acceleration(speed)) * dt
            + config.association_sigma * 2.0_f64.sqrt() * sensor.doppler_sigma() * scale;
        if (later.radial_velocity - earlier.radial_velocity).abs() > allowed {
            return None;
        }
    }
    let radial = unit(earlier.position);
    let predicted = std::array::from_fn(|i| {
        earlier.position[i]
            + radial[i] * (earlier.radial_velocity + later.radial_velocity) * dt / 2.0
    });
    let axes = basis(later.position, unit(config.up_axis));
    let sigma = sigmas(later.range().max(earlier.range()), sensor, config);
    let difference = sub(later.position, predicted);
    let spatial = axes
        .iter()
        .zip(sigma)
        .map(|(axis, sigma)| (dot(*axis, difference) / (2.0_f64.sqrt() * sigma)).powi(2))
        .sum::<f64>();
    if spatial.sqrt() > config.association_sigma {
        return None;
    }
    Some(radial_error.powi(2) + spatial)
}

/// Intersect quantized range cells after integrating Doppler backwards. This
/// permits a real one-bin staircase but rejects stationary Doppler ghosts.
fn range_doppler_consistent(
    samples: &[Sample],
    sensor: &SensorModel,
    config: &SwingConfig,
) -> bool {
    let half_cell = sensor.range_resolution_m * config.measurement_uncertainty_scale / 2.0;
    let mut lower = f64::NEG_INFINITY;
    let mut upper = f64::INFINITY;
    let mut integrated = 0.0;
    let mut variance = 0.0;
    for (index, sample) in samples.iter().enumerate() {
        if index > 0 {
            let previous = &samples[index - 1];
            let dt = (sample.frame_number - previous.frame_number) as f64 * sensor.frame_period_s;
            integrated += (previous.radial_velocity + sample.radial_velocity) * dt / 2.0;
            variance +=
                (sensor.doppler_sigma() * config.measurement_uncertainty_scale * dt).powi(2) / 2.0;
        }
        let uncertainty = half_cell + config.association_sigma * variance.sqrt();
        lower = lower.max(sample.range() - integrated - uncertainty);
        upper = upper.min(sample.range() - integrated + uncertainty);
    }
    lower <= upper
}

fn make_candidate(path: Path, id: u64, forward: [f64; 3]) -> Candidate {
    let furthest_range = path.samples.iter().map(Sample::range).fold(0.0, f64::max);
    let furthest_forward = path
        .samples
        .iter()
        .map(|sample| dot(sample.position, forward))
        .fold(f64::NEG_INFINITY, f64::max);
    let quality = path.quality();
    Candidate {
        track_id: id,
        observations: path.samples,
        fit: path.fit,
        quality,
        furthest_range_m: furthest_range,
        furthest_forward_m: furthest_forward,
        rejection_reason: None,
        club_evidence: None,
    }
}

fn stroke(path: Path, sensor: &SensorModel, config: &SwingConfig) -> Option<ClubStroke> {
    if path.samples.len() < config.min_swing_observations {
        return None;
    }
    // A braking reference must be one physical trajectory too. In particular,
    // do not graft the club peak onto a bright slow Doppler stripe/body return.
    if !range_doppler_consistent(&path.samples, sensor, config) {
        return None;
    }
    let (peak_index, peak) = path.samples.iter().enumerate().max_by(|(_, a), (_, b)| {
        a.radial_velocity
            .total_cmp(&b.radial_velocity)
            .then(a.frame_number.cmp(&b.frame_number))
    })?;
    let end = path.last();
    if peak_index + 1 >= path.samples.len() {
        return None;
    }
    let duration = (end.frame_number - peak.frame_number) as f64 * sensor.frame_period_s;
    let gravity = unit(config.up_axis).map(|value| -GRAVITY_MPS2 * value);
    let angular_sigma =
        config.elevation_resolution_sine / 12.0_f64.sqrt() * config.measurement_uncertainty_scale;
    let projected_gravity = path.samples[peak_index..]
        .iter()
        .map(|s| dot(gravity, unit(s.position)).abs())
        .fold(0.0, f64::max);
    let free_ball_loss = (projected_gravity
        + config.separation_sigma * GRAVITY_MPS2 * angular_sigma
        + config.drag_acceleration(peak.radial_velocity.abs()))
        * duration;
    let sigma = 2.0_f64.sqrt() * sensor.doppler_sigma() * config.measurement_uncertainty_scale;
    let significance = (peak.radial_velocity - end.radial_velocity - free_ball_loss) / sigma;
    if significance <= config.separation_sigma {
        return None;
    }
    let largest_step = path.samples[peak_index..]
        .windows(2)
        .map(|pair| (pair[0].radial_velocity - pair[1].radial_velocity).max(0.0))
        .fold(0.0, f64::max);
    if (peak.radial_velocity - end.radial_velocity - largest_step) / sigma
        <= config.separation_sigma
    {
        // One discontinuity followed by a steady body/ghost return is not an
        // independently observed braking swing.
        return None;
    }
    let forward = unit(config.forward_axis);
    Some(ClubStroke {
        peak_frame: peak.frame_number,
        braking_significance: significance,
        max_range_m: path.samples.iter().map(Sample::range).fold(0.0, f64::max),
        max_forward_m: path
            .samples
            .iter()
            .map(|s| dot(s.position, forward))
            .fold(f64::NEG_INFINITY, f64::max),
        mean_edge_error: path.cost / (path.samples.len() - 1) as f64,
        observations: path.samples,
    })
}

fn club_strokes(samples: &[Sample], sensor: &SensorModel, config: &SwingConfig) -> Vec<ClubStroke> {
    let mut states: Vec<Vec<Path>> = vec![Vec::new(); samples.len()];
    let mut strokes = Vec::new();
    let tolerance = config.association_sigma
        * 2.0_f64.sqrt()
        * sensor.doppler_sigma()
        * config.measurement_uncertainty_scale;
    for (index, sample) in samples.iter().enumerate() {
        if sample.radial_velocity <= 0.0 {
            continue;
        }
        let mut options = vec![Path {
            samples: vec![sample.clone()],
            fit: None,
            cost: 0.0,
        }];
        for previous in (0..index).rev() {
            if sample
                .frame_number
                .saturating_sub(samples[previous].frame_number)
                > config.max_missed_frames + 1
            {
                break;
            }
            if samples[previous].radial_velocity + tolerance < sample.radial_velocity {
                continue;
            }
            let Some(cost) = edge(&samples[previous], sample, sensor, config, false) else {
                continue;
            };
            for prefix in &states[previous] {
                let mut path = prefix.clone();
                path.samples.push(sample.clone());
                path.cost += cost;
                options.push(path);
            }
        }
        options.sort_by(|a, b| {
            b.samples
                .len()
                .cmp(&a.samples.len())
                .then(a.cost.total_cmp(&b.cost))
        });
        options.truncate(config.hypotheses_per_endpoint);
        for path in &options {
            if let Some(club) = stroke(path.clone(), sensor, config) {
                strokes.push(club);
            }
        }
        states[index] = options;
    }
    strokes.sort_by(|a, b| {
        b.observations
            .len()
            .cmp(&a.observations.len())
            .then(a.mean_edge_error.total_cmp(&b.mean_edge_error))
    });
    strokes.truncate(config.max_hypotheses);
    strokes
}

fn launch_connection(
    candidate: &Candidate,
    club: &ClubStroke,
    sensor: &SensorModel,
    config: &SwingConfig,
) -> Option<Sample> {
    let first = &candidate.observations[0];
    let fit = candidate.fit.as_ref()?;
    let sigma = sensor.range_sigma() * config.measurement_uncertainty_scale;
    let mut eligible = Vec::new();
    for parent in &club.observations {
        if parent.frame_number > first.frame_number
            || candidate.observations.iter().any(|s| s.id == parent.id)
        {
            continue;
        }
        if first.frame_number - parent.frame_number > config.context_frames {
            continue;
        }
        let dt = (first.frame_number - parent.frame_number) as f64 * sensor.frame_period_s;
        let expected_range = first.range() - first.radial_velocity * dt;
        let range_uncertainty = (2.0 * sigma.powi(2)
            + (sensor.doppler_sigma() * config.measurement_uncertainty_scale * dt).powi(2))
        .sqrt()
            + config.drag_acceleration(norm(fit.velocity)) * dt * dt / 2.0;
        if (expected_range - parent.range()).abs() > config.association_sigma * range_uncertainty {
            continue;
        }
        let (predicted, _) = fit.at(parent.frame_number, sensor.frame_period_s);
        let axes = basis(parent.position, unit(config.up_axis));
        let measurement = sigmas(parent.range(), sensor, config);
        let delta = sub(parent.position, predicted);
        let error = axes
            .iter()
            .zip(measurement)
            .map(|(axis, sigma)| {
                let velocity_variance =
                    dot(axis.map(|v| v * v), fit.velocity_std_mps.map(|v| v * v));
                dot(*axis, delta).powi(2) / (2.0 * sigma.powi(2) + dt * dt * velocity_variance)
            })
            .sum::<f64>()
            .sqrt();
        if error <= config.association_sigma {
            eligible.push(parent.clone());
        }
    }
    // The locally observed club-speed peak provides a launch connection without
    // imposing an installation distance or a time since first motion.
    eligible
        .into_iter()
        .max_by(|a, b| a.radial_velocity.total_cmp(&b.radial_velocity))
}

fn parent_at(club: &ClubStroke, frame: u32, config: &SwingConfig) -> Option<(Sample, bool)> {
    if let Some(sample) = club
        .observations
        .iter()
        .find(|sample| sample.frame_number == frame)
    {
        return Some((sample.clone(), true));
    }
    for pair in club.observations.windows(2) {
        let before = &pair[0];
        let after = &pair[1];
        if before.frame_number < frame
            && frame < after.frame_number
            && after.frame_number - before.frame_number <= config.max_missed_frames + 1
        {
            let t = (frame - before.frame_number) as f64
                / (after.frame_number - before.frame_number) as f64;
            let mut sample = before.clone();
            sample.id = u64::MAX;
            sample.frame_number = frame;
            sample.position = std::array::from_fn(|i| {
                before.position[i] + t * (after.position[i] - before.position[i])
            });
            sample.radial_velocity =
                before.radial_velocity + t * (after.radial_velocity - before.radial_velocity);
            return Some((sample, false));
        }
    }
    None
}

fn evidence(
    candidate: &Candidate,
    club: &ClubStroke,
    sensor: &SensorModel,
    config: &SwingConfig,
) -> Option<ClubEvidence> {
    let launch = launch_connection(candidate, club, sensor, config)?;
    let fit = candidate.fit.as_ref()?;
    let forward = unit(config.forward_axis);
    let origin = launch.position;
    let candidate_extent = candidate
        .observations
        .iter()
        .map(|s| dot(sub(s.position, origin), forward))
        .fold(f64::NEG_INFINITY, f64::max);
    let club_extent = club
        .observations
        .iter()
        .map(|s| dot(sub(s.position, origin), forward))
        .fold(f64::NEG_INFINITY, f64::max);
    let end = candidate.observations.last().unwrap();
    let club_end = club
        .observations
        .iter()
        .max_by(|a, b| dot(a.position, forward).total_cmp(&dot(b.position, forward)))
        .unwrap();
    let reach_sigma =
        (forward_variance(end, sensor, config) + forward_variance(club_end, sensor, config)).sqrt();
    let reach_significance = (candidate_extent - club_extent) / reach_sigma;
    let mut actual_pairs = 0;
    let mut independent = 0;
    let mut weighted_gap = 0.0;
    let mut precision = 0.0;
    let mut gaps = Vec::new();
    let mut distances = Vec::new();
    for child in &candidate.observations {
        let Some((parent, observed)) = parent_at(club, child.frame_number, config) else {
            continue;
        };
        if candidate
            .observations
            .iter()
            .any(|sample| sample.id == parent.id)
        {
            continue;
        }
        let delta_velocity = child.radial_velocity - parent.radial_velocity;
        let velocity_sigma =
            2.0_f64.sqrt() * sensor.doppler_sigma() * config.measurement_uncertainty_scale;
        if delta_velocity <= config.separation_sigma * velocity_sigma {
            continue;
        }
        let gap = dot(sub(child.position, parent.position), forward);
        let variance =
            forward_variance(child, sensor, config) + forward_variance(&parent, sensor, config);
        weighted_gap += gap / variance;
        precision += 1.0 / variance;
        independent += 1;
        if observed {
            actual_pairs += 1;
        }
        gaps.push(delta_velocity);
        distances.push(norm(sub(child.position, parent.position)));
    }
    let frontier = if precision > 0.0 {
        weighted_gap / precision.sqrt()
    } else {
        0.0
    };
    let (_, launch_velocity) = fit.at(launch.frame_number, sensor.frame_period_s);
    let first_gap = dot(unit(launch.position), launch_velocity) - launch.radial_velocity;
    let last_gap = gaps.last().copied().unwrap_or(first_gap);
    let velocity_gain = last_gap - first_gap;
    let required_velocity = config.separation_sigma
        * 2.0
        * sensor.doppler_sigma()
        * config.measurement_uncertainty_scale;
    let distance_gain = distances
        .first()
        .zip(distances.last())
        .map_or(0.0, |(a, b)| b - a);
    let required_distance =
        config.separation_sigma * 2.0 * sensor.range_sigma() * config.measurement_uncertainty_scale;
    let mode = if reach_significance > config.separation_sigma {
        Some("beyond_observed_club_reach")
    } else if actual_pairs >= config.min_separation_frames
        && frontier > config.separation_sigma
        && (velocity_gain > required_velocity || distance_gain > required_distance)
        && reach_significance >= -config.separation_sigma
    {
        Some("concurrent_outgoing_split")
    } else {
        None
    };
    Some(ClubEvidence {
        validation_mode: mode,
        launch_frame: Some(launch.frame_number),
        observed_origin: Some(origin),
        simultaneous_frames: actual_pairs,
        independent_frames: independent,
        parent_samples: club.observations.clone(),
        club_envelope_samples: club.observations.clone(),
        club_braking_significance: club.braking_significance,
        observed_club_reach_m: club_extent,
        candidate_extent_m: candidate_extent,
        beyond_club_reach_m: candidate_extent - club_extent,
        beyond_club_reach_sigma: reach_significance,
        concurrent_frontier_significance: frontier,
        relative_velocity_gain_mps: velocity_gain,
        required_velocity_gain_mps: required_velocity,
        separation_distance_gain_m: distance_gain,
        required_distance_gain_m: required_distance,
    })
}

fn assess(
    candidate: &Candidate,
    strokes: &[ClubStroke],
    all: &[Sample],
    sensor: &SensorModel,
    config: &SwingConfig,
) -> (Option<&'static str>, Option<ClubEvidence>) {
    if candidate.observations.len() < config.min_track_observations {
        return (Some("insufficient_independent_observations"), None);
    }
    let Some(fit) = &candidate.fit else {
        return (Some("unobservable_flight_model"), None);
    };
    if fit.reduced_chi_squared > fit.chi_squared_limit {
        return (
            Some("flight_model_inconsistent_with_sensor_uncertainty"),
            None,
        );
    }
    if !range_doppler_consistent(&candidate.observations, sensor, config) {
        return (Some("range_cells_disagree_with_integrated_doppler"), None);
    }
    if candidate
        .observations
        .iter()
        .any(|s| s.radial_velocity <= 0.0)
    {
        return (Some("not_an_outgoing_path"), None);
    }
    let forward = unit(config.forward_axis);
    let forward_std = dot(forward.map(|v| v * v), fit.velocity_std_mps.map(|v| v * v)).sqrt();
    if dot(fit.velocity, forward) <= config.separation_sigma * forward_std {
        return (Some("forward_flight_not_statistically_resolved"), None);
    }
    let first = candidate.observations[0].frame_number;
    let preceding: BTreeSet<_> = all
        .iter()
        .filter(|s| s.frame_number < first)
        .map(|s| s.frame_number)
        .collect();
    if preceding.len() < config.min_swing_observations {
        return (Some("insufficient_preceding_swing_evidence"), None);
    }
    let Some(primary) = strokes
        .iter()
        .find(|club| launch_connection(candidate, club, sensor, config).is_some())
    else {
        return (
            Some("no_independent_braking_club_and_launch_connection"),
            None,
        );
    };
    // Alternative braking prefixes can share the same physical club. Union the
    // connected stroke family before estimating its envelope; otherwise an inner
    // or prematurely ended fragment would make reach look artificially short.
    let mut ids: BTreeSet<u64> = primary
        .observations
        .iter()
        .map(|sample| sample.id)
        .collect();
    let mut included = BTreeSet::new();
    loop {
        let before = ids.len();
        for (index, club) in strokes.iter().enumerate() {
            if included.contains(&index) {
                continue;
            }
            if club
                .observations
                .iter()
                .filter(|sample| ids.contains(&sample.id))
                .count()
                >= config.min_swing_observations
            {
                included.insert(index);
                ids.extend(club.observations.iter().map(|sample| sample.id));
            }
        }
        if ids.len() == before {
            break;
        }
    }
    let child_ids: BTreeSet<_> = candidate
        .observations
        .iter()
        .map(|sample| sample.id)
        .collect();
    let mut by_frame: BTreeMap<u32, Sample> = BTreeMap::new();
    for sample in primary.observations.iter().chain(
        included
            .iter()
            .flat_map(|&index| strokes[index].observations.iter()),
    ) {
        // Shared observations still belong in the possible club envelope. Removing
        // them would let the last part of a single club path validate itself.
        let replace = by_frame
            .get(&sample.frame_number)
            .is_none_or(|other| dot(sample.position, forward) > dot(other.position, forward));
        if replace {
            by_frame.insert(sample.frame_number, sample.clone());
        }
    }
    let envelope: Vec<_> = by_frame.into_values().collect();
    if primary
        .observations
        .iter()
        .filter(|sample| !child_ids.contains(&sample.id))
        .count()
        < config.min_swing_observations
    {
        return (
            Some("club_evidence_shares_the_candidate_observations"),
            None,
        );
    }
    let Some(mut proof) = evidence(candidate, primary, sensor, config) else {
        return (
            Some("no_independent_braking_club_and_launch_connection"),
            None,
        );
    };
    let origin = proof.observed_origin.unwrap();
    let reach = envelope
        .iter()
        .max_by(|a, b| dot(a.position, forward).total_cmp(&dot(b.position, forward)))
        .unwrap();
    proof.observed_club_reach_m = dot(sub(reach.position, origin), forward);
    proof.beyond_club_reach_m = proof.candidate_extent_m - proof.observed_club_reach_m;
    proof.beyond_club_reach_sigma = proof.beyond_club_reach_m
        / (forward_variance(candidate.observations.last().unwrap(), sensor, config)
            + forward_variance(reach, sensor, config))
        .sqrt();
    proof.club_envelope_samples = envelope;
    proof.validation_mode = if proof.beyond_club_reach_sigma > config.separation_sigma {
        Some("beyond_observed_club_reach")
    } else if proof.simultaneous_frames >= config.min_separation_frames
        && proof.concurrent_frontier_significance > config.separation_sigma
        && (proof.relative_velocity_gain_mps > proof.required_velocity_gain_mps
            || proof.separation_distance_gain_m > proof.required_distance_gain_m)
        && proof.beyond_club_reach_sigma >= -config.separation_sigma
    {
        Some("concurrent_outgoing_split")
    } else {
        None
    };
    let reason = if proof.validation_mode.is_none() {
        Some("no_resolved_outgoing_path_beyond_club")
    } else {
        None
    };
    (reason, Some(proof))
}

pub fn analyze(
    samples: &[Sample],
    sensor: &SensorModel,
    config: &SwingConfig,
    next_id: &mut u64,
) -> BackwardAnalysis {
    let mut samples = samples.to_vec();
    samples.sort_by_key(|sample| (sample.frame_number, sample.id));
    let strokes = club_strokes(&samples, sensor, config);
    let mut states: Vec<Vec<Path>> = vec![Vec::new(); samples.len()];
    let mut paths = Vec::new();
    let mut evaluations = 0;
    let mut limited = false;
    let forward = unit(config.forward_axis);
    for index in (0..samples.len()).rev() {
        let sample = &samples[index];
        let mut options = vec![Path {
            samples: vec![sample.clone()],
            fit: None,
            cost: 0.0,
        }];
        for later in index + 1..samples.len() {
            if samples[later]
                .frame_number
                .saturating_sub(sample.frame_number)
                > config.max_missed_frames + 1
            {
                break;
            }
            let Some(cost) = edge(sample, &samples[later], sensor, config, true) else {
                continue;
            };
            for suffix in &states[later] {
                if evaluations >= config.max_backward_fits {
                    limited = true;
                    break;
                }
                let mut observations = Vec::with_capacity(suffix.samples.len() + 1);
                observations.push(sample.clone());
                observations.extend(suffix.samples.iter().cloned());
                let fit = fit_flight(&observations, sensor, config);
                evaluations += 1;
                options.push(Path {
                    samples: observations,
                    fit,
                    cost: suffix.cost + cost,
                });
            }
        }
        options.sort_by(|a, b| {
            let valid = |path: &Path| {
                path.fit
                    .as_ref()
                    .is_none_or(|fit| fit.reduced_chi_squared <= fit.chi_squared_limit)
            };
            valid(b)
                .cmp(&valid(a))
                .then(dot(b.last().position, forward).total_cmp(&dot(a.last().position, forward)))
                .then(b.quality().total_cmp(&a.quality()))
        });
        let mut retained = options
            .iter()
            .take(config.hypotheses_per_endpoint)
            .cloned()
            .collect::<Vec<_>>();
        // New endpoints remain available when a farther suffix later fails a
        // global motion fit. This also preserves very short, quantized tails.
        if retained.iter().all(|path| path.samples.len() > 1) {
            if retained.len() >= config.hypotheses_per_endpoint && retained.len() > 1 {
                retained.pop();
            }
            retained.push(Path {
                samples: vec![sample.clone()],
                fit: None,
                cost: 0.0,
            });
        }
        for path in &retained {
            *next_id += 1;
            paths.push(make_candidate(path.clone(), *next_id, forward));
        }
        states[index] = retained;
    }
    paths.sort_by(|a, b| {
        b.furthest_range_m
            .total_cmp(&a.furthest_range_m)
            .then(b.quality.total_cmp(&a.quality))
    });
    // Keep model-valid shorter suffixes as well as long paths at each frontier.
    if limited {
        paths.truncate(config.max_hypotheses);
        for candidate in &mut paths {
            candidate.rejection_reason = Some("backward_search_budget_exceeded");
        }
        return BackwardAnalysis {
            candidates: paths,
            club_strokes: strokes,
            selected_index: None,
            fit_evaluations: evaluations,
            search_budget_exhausted: true,
        };
    }
    // Assess before truncating: rejected far/noisy paths must not evict a valid
    // shorter flight from the bounded diagnostic list.
    for candidate in &mut paths {
        let (reason, proof) = assess(candidate, &strokes, &samples, sensor, config);
        candidate.rejection_reason = reason;
        candidate.club_evidence = proof;
    }
    let selected_id = paths
        .iter()
        .filter(|candidate| candidate.rejection_reason.is_none() && !limited)
        .max_by(|a, b| {
            a.furthest_range_m
                .total_cmp(&b.furthest_range_m)
                .then(a.quality.total_cmp(&b.quality))
        })
        .map(|candidate| candidate.track_id);
    let chosen = selected_id.and_then(|id| {
        paths
            .iter()
            .find(|candidate| candidate.track_id == id)
            .cloned()
    });
    paths.truncate(config.max_hypotheses);
    if let Some(chosen) = chosen {
        if !paths
            .iter()
            .any(|candidate| candidate.track_id == chosen.track_id)
        {
            paths.pop();
            paths.push(chosen);
        }
    }
    let selected_index =
        selected_id.and_then(|id| paths.iter().position(|candidate| candidate.track_id == id));
    BackwardAnalysis {
        candidates: paths,
        club_strokes: strokes,
        selected_index,
        fit_evaluations: evaluations,
        search_budget_exhausted: limited,
    }
}
