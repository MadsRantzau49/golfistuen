//! Operator-timed capture windows and qualitative shot descriptions.
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::live_logging::{LiveLog, LogPosition};
use crate::radar::frame::RadarFrame;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Speed {
    Low,
    Medium,
    High,
    FullSpeed,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Elevation {
    Rolling,
    VeryLowJumping,
    Low,
    Medium,
    GoodSwing,
    TooHigh,
    InstantCeiling,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    FullLeft,
    Left,
    Straight,
    Right,
    FullRight,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Annotation {
    pub speed: Option<Speed>,
    pub elevation: Option<Elevation>,
    pub direction: Option<Direction>,
    pub notes: Option<String>,
}

impl Annotation {
    fn normalized(mut self) -> io::Result<Self> {
        self.notes = self
            .notes
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        if self
            .notes
            .as_ref()
            .is_some_and(|value| value.chars().count() > 4096)
        {
            return Err(io::Error::other("Notes must be at most 4096 characters"));
        }
        Ok(self)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Capture {
    pub schema_version: u32,
    pub capture_id: String,
    pub session_id: String,
    pub state: String,
    pub started: LogPosition,
    pub ended: Option<LogPosition>,
    pub end_reason: Option<String>,
    pub client_start_ms: Option<u64>,
    pub client_end_ms: Option<u64>,
    pub annotation: Annotation,
    pub annotation_revision: u64,
    pub frame_count: u64,
    pub point_count: u64,
    pub first_frame: Option<u32>,
    pub last_frame: Option<u32>,
    pub detector_attempts: u64,
    pub confirmed_balls: u64,
    pub rejected_attempts: u64,
    pub interrupted_attempts: u64,
    pub detector_results: Vec<Value>,
    pub omitted_result_summaries: u64,
    #[serde(default)]
    pub latest_registered_shot: Option<Value>,
}

impl Capture {
    pub fn summary(&self, root: &Path) -> Value {
        let mut guess = self.latest_registered_shot.clone().or_else(|| {
            self.detector_results
                .iter()
                .rev()
                .find(|result| {
                    result["outcome"] == "ball_detected" && result["selected_shot"].is_object()
                })
                .map(|result| result["selected_shot"].clone())
        });
        if let Some(shot) = guess.as_mut().and_then(Value::as_object_mut) {
            shot.remove("spin_rpm");
        }
        json!({"schema_version":self.schema_version,"capture_id":self.capture_id,"session_id":self.session_id,
            "state":self.state,"started":self.started,"ended":self.ended,"end_reason":self.end_reason,
            "duration_s":self.ended.as_ref().map(|end|(end.elapsed_s-self.started.elapsed_s).max(0.0)),
            "client_start_ms":self.client_start_ms,"client_end_ms":self.client_end_ms,
            "annotation":self.annotation,"annotation_revision":self.annotation_revision,
            "frame_count":self.frame_count,"point_count":self.point_count,"first_frame":self.first_frame,"last_frame":self.last_frame,
            "detector_attempts":self.detector_attempts,"confirmed_balls":self.confirmed_balls,"rejected_attempts":self.rejected_attempts,
            "interrupted_attempts":self.interrupted_attempts,
            "detector_guess":guess,"detector_last_result":self.detector_results.last().map(|result|&result["outcome"]),
            "recording_directory":root.join(&self.session_id),
            "capture_file":root.join(&self.session_id).join("captures").join(format!("{}.json",self.capture_id))})
    }
}

pub struct ShotNotes {
    root: PathBuf,
    session_id: String,
    captures: BTreeMap<String, Capture>,
    active: Option<String>,
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}

impl ShotNotes {
    pub fn new(log: &LiveLog) -> Self {
        Self {
            root: log.directory.parent().unwrap().to_owned(),
            session_id: log
                .directory
                .file_name()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            captures: BTreeMap::new(),
            active: None,
        }
    }

    pub fn active_id(&self) -> Option<&str> {
        self.active.as_deref()
    }

    pub fn active_summary(&self) -> Option<Value> {
        self.active
            .as_ref()
            .and_then(|id| self.captures.get(id))
            .map(|capture| capture.summary(&self.root))
    }

    pub fn info(&self, offset: usize) -> Value {
        let mut captures: Vec<_> = self.captures.values().collect();
        captures.sort_by(|a, b| b.started.elapsed_s.total_cmp(&a.started.elapsed_s));
        let offset = offset.min(captures.len());
        let selected: Vec<_> = captures
            .iter()
            .skip(offset)
            .take(64)
            .map(|capture| capture.summary(&self.root))
            .collect();
        let next = offset + selected.len();
        json!({"type":"notes_info","protocol":1,"session_id":self.session_id,"recording_directory":self.root.join(&self.session_id),
            "active_capture_id":self.active,"captures":selected,"total_captures":captures.len(),
            "next_offset":if next<captures.len() {Some(next)} else {None}})
    }

    fn directory(&self, session: &str) -> io::Result<PathBuf> {
        if !valid_id(session) {
            return Err(io::Error::other("Invalid recording session ID"));
        }
        let directory = self.root.join(session).canonicalize()?;
        if directory.parent() != Some(self.root.as_path()) {
            return Err(io::Error::other("Invalid recording directory"));
        }
        Ok(directory.join("captures"))
    }

    fn persist(&self, capture: &Capture) -> io::Result<()> {
        let directory = self.directory(&capture.session_id)?;
        fs::create_dir_all(&directory)?;
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let temporary = directory.join(format!(
            "{}.{}-{stamp}.tmp",
            capture.capture_id,
            std::process::id()
        ));
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)?;
            serde_json::to_writer_pretty(&mut file, capture)?;
            file.write_all(b"\n")?;
            file.sync_data()?;
            fs::rename(
                &temporary,
                directory.join(format!("{}.json", capture.capture_id)),
            )
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }

    pub fn start(
        &mut self,
        id: &str,
        client_ms: Option<u64>,
        log: &mut LiveLog,
        last_frame: Option<u32>,
    ) -> io::Result<Value> {
        if !valid_id(id) {
            return Err(io::Error::other("Invalid capture ID"));
        }
        if let Some(existing) = self.captures.get(id) {
            return Ok(existing.summary(&self.root));
        }
        if self.active.is_some() {
            return Err(io::Error::other(
                "A capture is already recording; end it before starting another",
            ));
        }
        let capture = Capture {
            schema_version: 1,
            capture_id: id.into(),
            session_id: self.session_id.clone(),
            state: "recording".into(),
            started: log.position(last_frame),
            ended: None,
            end_reason: None,
            client_start_ms: client_ms,
            client_end_ms: None,
            annotation: Annotation::default(),
            annotation_revision: 0,
            frame_count: 0,
            point_count: 0,
            first_frame: None,
            last_frame: None,
            detector_attempts: 0,
            confirmed_balls: 0,
            rejected_attempts: 0,
            interrupted_attempts: 0,
            detector_results: Vec::new(),
            omitted_result_summaries: 0,
            latest_registered_shot: None,
        };
        self.persist(&capture)?;
        log.set_capture_id(Some(id.to_owned()));
        log.event(
            "shot_capture_started",
            json!({"capture":capture.summary(&self.root)}),
        )?;
        log.checkpoint()?;
        let summary = capture.summary(&self.root);
        self.captures.insert(id.into(), capture);
        self.active = Some(id.into());
        Ok(summary)
    }

    pub fn end(
        &mut self,
        id: &str,
        client_ms: Option<u64>,
        reason: &str,
        log: &mut LiveLog,
        last_frame: Option<u32>,
    ) -> io::Result<Value> {
        let existing = self
            .captures
            .get(id)
            .ok_or_else(|| io::Error::other("Unknown capture"))?;
        if existing.ended.is_some() {
            return Ok(existing.summary(&self.root));
        }
        if self.active.as_deref() != Some(id) {
            return Err(io::Error::other("This capture is not active"));
        }
        let mut capture = existing.clone();
        capture.ended = Some(log.position(last_frame));
        capture.client_end_ms = client_ms;
        capture.state = if reason == "space_stop" {
            "complete"
        } else {
            "interrupted"
        }
        .into();
        capture.end_reason = Some(reason.into());
        self.persist(&capture)?;
        log.event(
            "shot_capture_ended",
            json!({"capture":capture.summary(&self.root)}),
        )?;
        log.checkpoint()?;
        log.set_capture_id(None);
        let summary = capture.summary(&self.root);
        self.captures.insert(id.into(), capture);
        self.active = None;
        Ok(summary)
    }

    pub fn interrupt(
        &mut self,
        reason: &str,
        log: &mut LiveLog,
        last_frame: Option<u32>,
    ) -> io::Result<Option<Value>> {
        match self.active.clone() {
            Some(id) => self.end(&id, None, reason, log, last_frame).map(Some),
            None => Ok(None),
        }
    }

    pub fn annotate(
        &mut self,
        session: &str,
        id: &str,
        revision: u64,
        annotation: Annotation,
        log: &mut LiveLog,
    ) -> io::Result<Value> {
        if !valid_id(id) {
            return Err(io::Error::other("Invalid capture ID"));
        }
        let annotation = annotation.normalized()?;
        let mut capture = if session == self.session_id {
            self.captures
                .get(id)
                .cloned()
                .ok_or_else(|| io::Error::other("Unknown capture"))?
        } else {
            let path = self.directory(session)?.join(format!("{id}.json"));
            let capture: Capture = serde_json::from_reader(File::open(path)?)?;
            if capture.session_id != session || capture.capture_id != id {
                return Err(io::Error::other(
                    "Capture identity does not match its recording",
                ));
            }
            capture
        };
        if capture.annotation_revision != revision {
            return Err(io::Error::other(
                "Notes changed since this form was loaded; reload the shot before saving",
            ));
        }
        capture.annotation = annotation;
        capture.annotation_revision += 1;
        self.persist(&capture)?;
        log.event("shot_annotation_saved",json!({"session_id":session,"capture_id":id,"annotation":capture.annotation,"annotation_revision":capture.annotation_revision}))?;
        log.checkpoint()?;
        let summary = capture.summary(&self.root);
        if session == self.session_id {
            self.captures.insert(id.into(), capture);
        }
        Ok(summary)
    }

    pub fn get(&self, session: &str, id: &str) -> io::Result<Value> {
        if !valid_id(id) {
            return Err(io::Error::other("Invalid capture ID"));
        }
        if session == self.session_id {
            return self
                .captures
                .get(id)
                .map(|capture| capture.summary(&self.root))
                .ok_or_else(|| io::Error::other("Unknown capture"));
        }
        let capture: Capture = serde_json::from_reader(File::open(
            self.directory(session)?.join(format!("{id}.json")),
        )?)?;
        if capture.session_id != session || capture.capture_id != id {
            return Err(io::Error::other("Capture identity mismatch"));
        }
        Ok(capture.summary(&self.root))
    }

    pub fn frame(&mut self, frame: &RadarFrame) {
        if let Some(capture) = self
            .active
            .as_ref()
            .and_then(|id| self.captures.get_mut(id))
        {
            capture.frame_count += 1;
            capture.point_count += frame.points.len() as u64;
            capture.first_frame.get_or_insert(frame.frame_number);
            capture.last_frame = Some(frame.frame_number);
        }
    }

    pub fn detector_report(&mut self, report: &Value, frame: Option<u32>) {
        if let Some(capture) = self
            .active
            .as_ref()
            .and_then(|id| self.captures.get_mut(id))
        {
            capture.detector_attempts += 1;
            match report["outcome"].as_str() {
                Some("ball_detected") => capture.confirmed_balls += 1,
                Some("no_ball_detected") => capture.rejected_attempts += 1,
                Some("aborted") => capture.interrupted_attempts += 1,
                _ => {}
            }
            let mut reasons = BTreeMap::new();
            for track in report["tracks"].as_array().into_iter().flatten() {
                if let Some(reason) = track["rejection_reason"].as_str() {
                    *reasons.entry(reason).or_insert(0usize) += 1;
                }
            }
            let mut selected_shot = report["selected_shot"].clone();
            if let Some(shot) = selected_shot.as_object_mut() {
                shot.remove("spin_rpm");
                shot.insert("algorithm".into(), report["algorithm"].clone());
                shot.insert(
                    "observations".into(),
                    json!(
                        report["selected_observations"]
                            .as_array()
                            .map_or(0, Vec::len)
                    ),
                );
                shot.insert(
                    "velocity_std_mps".into(),
                    report["selected_fit"]["velocity_std_mps"].clone(),
                );
                shot.insert(
                    "validation_mode".into(),
                    report["selected_club_evidence"]["validation_mode"].clone(),
                );
                shot.insert(
                    "club_reach_m".into(),
                    report["selected_club_evidence"]["observed_club_reach_m"].clone(),
                );
                let observations = report["selected_observations"].as_array();
                shot.insert(
                    "first_frame".into(),
                    observations
                        .and_then(|v| v.first())
                        .map_or(Value::Null, |v| v["frame_number"].clone()),
                );
                shot.insert(
                    "last_frame".into(),
                    observations
                        .and_then(|v| v.last())
                        .map_or(Value::Null, |v| v["frame_number"].clone()),
                );
                shot.insert("detection_frame".into(), json!(frame));
                shot.insert(
                    "furthest_range_m".into(),
                    report["selected_furthest_range_m"].clone(),
                );
            }
            if report["outcome"] == "ball_detected" && selected_shot.is_object() {
                capture.latest_registered_shot = Some(selected_shot.clone());
            }
            capture.detector_results.push(json!({"start_frame":report["start_frame"],"end_frame":frame,"outcome":report["outcome"],
                "abort_reason":report["abort_reason"],"point_rejections":report["point_rejections"],"track_rejections":reasons,"selected_shot":selected_shot}));
            if capture.detector_results.len() > 256 {
                capture.detector_results.remove(0);
                capture.omitted_result_summaries += 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timed_capture_persists_even_without_a_detected_ball_and_retries_are_idempotent() {
        let root = std::env::temp_dir().join(format!(
            "shot-notes-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut log = LiveLog::in_directory(&root, json!({}), "").unwrap();
        let mut notes = ShotNotes::new(&log);
        let first = notes
            .start("trial-1", Some(1000), &mut log, Some(10))
            .unwrap();
        notes.frame(&RadarFrame {
            frame_number: 11,
            points: Vec::new(),
        });
        let retry = notes
            .start("trial-1", Some(1100), &mut log, Some(11))
            .unwrap();
        assert_eq!(first["started"], retry["started"]);
        let annotation:Annotation=serde_json::from_value(json!({"speed":"low","elevation":"instant_ceiling","direction":"straight","notes":"  ~4 m ahead, ~2 m high  "})).unwrap();
        notes
            .annotate(
                first["session_id"].as_str().unwrap(),
                "trial-1",
                0,
                annotation,
                &mut log,
            )
            .unwrap();
        let ended = notes
            .end("trial-1", Some(2000), "space_stop", &mut log, Some(11))
            .unwrap();
        assert_eq!(ended["state"], "complete");
        assert_eq!(ended["frame_count"], 1);
        assert_eq!(ended["confirmed_balls"], 0);
        assert_eq!(ended["annotation"]["notes"], "~4 m ahead, ~2 m high");
        assert_eq!(
            notes
                .end("trial-1", Some(3000), "space_stop", &mut log, Some(12))
                .unwrap()["ended"],
            ended["ended"]
        );
        let saved: Value =
            serde_json::from_reader(File::open(ended["capture_file"].as_str().unwrap()).unwrap())
                .unwrap();
        assert!(
            saved["ended"]["elapsed_s"].as_f64().unwrap()
                >= saved["started"]["elapsed_s"].as_f64().unwrap()
        );
        assert!(serde_json::from_value::<Annotation>(json!({"speed":"fastest"})).is_err());
        assert!(serde_json::from_value::<Annotation>(json!({"spin":1000})).is_err());
        assert!(
            notes
                .annotate("../outside", "trial-1", 0, Annotation::default(), &mut log)
                .is_err()
        );
        notes.start("trial-2", None, &mut log, None).unwrap();
        assert_eq!(
            notes
                .interrupt("disconnected", &mut log, None)
                .unwrap()
                .unwrap()["state"],
            "interrupted"
        );
        let mut next_log = LiveLog::in_directory(&root, json!({}), "").unwrap();
        let mut next = ShotNotes::new(&next_log);
        let previous = next
            .get(first["session_id"].as_str().unwrap(), "trial-1")
            .unwrap();
        let updated = next
            .annotate(
                first["session_id"].as_str().unwrap(),
                "trial-1",
                1,
                Annotation::default(),
                &mut next_log,
            )
            .unwrap();
        assert_eq!(updated["started"], previous["started"]);
        assert_eq!(updated["annotation_revision"], 2);
        assert!(updated["annotation"]["notes"].is_null());
        assert!(
            next.annotate(
                first["session_id"].as_str().unwrap(),
                "trial-1",
                1,
                Annotation::default(),
                &mut next_log
            )
            .is_err()
        );
        drop((notes, log, next, next_log));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn accepts_all_requested_presets_without_numeric_or_spin_fields() {
        for (field, values) in [
            ("speed", vec!["low", "medium", "high", "full_speed"]),
            (
                "elevation",
                vec![
                    "rolling",
                    "very_low_jumping",
                    "low",
                    "medium",
                    "good_swing",
                    "too_high",
                    "instant_ceiling",
                ],
            ),
            (
                "direction",
                vec!["full_left", "left", "straight", "right", "full_right"],
            ),
        ] {
            for value in values {
                let mut input = json!({});
                input[field] = json!(value);
                let annotation: Annotation = serde_json::from_value(input).unwrap();
                let output = serde_json::to_value(annotation.normalized().unwrap()).unwrap();
                assert_eq!(output[field], value);
                assert!(output.get("spin").is_none());
            }
        }
        let empty = Annotation {
            notes: Some("   ".into()),
            ..Annotation::default()
        }
        .normalized()
        .unwrap();
        assert!(empty.notes.is_none());
    }

    #[test]
    fn registered_estimate_is_retained_after_rejected_motion_and_loads_from_old_records() {
        let root = std::env::temp_dir().join(format!(
            "shot-guess-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut log = LiveLog::in_directory(&root, json!({}), "").unwrap();
        let mut notes = ShotNotes::new(&log);
        notes.start("guess", None, &mut log, None).unwrap();
        notes.detector_report(&json!({"outcome":"ball_detected","algorithm":"backward_outgoing_club_reach_v2","start_frame":10,
            "selected_shot":{"shot_id":"test","speed_mps":12.5,"direction_deg":-6.0,"elevation_deg":8.0,"spin_rpm":0.0},
            "selected_observations":[{},{},{}],"tracks":[]}),Some(20));
        notes.detector_report(
            &json!({"outcome":"no_ball_detected","start_frame":30,"tracks":[]}),
            Some(40),
        );
        let saved = notes
            .end("guess", None, "space_stop", &mut log, Some(40))
            .unwrap();
        assert_eq!(saved["detector_guess"]["speed_mps"], 12.5);
        assert_eq!(saved["detector_last_result"], "no_ball_detected");
        assert!(saved["detector_guess"].get("spin_rpm").is_none());
        let mut legacy: Value =
            serde_json::from_reader(File::open(saved["capture_file"].as_str().unwrap()).unwrap())
                .unwrap();
        legacy
            .as_object_mut()
            .unwrap()
            .remove("latest_registered_shot");
        let capture: Capture = serde_json::from_value(legacy).unwrap();
        assert_eq!(
            capture.summary(&root)["detector_guess"]["direction_deg"],
            -6.0
        );
        drop((notes, log));
        fs::remove_dir_all(root).unwrap();
    }
}
