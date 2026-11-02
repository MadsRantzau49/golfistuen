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
    pub outcome: Option<Outcome>,
    /// Open-ended experimental conditions, independent of detector decisions.
    pub context: BTreeMap<String, String>,
    /// Independent measured ground truth; units are explicit in each metric key.
    pub measurements: BTreeMap<String, f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Hit,
    Miss,
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
        if self.context.len() > 64 {
            return Err(io::Error::other("Use at most 64 context tags"));
        }
        let mut context = BTreeMap::new();
        for (key, value) in self.context {
            let key = key.trim();
            let value = value.trim();
            if key.is_empty() || key.len() > 64 || !key.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_') {
                return Err(io::Error::other("Context keys must be 1–64 letters, digits or underscores"));
            }
            if key == "cfg_sha256" {
                return Err(io::Error::other("cfg_sha256 is reserved for the actual recorded CFG"));
            }
            if value.chars().count() > 512 {
                return Err(io::Error::other("Context values must be at most 512 characters"));
            }
            if !value.is_empty() && context.insert(key.to_owned(), value.to_owned()).is_some() {
                return Err(io::Error::other("Duplicate context key after trimming"));
            }
        }
        self.context = context;
        if self.measurements.len() > 64 || self.measurements.iter().any(|(key, value)| {
            key.is_empty() || key.len() > 64 || !key.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_') || !value.is_finite()
        }) {
            return Err(io::Error::other("Use at most 64 finite measurements with letters/digits/underscore keys"));
        }
        if self.measurements.contains_key("speed_mps") && self.measurements.contains_key("speed_kph") {
            return Err(io::Error::other("Supply exact speed in either m/s or km/h, not both"));
        }
        for (key, value) in &self.measurements {
            if ((key == "speed_mps" || key == "speed_kph" || key == "distance_m") && *value < 0.0)
                || (key == "direction_deg" && value.abs() > 180.0)
                || (key == "elevation_deg" && value.abs() > 90.0) {
                return Err(io::Error::other("Invalid speed, distance or angle measurement"));
            }
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
    history: BTreeMap<String, Capture>,
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
        let mut notes = Self {
            root: log.directory.parent().unwrap().to_owned(),
            session_id: log
                .directory
                .file_name()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            captures: BTreeMap::new(),
            history: BTreeMap::new(),
            active: None,
        };
        notes.history = notes.load_history();
        notes
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

    fn load_history(&self) -> BTreeMap<String, Capture> {
        // History spans recordings, rather than disappearing when the service restarts.
        let mut history = BTreeMap::new();
        if let Ok(sessions) = fs::read_dir(&self.root) {
            for session in sessions.flatten() {
                let name = session.file_name().to_string_lossy().into_owned();
                if !valid_id(&name) { continue; }
                if let Ok(entries) = fs::read_dir(session.path().join("captures")) {
                    for entry in entries.flatten() {
                        if entry.path().extension().and_then(|v|v.to_str()) != Some("json") { continue; }
                        if let Ok(file) = File::open(entry.path()) {
                            if let Ok(capture) = serde_json::from_reader::<_, Capture>(file) {
                                if capture.session_id == name && entry.path().file_stem().and_then(|v|v.to_str()) == Some(capture.capture_id.as_str()) {
                                    history.insert(format!("{}/{}",name,capture.capture_id),capture);
                                }
                            }
                        }
                    }
                }
            }
        }
        history
    }

    pub fn info(&self, offset: usize) -> Value {
        let mut captures: Vec<_> = self.history.values().filter(|capture|capture.session_id != self.session_id)
            .chain(self.captures.values()).collect();
        captures.sort_by(|a, b| b.started.unix_time_ms.cmp(&a.started.unix_time_ms));
        let offset = offset.min(captures.len());
        let selected: Vec<_> = captures
            .iter()
            .skip(offset)
            .take(64)
            .map(|capture| capture.summary(&self.root))
            .collect();
        let next = offset + selected.len();
        json!({"type":"notes_info","protocol":1,"session_id":self.session_id,"recording_directory":self.root.join(&self.session_id),
            "capabilities":{"capture_delete":true,"regression":true},
            "active_capture_id":self.active,"captures":selected,"total_captures":captures.len(),"all_sessions":true,
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

    pub fn deleted_keys(&self, keys: &Value) -> Vec<String> {
        keys.as_array().into_iter().flatten().take(512).filter_map(|key| {
            let key = key.as_str()?;
            let (session,id) = key.split_once('/')?;
            if !valid_id(id) { return None; }
            let directory = self.directory(session).ok()?.parent()?.join("deleted-captures");
            directory.join(format!("{id}.json")).is_file().then(||key.to_owned())
        }).collect()
    }

    pub fn delete(&mut self, session: &str, id: &str, revision: u64, log: &mut LiveLog) -> io::Result<Value> {
        if !valid_id(id) { return Err(io::Error::other("Invalid capture ID")); }
        if session == self.session_id && self.active_id() == Some(id) {
            return Err(io::Error::other("End the recording before deleting this shot"));
        }
        let directory = self.directory(session)?;
        let archive = directory.parent().unwrap().join("deleted-captures");
        let source = directory.join(format!("{id}.json"));
        let target = archive.join(format!("{id}.json"));
        if !source.exists() && target.is_file() {
            return Ok(json!({"type":"capture_deleted","session_id":session,"capture_id":id}));
        }
        let capture: Capture = serde_json::from_reader(File::open(&source)?)?;
        if capture.session_id != session || capture.capture_id != id || capture.annotation_revision != revision {
            return Err(io::Error::other("Shot changed since loading; reload it before deleting"));
        }
        fs::create_dir_all(&archive)?;
        fs::rename(source,target)?;
        if session == self.session_id { self.captures.remove(id); }
        self.history.remove(&format!("{session}/{id}"));
        log.event("shot_capture_deleted",json!({"session_id":session,"capture_id":id}))?;
        log.checkpoint()?;
        Ok(json!({"type":"capture_deleted","session_id":session,"capture_id":id}))
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
        self.start_annotated(id, client_ms, None, log, last_frame)
    }

    pub fn start_annotated(
        &mut self,
        id: &str,
        client_ms: Option<u64>,
        annotation: Option<Annotation>,
        log: &mut LiveLog,
        last_frame: Option<u32>,
    ) -> io::Result<Value> {
        if !valid_id(id) {
            return Err(io::Error::other("Invalid capture ID"));
        }
        if self.directory(&self.session_id)?.parent().unwrap().join("deleted-captures").join(format!("{id}.json")).exists() {
            return Err(io::Error::other("This capture was deleted; start a new shot"));
        }
        if let Some(existing) = self.captures.get(id) {
            return Ok(existing.summary(&self.root));
        }
        if self.active.is_some() {
            return Err(io::Error::other(
                "A capture is already recording; end it before starting another",
            ));
        }
        let annotation = annotation.unwrap_or_else(|| {
            let mut previous = self.captures.values()
                .max_by(|a, b| a.started.elapsed_s.total_cmp(&b.started.elapsed_s))
                .map(|capture| capture.annotation.clone()).unwrap_or_default();
            previous.notes = None;
            // Measured truth belongs to this attempt, unlike the repeated setup/labels.
            previous.measurements.clear();
            previous
        }).normalized()?;
        let capture = Capture {
            schema_version: 2,
            capture_id: id.into(),
            session_id: self.session_id.clone(),
            state: "recording".into(),
            started: log.position(last_frame),
            ended: None,
            end_reason: None,
            client_start_ms: client_ms,
            client_end_ms: None,
            annotation,
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
        } else {
            self.history.insert(format!("{session}/{id}"),capture);
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
    fn deletion_survives_restarts_and_does_not_remove_shared_recordings() {
        let root = std::env::temp_dir().join(format!("shot-delete-{}-{}",std::process::id(),SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        let mut log = LiveLog::in_directory(&root,json!({}),"cfg").unwrap();
        let mut notes = ShotNotes::new(&log);
        let capture = notes.start("remove-me",None,&mut log,None).unwrap();
        let session = capture["session_id"].as_str().unwrap();
        assert!(notes.delete(session,"remove-me",0,&mut log).is_err());
        notes.end("remove-me",None,"space_stop",&mut log,None).unwrap();
        let next_log = LiveLog::in_directory(&root,json!({}),"cfg").unwrap();
        let other = ShotNotes::new(&next_log);
        assert_eq!(other.info(0)["total_captures"],1);
        assert!(notes.delete(session,"remove-me",1,&mut log).is_err());
        notes.delete(session,"remove-me",0,&mut log).unwrap();
        assert_eq!(notes.info(0)["total_captures"],0);
        assert!(!log.directory.join("captures/remove-me.json").exists());
        assert!(log.directory.join("deleted-captures/remove-me.json").is_file());
        assert!(log.directory.join("raw-000001.dat").is_file());
        assert!(notes.start("remove-me",None,&mut log,None).is_err());
        let mut restored = ShotNotes::new(&next_log);
        assert_eq!(restored.info(0)["total_captures"],0);
        assert!(restored.get(session,"remove-me").is_err());
        assert_eq!(restored.deleted_keys(&json!([format!("{session}/remove-me")])),vec![format!("{session}/remove-me")]);
        assert_eq!(restored.delete(session,"remove-me",0,&mut log).unwrap()["type"],"capture_deleted");
        drop((notes,restored,other,log,next_log));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn context_and_exact_measurements_are_open_ended_validated_and_legacy_compatible() {
        let legacy: Annotation = serde_json::from_value(json!({"speed":"low"})).unwrap();
        assert!(legacy.context.is_empty() && legacy.measurements.is_empty() && legacy.outcome.is_none());
        let annotation: Annotation = serde_json::from_value(json!({"outcome":"miss",
            "context":{"room":"  big room  ","custom_support":"pillow moves","empty":" "},
            "measurements":{"speed_kph":54.2,"direction_deg":-12.0,"distance_m":4.2,"custom_metric_m":1.5}})).unwrap();
        let annotation = annotation.normalized().unwrap();
        assert_eq!(annotation.context["room"], "big room");
        assert!(!annotation.context.contains_key("empty"));
        assert_eq!(annotation.measurements["custom_metric_m"], 1.5);
        for invalid in [json!({"context":{"cfg_sha256":"invented"}}),
            json!({"context":{"bad key":"x"}}), json!({"measurements":{"distance_m":-1}}),
            json!({"measurements":{"direction_deg":181}}),
            json!({"measurements":{"speed_mps":1,"speed_kph":3.6}})] {
            assert!(serde_json::from_value::<Annotation>(invalid).unwrap().normalized().is_err());
        }
        assert!(serde_json::from_value::<Annotation>(json!({"measurements":{"distance_m":"four"}})).is_err());
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
