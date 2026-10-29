use crate::radar::frame::{RadarFrame, RadarPoint};

#[derive(Debug, Clone)]
pub struct TrackObservation {
    pub frame_number: u32,
    pub time_s: f64,
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub radial_velocity: f32,
}

impl TrackObservation {
    pub fn from_point(point: &RadarPoint, frame_number: u32, time_s: f64) -> Self {
        Self {
            frame_number,
            time_s,
            x: point.x,
            y: point.y,
            z: point.z,
            radial_velocity: point.radial_velocity,
        }
    }

    pub fn distance_to(&self, other: &Self) -> f32 {
        let dx = self.x - other.x;
        let dy = self.y - other.y;
        let dz = self.z - other.z;

        dx.hypot(dy).hypot(dz)
    }
}

#[derive(Debug)]
pub struct BallTrack {
    pub id: u64,
    pub observations: Vec<TrackObservation>,
}

#[derive(Debug, Clone)]
pub struct TrackingConfig {
    pub max_speed_mps: f32,
    pub position_tolerance_m: f32,
    pub max_missed_frames: u32,
    pub frame_period_s: f64,
}

impl Default for TrackingConfig {
    fn default() -> Self {
        Self {
            max_speed_mps: 50.0,
            position_tolerance_m: 0.15,
            max_missed_frames: 2,
            frame_period_s: 0.020,
        }
    }
}

#[derive(Debug, Default)]
pub struct BallTracker {
    next_track_id: u64,
    active_tracks: Vec<BallTrack>,
    completed_tracks: Vec<BallTrack>,
}

