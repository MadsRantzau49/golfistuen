//! Weighted ballistic fitting with XYZ and Doppler measurement uncertainty.
use super::sensor::SensorModel;
use super::shot::SwingConfig;
use crate::radar::frame::RadarPoint;
use serde::Serialize;

pub const GRAVITY_MPS2: f64 = 9.80665;

pub fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a.iter().zip(b).map(|(a, b)| a * b).sum()
}
pub fn norm(a: [f64; 3]) -> f64 {
    dot(a, a).sqrt()
}
pub fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    std::array::from_fn(|i| a[i] - b[i])
}
pub fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
pub fn unit(a: [f64; 3]) -> [f64; 3] {
    let length = norm(a);
    a.map(|x| x / length)
}

#[derive(Debug, Clone, Serialize)]
pub struct Sample {
    pub id: u64,
    pub frame_number: u32,
    pub position: [f64; 3],
    pub radial_velocity: f64,
    pub snr_db: Option<f32>,
}

impl Sample {
    pub fn new(id: u64, frame: u32, point: &RadarPoint) -> Self {
        Self {
            id,
            frame_number: frame,
            position: [point.x as f64, point.y as f64, point.z as f64],
            radial_velocity: point.radial_velocity as f64,
            snr_db: point.side_info.as_ref().map(|s| s.snr_db),
        }
    }
    pub fn range(&self) -> f64 {
        norm(self.position)
    }
}

pub fn basis(position: [f64; 3], up: [f64; 3]) -> [[f64; 3]; 3] {
    let radial = unit(position);
    let horizontal = cross(up, radial);
    let horizontal = if norm(horizontal) > f64::EPSILON {
        unit(horizontal)
    } else {
        let least = (0..3)
            .min_by(|&a, &b| radial[a].abs().total_cmp(&radial[b].abs()))
            .unwrap();
        let axis = std::array::from_fn(|i| if i == least { 1.0 } else { 0.0 });
        unit(cross(axis, radial))
    };
    [radial, horizontal, unit(cross(radial, horizontal))]
}

pub fn sigmas(range: f64, sensor: &SensorModel, config: &SwingConfig) -> [f64; 3] {
    [
        sensor.range_sigma(),
        (range * config.azimuth_resolution_sine / 12.0_f64.sqrt()).max(sensor.range_sigma()),
        (range * config.elevation_resolution_sine / 12.0_f64.sqrt()).max(sensor.range_sigma()),
    ]
    .map(|value| value * config.measurement_uncertainty_scale)
}

pub fn spatial_error(
    predicted: [f64; 3],
    observed: &Sample,
    sensor: &SensorModel,
    config: &SwingConfig,
) -> f64 {
    let axes = basis(observed.position, unit(config.up_axis));
    let sigma = sigmas(observed.range(), sensor, config);
    let difference = sub(observed.position, predicted);
    axes.iter()
        .zip(sigma)
        .map(|(axis, sigma)| (dot(*axis, difference) / (2.0_f64.sqrt() * sigma)).powi(2))
        .sum::<f64>()
        .sqrt()
}

#[derive(Debug, Clone, Serialize)]
pub struct FlightFit {
    pub reference_frame: u32,
    pub position: [f64; 3],
    pub velocity: [f64; 3],
    pub acceleration: [f64; 3],
    pub velocity_std_mps: [f64; 3],
    pub reduced_chi_squared: f64,
    pub chi_squared_limit: f64,
    pub degrees_of_freedom: usize,
    pub max_position_residual_m: f64,
    pub max_doppler_residual_mps: f64,
}

impl FlightFit {
    pub fn at(&self, frame: u32, period: f64) -> ([f64; 3], [f64; 3]) {
        let t = (frame as f64 - self.reference_frame as f64) * period;
        (
            std::array::from_fn(|i| {
                self.position[i] + self.velocity[i] * t + self.acceleration[i] * t * t / 2.0
            }),
            std::array::from_fn(|i| self.velocity[i] + self.acceleration[i] * t),
        )
    }
}

fn solve(mut matrix: [[f64; 6]; 6], mut rhs: [f64; 6]) -> Option<[f64; 6]> {
    for column in 0..6 {
        let pivot = (column..6)
            .max_by(|&a, &b| matrix[a][column].abs().total_cmp(&matrix[b][column].abs()))?;
        if !matrix[pivot][column].is_finite() || matrix[pivot][column].abs() <= f64::EPSILON {
            return None;
        }
        matrix.swap(column, pivot);
        rhs.swap(column, pivot);
        let scale = matrix[column][column];
        for index in column..6 {
            matrix[column][index] /= scale;
        }
        rhs[column] /= scale;
        for row in 0..6 {
            if row == column {
                continue;
            }
            let factor = matrix[row][column];
            for index in column..6 {
                matrix[row][index] -= factor * matrix[column][index];
            }
            rhs[row] -= factor * rhs[column];
        }
    }
    rhs.iter().all(|v| v.is_finite()).then_some(rhs)
}

