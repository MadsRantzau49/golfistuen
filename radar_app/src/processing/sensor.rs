//! Measurement scales derived from the active TI radar configuration.
use serde::{Deserialize, Serialize};

// Match the constant used by the TI demo when reporting point-cloud coordinates.
const LIGHT_SPEED_MPS: f64 = 300_000_000.0;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SensorModel {
    pub frame_period_s: f64,
    pub range_resolution_m: f64,
    pub doppler_resolution_mps: f64,
    pub min_range_m: f64,
    pub max_range_m: f64,
    pub max_unambiguous_radial_speed_mps: f64,
}

impl SensorModel {
    pub fn from_commands(commands: &[String]) -> Result<Self, String> {
        let command = |name: &str| -> Result<Vec<&str>, String> {
            let matches: Vec<_> = commands
                .iter()
                .map(|line| line.split_whitespace().collect::<Vec<_>>())
                .filter(|parts| parts.first() == Some(&name))
                .collect();
            if matches.len() != 1 {
                return Err(format!(
                    "Expected one {name} command; advanced/multi-profile framing needs an explicit sensor model"
                ));
            }
            Ok(matches[0].clone())
        };
        let number = |parts: &[&str], index: usize| -> Result<f64, String> {
            parts
                .get(index)
                .and_then(|value| value.parse::<f64>().ok())
                .filter(|value| value.is_finite())
                .ok_or_else(|| format!("Invalid {} field {index}", parts[0]))
        };
        let profile = command("profileCfg")?;
        let frame = command("frameCfg")?;
        let samples = number(&profile, 10)?;
        let sample_rate = number(&profile, 11)? * 1_000.0;
        let slope = number(&profile, 8)? * 1_000_000_000_000.0;
        let adc_start_s = number(&profile, 4)? * 0.000_001;
        let chirp_period_s = (number(&profile, 3)? + number(&profile, 5)?) * 0.000_001;
        let carrier_hz = number(&profile, 2)? * 1_000_000_000.0
            + slope * (adc_start_s + samples / (2.0 * sample_rate));
        let chirps_per_loop = number(&frame, 2)? - number(&frame, 1)? + 1.0;
        let loops = number(&frame, 3)?;
        let period = number(&frame, 5)? / 1_000.0;
        if samples <= 0.0
            || samples.fract() != 0.0
            || samples > u32::MAX as f64
            || sample_rate <= 0.0
            || slope <= 0.0
            || carrier_hz <= 0.0
            || chirp_period_s <= 0.0
            || chirps_per_loop <= 0.0
            || chirps_per_loop.fract() != 0.0
            || loops <= 0.0
            || loops.fract() != 0.0
            || loops > u32::MAX as f64
            || period <= 0.0
        {
            return Err("Invalid radar sampling/framing parameters".into());
        }
        let chirps: Vec<_> = commands
            .iter()
            .map(|line| line.split_whitespace().collect::<Vec<_>>())
            .filter(|parts| parts.first() == Some(&"chirpCfg"))
            .collect();
        if chirps_per_loop as usize > chirps.len() {
            return Err(
                "Sensor model requires distinct configured TDM chirps for each transmitter".into(),
            );
        }
        let first_chirp = number(&frame, 1)?;
        if first_chirp < 0.0 || first_chirp.fract() != 0.0 {
            return Err("Invalid first chirp index".into());
        }
        let mut transmitters = std::collections::BTreeSet::new();
        for offset in 0..chirps_per_loop as usize {
            let index = first_chirp + offset as f64;
            let matching: Vec<_> = chirps
                .iter()
                .filter(|parts| {
                    number(parts, 1).is_ok_and(|start| start <= index)
                        && number(parts, 2).is_ok_and(|end| end >= index)
                })
                .collect();
            if matching.len() != 1 {
                return Err("Each frame chirp must have one unambiguous chirpCfg".into());
            }
            let chirp = matching[0];
            let tx = number(chirp, 8)?;
            if number(chirp, 3)? != number(&profile, 1)?
                || tx <= 0.0
                || tx.fract() != 0.0
                || tx > u32::MAX as f64
                || (tx as u32).count_ones() != 1
                || !transmitters.insert(tx as u32)
                || (4..=7).any(|field| number(chirp, field).map_or(true, |value| value != 0.0))
            {
                return Err("Unsupported non-TDM/mixed-waveform chirps; refusing to guess sensor resolution".into());
            }
        }
        // The standard TI demo zero-pads the range/Doppler FFTs to powers of two.
        let range_bins = (samples as u32)
            .checked_next_power_of_two()
            .ok_or("Range FFT overflow")? as f64;
        let doppler_bins = (loops as u32)
            .checked_next_power_of_two()
            .ok_or("Doppler FFT overflow")? as f64;
        let range_resolution = LIGHT_SPEED_MPS * sample_rate / (2.0 * slope * range_bins);
        let doppler_resolution =
            LIGHT_SPEED_MPS / (2.0 * carrier_hz * chirp_period_s * chirps_per_loop * doppler_bins);
        let mut min_range = 0.0;
        let mut max_range = range_resolution * range_bins;
        for parts in commands
            .iter()
            .map(|line| line.split_whitespace().collect::<Vec<_>>())
        {
            if parts.first() == Some(&"cfarFovCfg") && parts.get(2) == Some(&"0") {
                min_range = number(&parts, 3)?;
                max_range = number(&parts, 4)?;
            }
        }
        if min_range < 0.0 || max_range <= min_range {
            return Err("Invalid radar range FOV".into());
        }
        Ok(Self {
            frame_period_s: period,
            range_resolution_m: range_resolution,
            doppler_resolution_mps: doppler_resolution,
            min_range_m: min_range,
            max_range_m: max_range,
            max_unambiguous_radial_speed_mps: doppler_resolution * doppler_bins / 2.0,
        })
    }

    pub fn range_sigma(&self) -> f64 {
        self.range_resolution_m / 12.0_f64.sqrt()
    }
    pub fn doppler_sigma(&self) -> f64 {
        self.doppler_resolution_mps / 12.0_f64.sqrt()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::radar::configuration::parse_config;

    #[test]
    fn derives_scales_from_the_uploaded_waveform_not_recorded_shots() {
        let commands = parse_config(include_str!("../../configs/golf.cfg"));
        let model = SensorModel::from_commands(&commands).unwrap();
        assert!((model.range_resolution_m - 0.1953125).abs() < 0.00001);
        assert!((model.doppler_resolution_mps - 0.4575272).abs() < 0.00001);
        assert_eq!(model.frame_period_s, 0.02);
        assert_eq!(model.max_range_m, 7.0);
        let changed: Vec<_> = commands
            .iter()
            .map(|line| line.replace("64 12500", "128 12500"))
            .collect();
        let other = SensorModel::from_commands(&changed).unwrap();
        assert!((model.range_resolution_m / other.range_resolution_m - 2.0).abs() < f64::EPSILON);
        let repeated_tx: Vec<_> = commands
            .iter()
            .map(|line| line.replace("chirpCfg 2 2 0 0 0 0 0 2", "chirpCfg 2 2 0 0 0 0 0 4"))
            .collect();
        assert!(
            SensorModel::from_commands(&repeated_tx).is_err(),
            "unsupported framing must not silently use guessed Doppler scales"
        );
    }
}