impl BallTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn active_tracks(&self) -> &[BallTrack] {
        &self.active_tracks
    }

    pub fn completed_tracks(&self) -> &[BallTrack] {
        &self.completed_tracks
    }

    pub fn take_completed_tracks(&mut self) -> Vec<BallTrack> {
        std::mem::take(&mut self.completed_tracks)
    }

    pub fn total_tracks_created(&self) -> u64 {
        self.next_track_id
    }

    pub fn finish(&mut self) {
        self.completed_tracks.append(&mut self.active_tracks);
    }

    pub fn update(
        &mut self,
        frame: &RadarFrame,
        candidates: &[&RadarPoint],
        config: &TrackingConfig,
    ) {
        let frame_number = frame.frame_number;
        let time_s = frame_number as f64 * config.frame_period_s;

        let mut active = Vec::new();

        for track in self.active_tracks.drain(..) {
            let last = track.observations.last().unwrap();

            let missed_frames = frame_number.saturating_sub(last.frame_number);

            if missed_frames <= config.max_missed_frames {
                active.push(track);
            } else {
                self.completed_tracks.push(track);
            }
        }

        self.active_tracks = active;

        let mut possible_matches: Vec<(f32, usize, usize)> = Vec::new();

        for (track_index, track) in self.active_tracks.iter().enumerate() {
            let last = track.observations.last().unwrap();
            let dt = time_s - last.time_s;

            if dt <= 0.0 {
                continue;
            }

            let max_distance =
                config.max_speed_mps * dt as f32 + config.position_tolerance_m;

            for (candidate_index, point) in candidates.iter().enumerate() {
                let observation =
                    TrackObservation::from_point(point, frame_number, time_s);

                let distance = last.distance_to(&observation);

                if distance <= max_distance {
                    possible_matches.push((distance, track_index, candidate_index));
                }
            }
        }

        possible_matches.sort_by(|a, b| a.0.total_cmp(&b.0));

        let mut matched_tracks = vec![false; self.active_tracks.len()];
        let mut matched_candidates = vec![false; candidates.len()];

        for (_, track_index, candidate_index) in possible_matches {
            if matched_tracks[track_index] || matched_candidates[candidate_index] {
                continue;
            }

            let observation =
                TrackObservation::from_point(candidates[candidate_index], frame_number, time_s);

            self.active_tracks[track_index]
                .observations
                .push(observation);

            matched_tracks[track_index] = true;
            matched_candidates[candidate_index] = true;
        }

        for (candidate_index, point) in candidates.iter().enumerate() {
            if matched_candidates[candidate_index] {
                continue;
            }

            let observation = TrackObservation::from_point(point, frame_number, time_s);

            self.active_tracks.push(BallTrack {
                id: self.next_track_id,
                observations: vec![observation],
            });

            self.next_track_id += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_frame(frame_number: u32, y_positions: &[f32]) -> RadarFrame {
        RadarFrame {
            frame_number,
            points: y_positions
                .iter()
                .map(|&y| RadarPoint {
                    x: 0.0,
                    y,
                    z: 0.0,
                    radial_velocity: 10.0,
                    side_info: None,
                })
                .collect(),
        }
    }

    fn update_with_all_points(
        tracker: &mut BallTracker,
        frame: &RadarFrame,
        config: &TrackingConfig,
    ) {
        let candidates: Vec<&RadarPoint> = frame.points.iter().collect();
        tracker.update(frame, &candidates, config);
    }

    #[test]
    fn calculates_distance_between_observations() {
        let first = TrackObservation {
            frame_number: 1,
            time_s: 0.020,
            x: 0.0,
            y: 1.0,
            z: 0.0,
            radial_velocity: 10.0,
        };

        let second = TrackObservation {
            frame_number: 2,
            time_s: 0.040,
            x: 0.0,
            y: 1.2,
            z: 0.0,
            radial_velocity: 10.0,
        };

        assert!((first.distance_to(&second) - 0.2).abs() < 0.0001);
    }

    #[test]
    fn new_tracker_has_no_tracks() {
        let tracker = BallTracker::new();

        assert!(tracker.active_tracks().is_empty());
        assert!(tracker.completed_tracks().is_empty());
        assert_eq!(tracker.total_tracks_created(), 0);
    }

    #[test]
    fn creates_observation_from_radar_point() {
        let point = RadarPoint {
            x: 0.5,
            y: 2.0,
            z: 0.3,
            radial_velocity: 15.0,
            side_info: None,
        };

        let observation = TrackObservation::from_point(&point, 42, 0.84);

        assert_eq!(observation.frame_number, 42);
        assert_eq!(observation.time_s, 0.84);
        assert_eq!(observation.x, 0.5);
        assert_eq!(observation.y, 2.0);
        assert_eq!(observation.z, 0.3);
        assert_eq!(observation.radial_velocity, 15.0);
    }

    #[test]
    fn tracks_object_across_frames() {
        let mut tracker = BallTracker::new();
        let config = TrackingConfig::default();

        update_with_all_points(&mut tracker, &make_frame(1, &[1.0]), &config);
        update_with_all_points(&mut tracker, &make_frame(2, &[1.3]), &config);
        update_with_all_points(&mut tracker, &make_frame(3, &[1.6]), &config);

        assert_eq!(tracker.active_tracks().len(), 1);

        let track = &tracker.active_tracks()[0];

        assert_eq!(track.id, 0);
        assert_eq!(track.observations.len(), 3);
        assert_eq!(track.observations[0].frame_number, 1);
        assert_eq!(track.observations[2].frame_number, 3);
    }

    #[test]
    fn creates_new_track_when_distance_is_too_large() {
        let mut tracker = BallTracker::new();
        let config = TrackingConfig::default();

        update_with_all_points(&mut tracker, &make_frame(1, &[1.0]), &config);
        update_with_all_points(&mut tracker, &make_frame(2, &[3.0]), &config);

        assert_eq!(tracker.active_tracks().len(), 2);
        assert_eq!(tracker.total_tracks_created(), 2);
    }

    #[test]
    fn matches_two_objects_independently() {
        let mut tracker = BallTracker::new();
        let config = TrackingConfig::default();

        update_with_all_points(&mut tracker, &make_frame(1, &[1.0, 4.0]), &config);
        update_with_all_points(&mut tracker, &make_frame(2, &[1.2, 4.2]), &config);

        assert_eq!(tracker.active_tracks().len(), 2);

        for track in tracker.active_tracks() {
            assert_eq!(track.observations.len(), 2);
        }

        assert_eq!(tracker.active_tracks()[0].observations[1].y, 1.2);
        assert_eq!(tracker.active_tracks()[1].observations[1].y, 4.2);
    }

    #[test]
    fn retains_track_during_short_detection_gap() {
        let mut tracker = BallTracker::new();
        let config = TrackingConfig::default();

        update_with_all_points(&mut tracker, &make_frame(1, &[1.0]), &config);
        update_with_all_points(&mut tracker, &make_frame(2, &[]), &config);
        update_with_all_points(&mut tracker, &make_frame(3, &[1.4]), &config);

        assert_eq!(tracker.active_tracks().len(), 1);

        let track = &tracker.active_tracks()[0];

        assert_eq!(track.id, 0);
        assert_eq!(track.observations.len(), 2);
        assert_eq!(track.observations[0].frame_number, 1);
        assert_eq!(track.observations[1].frame_number, 3);
    }

    #[test]
    fn removes_track_after_too_many_missing_frames() {
        let mut tracker = BallTracker::new();
        let config = TrackingConfig::default();

        update_with_all_points(&mut tracker, &make_frame(1, &[1.0]), &config);
        update_with_all_points(&mut tracker, &make_frame(2, &[]), &config);
        update_with_all_points(&mut tracker, &make_frame(3, &[]), &config);

        assert_eq!(tracker.active_tracks().len(), 1);

        update_with_all_points(&mut tracker, &make_frame(4, &[]), &config);

        assert!(tracker.active_tracks().is_empty());
        assert_eq!(tracker.completed_tracks().len(), 1);
    }

    #[test]
    fn accounts_for_skipped_frame_numbers() {
        let mut tracker = BallTracker::new();
        let config = TrackingConfig::default();

        update_with_all_points(&mut tracker, &make_frame(10, &[1.0]), &config);
        update_with_all_points(&mut tracker, &make_frame(12, &[2.0]), &config);

        assert_eq!(tracker.active_tracks().len(), 1);
        assert_eq!(tracker.active_tracks()[0].observations.len(), 2);
    }

    #[test]
    fn preserves_expired_tracks() {
        let mut tracker = BallTracker::new();
        let config = TrackingConfig::default();

        update_with_all_points(&mut tracker, &make_frame(1, &[1.0]), &config);

        for frame_number in 2..=4 {
            update_with_all_points(
                &mut tracker,
                &make_frame(frame_number, &[]),
                &config,
            );
        }

        assert!(tracker.active_tracks().is_empty());
        assert_eq!(tracker.completed_tracks().len(), 1);

        let completed = tracker.take_completed_tracks();

        assert_eq!(completed.len(), 1);
        assert_eq!(completed[0].id, 0);
        assert_eq!(completed[0].observations.len(), 1);
        assert!(tracker.completed_tracks().is_empty());
    }

    #[test]
    fn finish_moves_active_tracks_to_completed() {
        let mut tracker = BallTracker::new();
        let config = TrackingConfig::default();

        update_with_all_points(&mut tracker, &make_frame(1, &[1.0]), &config);
        update_with_all_points(&mut tracker, &make_frame(2, &[1.2]), &config);

        tracker.finish();

        assert!(tracker.active_tracks().is_empty());
        assert_eq!(tracker.completed_tracks().len(), 1);
        assert_eq!(tracker.completed_tracks()[0].observations.len(), 2);
    }

    #[test]
    fn taking_completed_tracks_does_not_duplicate_them() {
        let mut tracker = BallTracker::new();
        let config = TrackingConfig::default();

        update_with_all_points(&mut tracker, &make_frame(1, &[1.0]), &config);
        update_with_all_points(&mut tracker, &make_frame(4, &[]), &config);

        let first = tracker.take_completed_tracks();
        let second = tracker.take_completed_tracks();

        assert_eq!(first.len(), 1);
        assert!(second.is_empty());
        assert_eq!(tracker.total_tracks_created(), 1);
    }
}
