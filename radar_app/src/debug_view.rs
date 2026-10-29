//! Bounded diagnostics transport and off-thread recorded-session browsing.
use std::collections::VecDeque;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError};

use serde_json::{Value, json};

pub const OUTPUT_LIMIT: usize = 256 * 1024;
pub const CONTROL_RESERVE: usize = 8 * 1024;
const TRANSFER_LIMIT: usize = 16 * 1024 * 1024;
const LINE_LIMIT: u64 = 16 * 1024 * 1024;
const INDEX_LIMIT: usize = 1_000_000;
const POINTS_PER_PART: usize = 64;

fn wire(value: Value) -> io::Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(&value)?;
    bytes.push(b'\n');
    if bytes.len() > OUTPUT_LIMIT - 2 * CONTROL_RESERVE {
        return Err(io::Error::other("Debug record exceeds transport limit"));
    }
    Ok(bytes)
}

pub fn frame_messages(data: &Value, time_s: f64, source: &str, request: &str) -> Vec<Value> {
    let diagnostics = &data["diagnostics"];
    let points = diagnostics["points"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let parts = points.len().max(1).div_ceil(POINTS_PER_PART);
    (0..parts).map(|part| {
        let start=(part*POINTS_PER_PART).min(points.len());
        let end=(start+POINTS_PER_PART).min(points.len());
        let mut metadata=diagnostics.clone(); metadata["points"]=json!(&points[start..end]);
        json!({"type":"debug_frame","source":source,"request_id":request,"time_s":time_s,
            "part":part,"parts":parts,"detector_state":data["detector_state"],"diagnostics":metadata})
    }).collect()
}

pub fn report_messages(
    report: &Value,
    time_s: f64,
    source: &str,
    request: &str,
    id: u64,
) -> Vec<Value> {
    let mut header = report.clone();
    let tracks = header
        .as_object_mut()
        .and_then(|object| object.remove("tracks"))
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default();
    let mut messages = vec![
        json!({"type":"debug_attempt_begin","source":source,"request_id":request,
        "attempt_id":id,"time_s":time_s,"track_count":tracks.len(),"report":header}),
    ];
    messages.extend(tracks.into_iter().enumerate().map(|(index,track)|json!({
        "type":"debug_track","source":source,"request_id":request,"attempt_id":id,"index":index,"track":track})));
    messages.push(
        json!({"type":"debug_attempt_end","source":source,"request_id":request,"attempt_id":id}),
    );
    messages
}

pub struct DebugFeed {
    requests: SyncSender<Value>,
    responses: Receiver<(String, io::Result<Vec<Value>>)>,
    pending: VecDeque<Vec<u8>>,
    pending_bytes: usize,
    pub dropped_frames: u64,
    pub dropped_reports: u64,
    next_attempt: u64,
}

impl DebugFeed {
    pub fn new(root: PathBuf, current: PathBuf) -> Self {
        let (requests, worker_requests) = mpsc::sync_channel::<Value>(2);
        let (worker_responses, responses) = mpsc::sync_channel(2);
        std::thread::spawn(move || {
            let mut cached: Option<SessionIndex> = None;
            while let Ok(request) = worker_requests.recv() {
                let id = request["request_id"].as_str().unwrap_or("").to_owned();
                let result = archive_request(&root, &current, &mut cached, &request);
                if worker_responses.send((id, result)).is_err() {
                    break;
                }
            }
        });
        Self {
            requests,
            responses,
            pending: VecDeque::new(),
            pending_bytes: 0,
            dropped_frames: 0,
            dropped_reports: 0,
            next_attempt: 0,
        }
    }

    pub fn request(&self, request: Value) -> io::Result<()> {
        self.requests
            .try_send(request)
            .map_err(|_| io::Error::other("Archive reader is busy; retry the request"))
    }

    pub fn queue(&mut self, messages: Vec<Value>) -> io::Result<()> {
        let records = messages
            .into_iter()
            .map(wire)
            .collect::<io::Result<Vec<_>>>()?;
        let total: usize = records.iter().map(Vec::len).sum();
        if self.pending_bytes + total > TRANSFER_LIMIT {
            return Err(io::Error::other(
                "Debug transfer is full; wait for the current clip",
            ));
        }
        self.pending_bytes += total;
        self.pending.extend(records);
        Ok(())
    }

    pub fn report(&mut self, report: &Value, time_s: f64) {
        self.next_attempt += 1;
        if self
            .queue(report_messages(
                report,
                time_s,
                "live",
                "",
                self.next_attempt,
            ))
            .is_err()
        {
            self.dropped_reports += 1;
        }
    }

    pub fn frame(&mut self, data: &Value, time_s: f64, output: &mut Vec<u8>) {
        let records = frame_messages(data, time_s, "live", "")
            .into_iter()
            .map(wire)
            .collect::<io::Result<Vec<_>>>();
        if let Ok(records) = records {
            let total: usize = records.iter().map(Vec::len).sum();
            if output.len() + total <= OUTPUT_LIMIT - 2 * CONTROL_RESERVE {
                for record in records {
                    output.extend(record);
                }
                return;
            }
        }
        self.dropped_frames += 1;
    }

    pub fn pump(&mut self, output: &mut Vec<u8>) -> io::Result<()> {
        loop {
            match self.responses.try_recv() {
                Ok((id, result)) => {
                    let result = result.and_then(|messages| self.queue(messages));
                    if let Err(error) = result {
                        let record = wire(
                            json!({"type":"debug_error","request_id":id,"message":error.to_string()}),
                        )?;
                        if output.len() + record.len() <= OUTPUT_LIMIT {
                            output.extend(record);
                        }
                    }
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    return Err(io::Error::other("Archive reader stopped"));
                }
            }
        }
        while self
            .pending
            .front()
            .is_some_and(|record| output.len() + record.len() <= OUTPUT_LIMIT - 2 * CONTROL_RESERVE)
        {
            let record = self.pending.pop_front().unwrap();
            self.pending_bytes -= record.len();
            output.extend(record);
        }
        Ok(())
    }
}

#[derive(Clone)]
struct FrameRef {
    file: usize,
    offset: u64,
    number: u32,
    time: f64,
}
struct AttemptRef {
    file: usize,
    offset: u64,
    summary: Value,
}
struct SessionIndex {
    id: String,
    paths: Vec<PathBuf>,
    frames: Vec<FrameRef>,
    attempts: Vec<AttemptRef>,
    configuration: Value,
}

fn read_event(reader: &mut BufReader<File>) -> io::Result<Option<Value>> {
    let mut line = String::new();
    let count = reader.take(LINE_LIMIT + 1).read_line(&mut line)?;
    if count == 0 {
        return Ok(None);
    }
    if count as u64 > LINE_LIMIT {
        return Err(io::Error::other(
            "Recording event exceeds debug reader limit",
        ));
    }
    match serde_json::from_str(&line) {
        Ok(value) => Ok(Some(value)),
        // A capture currently being written may end in an incomplete last line.
        Err(_) if !line.ends_with('\n') => Ok(None),
        Err(error) => Err(io::Error::other(format!(
            "Invalid recording event: {error}"
        ))),
    }
}

fn event_at(paths: &[PathBuf], file: usize, offset: u64) -> io::Result<Value> {
    let mut reader = BufReader::new(File::open(&paths[file])?);
    reader.seek(SeekFrom::Start(offset))?;
    read_event(&mut reader)?.ok_or_else(|| io::Error::other("Recording event is not complete yet"))
}

impl SessionIndex {
    fn load(root: &Path, id: &str) -> io::Result<Self> {
        // Session IDs are directory names returned by the service, not arbitrary paths.
        if id.is_empty() || !id.bytes().all(|c| c.is_ascii_digit() || c == b'-') {
            return Err(io::Error::other("Invalid recording session ID"));
        }
        let directory = root.join(id).canonicalize()?;
        if directory.parent() != Some(root.canonicalize()?.as_path()) {
            return Err(io::Error::other("Session is outside recording directory"));
        }
        let configuration: Value =
            serde_json::from_reader(File::open(directory.join("session.json"))?)?;
        let mut paths = fs::read_dir(&directory)?
            .map(|entry| entry.map(|e| e.path()))
            .collect::<io::Result<Vec<_>>>()?;
        paths.retain(|path| {
            path.file_name()
                .and_then(|v| v.to_str())
                .is_some_and(|name| name.starts_with("events-") && name.ends_with(".jsonl"))
        });
        paths.sort();
        if paths.is_empty() {
            return Err(io::Error::other("Session has no recorded events"));
        }
        let mut frames: Vec<FrameRef> = Vec::new();
        let mut attempts = Vec::new();
        for (file, path) in paths.iter().enumerate() {
            let mut reader = BufReader::new(File::open(path)?);
            loop {
                let offset = reader.stream_position()?;
                let Some(event) = read_event(&mut reader)? else {
                    break;
                };
                if event["type"] == "frame" {
                    if frames.len() >= INDEX_LIMIT {
                        return Err(io::Error::other(
                            "Recording has too many frames for one debug index",
                        ));
                    }
                    frames.push(FrameRef {
                        file,
                        offset,
                        number: event["data"]["diagnostics"]["frame_number"]
                            .as_u64()
                            .unwrap_or(0) as u32,
                        time: event["elapsed_s"].as_f64().unwrap_or(0.0),
                    });
                } else if event["type"] == "swing_completed" || event["type"] == "operator_mark" {
                    let report = &event["data"]["report"];
                    let start = report["start_frame"].as_u64().unwrap_or(0) as u32;
                    let end_time = if event["type"] == "operator_mark" {
                        let number = report["end_frame"].as_u64().unwrap_or(0) as u32;
                        frames
                            .iter()
                            .rev()
                            .find(|frame| frame.number == number)
                            .map_or_else(
                                || report["end_time_s"].as_f64().unwrap_or(0.0),
                                |frame| frame.time,
                            )
                    } else {
                        event["elapsed_s"].as_f64().unwrap_or(0.0)
                    };
                    let start_time = frames
                        .iter()
                        .rev()
                        .find(|frame| frame.number == start)
                        .map_or_else(
                            || report["start_time_s"].as_f64().unwrap_or(end_time),
                            |frame| frame.time,
                        );
                    let index = attempts.len();
                    attempts.push(AttemptRef {file,offset,summary:json!({"id":index,"start_frame":start,
                        "end_frame":event["data"]["end_frame"],"start_time_s":start_time,"end_time_s":end_time,
                        "outcome":report["outcome"],"operator_label":report["operator_label"],"points_evaluated":report["points_evaluated"],"ball_candidates":report["ball_candidates"]})});
                }
            }
        }
        Ok(Self {
            id: id.into(),
            paths,
            frames,
            attempts,
            configuration,
        })
    }

    fn clip(&self, request: &Value) -> io::Result<Vec<Value>> {
        let index = request["attempt_id"]
            .as_u64()
            .ok_or_else(|| io::Error::other("Missing attempt ID"))? as usize;
        let attempt = self
            .attempts
            .get(index)
            .ok_or_else(|| io::Error::other("Unknown attempt"))?;
        let before = request["before_s"].as_f64().unwrap_or(0.5).clamp(0.0, 10.0);
        let after = request["after_s"].as_f64().unwrap_or(0.5).clamp(0.0, 10.0);
        let start = attempt.summary["start_time_s"].as_f64().unwrap_or(0.0) - before;
        let end = attempt.summary["end_time_s"].as_f64().unwrap_or(0.0) + after;
        let frames: Vec<_> = self
            .frames
            .iter()
            .filter(|frame| frame.time >= start && frame.time <= end)
            .collect();
        if frames.len() > 3000 {
            return Err(io::Error::other(
                "Clip contains too many frames; reduce context",
            ));
        }
        let id = request["request_id"].as_str().unwrap_or("");
        let mut messages = vec![
            json!({"type":"debug_clip_begin","request_id":id,"session_id":self.id,
            "attempt":attempt.summary,"configuration":self.configuration,"frame_count":frames.len()}),
        ];
        let mut bytes = 0;
        for frame in frames {
            let event = event_at(&self.paths, frame.file, frame.offset)?;
            let chunks = frame_messages(&event["data"], frame.time, "archive", id);
            bytes += chunks
                .iter()
                .map(|value| value.to_string().len())
                .sum::<usize>();
            if bytes > TRANSFER_LIMIT {
                return Err(io::Error::other(
                    "Clip exceeds transfer budget; reduce context",
                ));
            }
            messages.extend(chunks);
        }
        let event = event_at(&self.paths, attempt.file, attempt.offset)?;
        messages.extend(report_messages(
            &event["data"]["report"],
            attempt.summary["end_time_s"].as_f64().unwrap_or(0.0),
            "archive",
            id,
            index as u64,
        ));
        messages.push(json!({"type":"debug_clip_end","request_id":id}));
        Ok(messages)
    }
}

fn archive_request(
    root: &Path,
    current: &Path,
    cached: &mut Option<SessionIndex>,
    request: &Value,
) -> io::Result<Vec<Value>> {
    let request_id = request["request_id"].as_str().unwrap_or("");
    match request["type"].as_str() {
        Some("debug_sessions") => {
            let mut sessions = Vec::new();
            for entry in fs::read_dir(root)? {
                let entry = entry?;
                if !entry.file_type()?.is_dir() || !entry.path().join("session.json").is_file() {
                    continue;
                }
                let id = entry.file_name().to_string_lossy().into_owned();
                if !id.bytes().all(|c| c.is_ascii_digit() || c == b'-') {
                    continue;
                }
                sessions.push(json!({"id":id,"current":entry.path().canonicalize().ok()==current.canonicalize().ok()}));
            }
            sessions.sort_by(|a, b| b["id"].as_str().cmp(&a["id"].as_str()));
            sessions.truncate(1000);
            Ok(vec![
                json!({"type":"debug_sessions","request_id":request_id,"sessions":sessions}),
            ])
        }
        Some("debug_attempts") => {
            let id = request["session_id"]
                .as_str()
                .ok_or_else(|| io::Error::other("Missing session ID"))?;
            *cached = Some(SessionIndex::load(root, id)?);
            let index = cached.as_ref().unwrap();
            let skip = index.attempts.len().saturating_sub(1000);
            Ok(vec![
                json!({"type":"debug_attempts","request_id":request_id,"session_id":id,
                "frame_count":index.frames.len(),"total_attempts":index.attempts.len(),"omitted_older_attempts":skip,
                "attempts":index.attempts.iter().skip(skip).map(|a|&a.summary).collect::<Vec<_>>()}),
            ])
        }
        Some("debug_clip") => {
            let id = request["session_id"]
                .as_str()
                .ok_or_else(|| io::Error::other("Missing session ID"))?;
            if cached.as_ref().is_none_or(|index| index.id != id) {
                *cached = Some(SessionIndex::load(root, id)?);
            }
            cached.as_ref().unwrap().clip(request)
        }
        _ => Err(io::Error::other("Unknown debug archive request")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chunks_all_points_without_filtering_or_splitting_tracks() {
        let points: Vec<_> = (0..193)
            .map(|i| json!({"x":i,"y":1,"z":0,"radial_velocity":0,"ball_rejection":"background"}))
            .collect();
        let data =
            json!({"diagnostics":{"frame_number":42,"points":points},"detector_state":"waiting"});
        let chunks = frame_messages(&data, 1.0, "live", "");
        assert_eq!(chunks.len(), 4);
        let recovered: Vec<_> = chunks
            .iter()
            .flat_map(|c| c["diagnostics"]["points"].as_array().unwrap().clone())
            .collect();
        assert_eq!(recovered, points);
        assert!(
            chunks
                .into_iter()
                .all(|chunk| wire(chunk).unwrap().len() <= OUTPUT_LIMIT)
        );
    }

    #[test]
    fn backpressure_drops_whole_live_frames_and_keeps_control_capacity() {
        let mut feed = DebugFeed::new(PathBuf::from("."), PathBuf::from("."));
        let data = json!({"diagnostics":{"frame_number":1,"points":[{"x":0,"y":1,"z":0}]}});
        let mut output = vec![b' '; OUTPUT_LIMIT - 2 * CONTROL_RESERVE];
        let size = output.len();
        feed.frame(&data, 1.0, &mut output);
        assert_eq!(feed.dropped_frames, 1);
        assert_eq!(output.len(), size);
        output.clear();
        feed.frame(&data, 1.02, &mut output);
        assert_eq!(feed.dropped_frames, 1);
        assert!(output.ends_with(b"\n"));
        let event: Value = serde_json::from_slice(&output).unwrap();
        assert_eq!(event["diagnostics"]["points"].as_array().unwrap().len(), 1);
    }
}
