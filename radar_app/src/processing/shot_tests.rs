use super::*;
use crate::radar::frame::PointSideInfo;

fn sensor(period: f64) -> SensorModel {
    SensorModel {
        frame_period_s: period,
        range_resolution_m: 0.15,
        doppler_resolution_mps: 0.3,
        min_range_m: 0.0,
        max_range_m: 100.0,
        max_unambiguous_radial_speed_mps: 120.0,
    }
}

fn point(position: [f64; 3], velocity: [f64; 3]) -> RadarPoint {
    RadarPoint {
        x: position[0] as f32,
        y: position[1] as f32,
        z: position[2] as f32,
        radial_velocity: dot(unit(position), velocity) as f32,
        side_info: Some(PointSideInfo {
            snr_db: 5.0,
            noise_db: 0.0,
        }),
    }
}

fn sequence(
    period: f64,
    speed: f64,
    origin: [f64; 3],
    separate_ball: bool,
    missing: bool,
    noise: bool,
) -> Vec<RadarFrame> {
    let launch = 8;
    // Observe a fixed flight distance at each speed, rather than denying slow
    // balls enough samples to resolve their motion above the sensor uncertainty.
    let ball_frames = (1.2 / (speed * period)).ceil().max(8.0) as u32;
    let last = launch + ball_frames + 4;
    let club_speed = speed * 0.7;
    let deceleration = club_speed / (10.0 * period);
    let launch_y = origin[1] + club_speed * (launch - 1) as f64 * period;
    // Independent forward simulation with changing aerodynamic acceleration.
    let physics = SwingConfig::default();
    let area = std::f64::consts::PI * physics.ball_diameter_m.powi(2) / 4.0;
    let drag_k =
        physics.air_density_kg_m3 * physics.drag_coefficient * area / (2.0 * physics.ball_mass_kg);
    let mut ball_position = [origin[0], launch_y, origin[2]];
    let mut ball_velocity = [speed * 0.08, speed, speed * 0.18];
    let mut ball_states = Vec::new();
    for _ in 0..ball_frames {
        ball_states.push((ball_position, ball_velocity));
        let step = period / 16.0;
        for _ in 0..16 {
            let acceleration: [f64; 3] = std::array::from_fn(|i| {
                -drag_k * norm(ball_velocity) * ball_velocity[i]
                    - if i == 2 { GRAVITY_MPS2 } else { 0.0 }
            });
            for i in 0..3 {
                ball_position[i] += ball_velocity[i] * step + acceleration[i] * step * step / 2.0;
                ball_velocity[i] += acceleration[i] * step;
            }
        }
    }
    (1..=last + 12)
        .map(|frame| {
            let mut points = Vec::new();
            if frame <= last {
                let t = (frame as f64 - launch as f64) * period;
                let after = t.max(0.0);
                let stopped_after = after.min(club_speed / deceleration);
                let club_y = if frame < launch {
                    origin[1] + club_speed * (frame - 1) as f64 * period
                } else {
                    launch_y + club_speed * stopped_after
                        - deceleration * stopped_after * stopped_after / 2.0
                };
                let velocity = if frame < launch {
                    club_speed
                } else {
                    (club_speed - deceleration * after).max(0.0)
                };
                points.push(point([origin[0], club_y, origin[2]], [0.0, velocity, 0.0]));
                if separate_ball
                    && frame >= launch
                    && frame < launch + ball_frames
                    && (!missing || ![launch + 2, launch + 3].contains(&frame))
                {
                    let (mut position, velocity) = ball_states[(frame - launch) as usize];
                    let mut p = point(position, velocity);
                    if noise {
                        // Range-bin and angular measurement errors, not a fitted trajectory.
                        position[0] += 0.04 * ((frame as f64) * 1.7).sin();
                        position[1] += 0.03 * ((frame as f64) * 2.3).cos();
                        position[2] += 0.2 * ((frame as f64) * 1.3).sin();
                        p.x = position[0] as f32;
                        p.y = position[1] as f32;
                        p.z = position[2] as f32;
                    }
                    points.push(p);
                }
            }
            RadarFrame {
                frame_number: frame,
                points,
            }
        })
        .collect()
}

fn detect(
    frames: &[RadarFrame],
    period: f64,
    config: SwingConfig,
) -> (Vec<ShotOutput>, Vec<Value>) {
    let mut detector = ShotDetector::new(sensor(period), config);
    let mut shots = Vec::new();
    let mut reports = Vec::new();
    for frame in frames {
        if let Some(DetectionEvent::BallDetected(shot)) = detector.update(frame) {
            shots.push(shot);
        }
        if let Some(report) = detector.take_report() {
            reports.push(report);
        }
    }
    (shots, reports)
}