pub fn fit_flight(
    samples: &[Sample],
    sensor: &SensorModel,
    config: &SwingConfig,
) -> Option<FlightFit> {
    let first = samples.first()?;
    if samples.len() < 2
        || config.fit_iterations == 0
        || samples.last()?.frame_number == first.frame_number
    {
        return None;
    }
    let gravity = unit(config.up_axis).map(|value| -GRAVITY_MPS2 * value);
    let mut acceleration = gravity;
    let mut velocity_guess = unit(first.position).map(|value| value * first.radial_velocity);
    let mut rows: Vec<([f64; 6], f64)> = Vec::new();
    let mut matrix = [[0.0; 6]; 6];
    let mut parameters = [0.0; 6];
    for _ in 0..config.fit_iterations {
        let speed = norm(velocity_guess);
        let drag = config.drag_acceleration(speed);
        acceleration = std::array::from_fn(|i| {
            gravity[i] - drag * velocity_guess[i] / speed.max(f64::EPSILON)
        });
        rows.clear();
        for sample in samples {
            let t = (sample.frame_number - first.frame_number) as f64 * sensor.frame_period_s;
            let axes = basis(sample.position, unit(config.up_axis));
            let sigma = sigmas(sample.range(), sensor, config);
            for (axis, sigma) in axes.into_iter().zip(sigma) {
                let row = std::array::from_fn(|i| {
                    if i < 3 {
                        axis[i] / sigma
                    } else {
                        axis[i - 3] * t / sigma
                    }
                });
                let value =
                    (dot(axis, sample.position) - dot(axis, acceleration) * t * t / 2.0) / sigma;
                rows.push((row, value));
            }
            // XYZ angles are noisy too: treating their direction cosines as exact
            // would force transverse velocity to explain quantized radial speeds.
            let velocity = std::array::from_fn(|i| velocity_guess[i] + acceleration[i] * t);
            let variance = sensor.doppler_sigma().powi(2)
                + (dot(axes[1], velocity) * config.azimuth_resolution_sine / 12.0_f64.sqrt())
                    .powi(2)
                + (dot(axes[2], velocity) * config.elevation_resolution_sine / 12.0_f64.sqrt())
                    .powi(2);
            let sigma = variance.sqrt() * config.measurement_uncertainty_scale;
            let row = std::array::from_fn(|i| if i < 3 { 0.0 } else { axes[0][i - 3] / sigma });
            rows.push((
                row,
                (sample.radial_velocity - dot(axes[0], acceleration) * t) / sigma,
            ));
        }
        matrix = [[0.0; 6]; 6];
        let mut rhs = [0.0; 6];
        for (row, value) in &rows {
            for i in 0..6 {
                rhs[i] += row[i] * value;
                for j in 0..6 {
                    matrix[i][j] += row[i] * row[j];
                }
            }
        }
        parameters = solve(matrix, rhs)?;
        velocity_guess = parameters[3..].try_into().ok()?;
    }
    let dof = rows.len() - 6;
    let chi2 = rows
        .iter()
        .map(|(row, value)| {
            (row.iter().zip(parameters).map(|(a, b)| a * b).sum::<f64>() - value).powi(2)
        })
        .sum::<f64>();
    let mut std = [0.0; 3];
    for axis in 0..3 {
        let mut identity = [0.0; 6];
        identity[axis + 3] = 1.0;
        std[axis] = solve(matrix, identity)?[axis + 3].max(0.0).sqrt();
    }
    let mut fit = FlightFit {
        reference_frame: first.frame_number,
        position: parameters[..3].try_into().ok()?,
        velocity: parameters[3..].try_into().ok()?,
        acceleration,
        velocity_std_mps: std,
        reduced_chi_squared: chi2 / dof as f64,
        // A chi-square concentration bound expressed in configurable sigma units.
        chi_squared_limit: 1.0
            + config.fit_sigma * (2.0 / dof as f64).sqrt()
            + config.fit_sigma.powi(2) / dof as f64,
        degrees_of_freedom: dof,
        max_position_residual_m: 0.0,
        max_doppler_residual_mps: 0.0,
    };
    for sample in samples {
        let (position, velocity) = fit.at(sample.frame_number, sensor.frame_period_s);
        fit.max_position_residual_m = fit
            .max_position_residual_m
            .max(norm(sub(position, sample.position)));
        fit.max_doppler_residual_mps = fit
            .max_doppler_residual_mps
            .max((dot(unit(sample.position), velocity) - sample.radial_velocity).abs());
    }
    Some(fit)
}