#[test]
fn works_across_distances_speeds_and_frame_periods_without_changing_settings() {
    for period in [0.01, 0.02, 0.04] {
        for speed in [4.0, 15.0, 40.0] {
            for origin in [[-1.0, 0.75, 0.0], [0.0, 3.0, 0.1], [1.5, 6.0, -0.2]] {
                let frames = sequence(period, speed, origin, true, false, false);
                let (shots, reports) = detect(&frames, period, SwingConfig::default());
                assert_eq!(
                    shots.len(),
                    1,
                    "period={period} speed={speed} origin={origin:?}; {}",
                    json!(reports.iter().map(|r| &r["tracks"][0]).collect::<Vec<_>>())
                );
                assert!(
                    (shots[0].speed_mps as f64
                        - speed * (1.0_f64 + 0.08_f64.powi(2) + 0.18_f64.powi(2)).sqrt())
                    .abs()
                        < speed * 0.15,
                    "speed estimate: {:?}",
                    shots[0]
                );
            }
        }
    }
}

#[test]
fn no_ball_for_club_only_ball_only_or_rigid_club_reflections() {
    let mut club_only = sequence(0.02, 15.0, [0.0, 1.0, 0.0], false, false, false);
    assert!(
        detect(&club_only, 0.02, SwingConfig::default())
            .0
            .is_empty()
    );
    for frame in &mut club_only {
        if let Some(p) = frame.points.first() {
            let reflected = RadarPoint {
                x: p.x + 0.1,
                y: p.y,
                z: p.z + 0.1,
                radial_velocity: p.radial_velocity * 0.8,
                side_info: None,
            };
            frame.points.push(reflected);
        }
    }
    assert!(
        detect(&club_only, 0.02, SwingConfig::default())
            .0
            .is_empty()
    );
    let mut ball_only = sequence(0.02, 15.0, [0.0, 1.0, 0.0], true, false, false);
    for frame in &mut ball_only {
        if !frame.points.is_empty() {
            frame.points.remove(0);
        }
    }
    assert!(
        detect(&ball_only, 0.02, SwingConfig::default())
            .0
            .is_empty()
    );
}

#[test]
fn survives_missing_returns_and_realistic_angular_noise() {
    let frames = sequence(0.02, 15.0, [-0.2, 1.0, 0.0], true, true, true);
    let (shots, reports) = detect(&frames, 0.02, SwingConfig::default());
    assert_eq!(
        shots.len(),
        1,
        "{}",
        json!(reports.iter().map(|r| &r["tracks"][0]).collect::<Vec<_>>())
    );
    let selected = reports
        .iter()
        .find(|r| r["outcome"] == "ball_detected")
        .unwrap();
    assert!(
        selected["selected_fit"]["max_position_residual_m"]
            .as_f64()
            .unwrap()
            > 0.12
    );
}

#[test]
fn custom_orientation_and_point_order_do_not_define_a_fixed_lane() {
    let mut frames = sequence(0.02, 15.0, [1.5, 3.0, 0.0], true, false, false);
    for frame in &mut frames {
        for point in &mut frame.points {
            let x = point.x;
            point.x = point.y;
            point.y = -x;
        }
        frame.points.reverse();
    }
    let config = SwingConfig {
        forward_axis: [1.0, 0.0, 0.0],
        ..SwingConfig::default()
    };
    assert_eq!(detect(&frames, 0.02, config).0.len(), 1);
}

#[test]
fn interrupted_attempt_is_logged_and_resets_discard_evidence() {
    let frames = sequence(0.02, 15.0, [0.0, 1.0, 0.0], true, false, false);
    let mut detector = ShotDetector::new(sensor(0.02), SwingConfig::default());
    for frame in &frames[..10] {
        detector.update(frame);
    }
    assert_eq!(
        detector.abort_report("disconnected").unwrap()["abort_reason"],
        "disconnected"
    );
    detector.reset();
    for frame in &frames[10..] {
        assert!(!matches!(
            detector.update(frame),
            Some(DetectionEvent::BallDetected(_))
        ));
    }
}

#[test]
fn invalid_points_do_not_arm_and_invalid_settings_fail_explicitly() {
    let mut detector = ShotDetector::new(sensor(0.02), SwingConfig::default());
    assert!(
        detector
            .update(&RadarFrame {
                frame_number: 1,
                points: vec![point([f64::NAN, 1.0, 0.0], [0.0, 1.0, 0.0])]
            })
            .is_none()
    );
    assert!(
        SwingConfig {
            measurement_uncertainty_scale: -1.0,
            ..SwingConfig::default()
        }
        .validate()
        .is_err()
    );
    assert!(
        serde_json::from_str::<SwingConfig>(r#"{"club_clearance_m":0.75}"#).is_err(),
        "old geometry gates must not silently remain active"
    );
}
