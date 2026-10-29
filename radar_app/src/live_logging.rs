//! Always-on, lossless UART capture and structured live diagnostics.
//! File writes are unbuffered in userspace so Ctrl+C/SIGTERM cannot lose a buffer.
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const SEGMENT_BYTES: u64 = 64 * 1024 * 1024;

struct Segments {
    directory: PathBuf,
    prefix: &'static str,
    extension: &'static str,
    file: File,
    index: u64,
    length: u64,
    limit: u64,
}

impl Segments {
    fn new(
        directory: &Path,
        prefix: &'static str,
        extension: &'static str,
        limit: u64,
    ) -> io::Result<Self> {
        let file = Self::open(directory, prefix, extension, 1)?;
        Ok(Self {
            directory: directory.to_owned(),
            prefix,
            extension,
            file,
            index: 1,
            length: 0,
            limit,
        })
    }

    fn open(directory: &Path, prefix: &str, extension: &str, index: u64) -> io::Result<File> {
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(directory.join(format!("{prefix}-{index:06}.{extension}")))
    }

    fn rotate(&mut self) -> io::Result<()> {
        self.file.sync_data()?;
        let next = Self::open(&self.directory, self.prefix, self.extension, self.index + 1)?;
        self.file = next;
        self.index += 1;
        self.length = 0;
        Ok(())
    }

    fn bytes(&mut self, mut bytes: &[u8]) -> io::Result<()> {
        while !bytes.is_empty() {
            if self.length >= self.limit {
                self.rotate()?;
            }
            let count = bytes.len().min((self.limit - self.length) as usize);
            self.file.write_all(&bytes[..count])?;
            self.length += count as u64;
            bytes = &bytes[count..];
        }
        Ok(())
    }

    fn record(&mut self, bytes: &[u8]) -> io::Result<()> {
        // A JSON record is never split across segments, even if it is oversized.
        if self.length > 0 && self.length + bytes.len() as u64 > self.limit {
            self.rotate()?;
        }
        self.file.write_all(bytes)?;
        self.length += bytes.len() as u64;
        Ok(())
    }
}

pub struct LiveLog {
    pub directory: PathBuf,
    raw: Segments,
    events: Segments,
    started: Instant,
    sequence: u64,
    raw_bytes: u64,
    swing_sequence: u64,
    active_swing: Option<u64>,
}

impl LiveLog {
    pub fn elapsed_s(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }
    pub fn start(metadata: Value, radar_config: &str) -> io::Result<Self> {
        let root = std::env::var_os("RADAR_LOG_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("logs/radar-live"));
        Self::in_directory(&root, metadata, radar_config)
    }

    pub fn in_directory(root: &Path, metadata: Value, radar_config: &str) -> io::Result<Self> {
        fs::create_dir_all(root)?;
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let directory = root.join(format!("{stamp}-{}", std::process::id()));
        fs::create_dir(&directory)?;
        let directory = directory.canonicalize()?;
        let mut config = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(directory.join("radar.cfg"))?;
        config.write_all(radar_config.as_bytes())?;
        config.sync_data()?;
        let metadata = json!({"schema_version":1, "app_version":env!("CARGO_PKG_VERSION"),
            "segment_bytes":SEGMENT_BYTES, "settings":metadata});
        let mut session = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(directory.join("session.json"))?;
        serde_json::to_writer_pretty(&mut session, &metadata)?;
        session.write_all(b"\n")?;
        session.sync_data()?;
        let mut log = Self {
            raw: Segments::new(&directory, "raw", "dat", SEGMENT_BYTES)?,
            events: Segments::new(&directory, "events", "jsonl", SEGMENT_BYTES)?,
            directory,
            started: Instant::now(),
            sequence: 0,
            raw_bytes: 0,
            swing_sequence: 0,
            active_swing: None,
        };
        log.event("session_started", metadata)?;
        eprintln!(
            "Always-on radar debug recording: {}",
            log.directory.display()
        );
        Ok(log)
    }

    pub fn raw(&mut self, bytes: &[u8]) -> io::Result<()> {
        if bytes.is_empty() {
            return Ok(());
        }
        let start = self.raw_bytes;
        self.raw.bytes(bytes)?;
        self.raw_bytes += bytes.len() as u64;
        self.event(
            "uart_read",
            json!({"bytes":bytes.len(), "stream_start":start,
            "stream_end":self.raw_bytes}),
        )
    }

    pub fn event(&mut self, kind: &str, data: Value) -> io::Result<()> {
        self.timed_event(kind, data).map(|_| ())
    }

    pub fn timed_event(&mut self, kind: &str, data: Value) -> io::Result<f64> {
        self.sequence += 1;
        let elapsed_s = self.started.elapsed().as_secs_f64();
        let mut bytes = serde_json::to_vec(&json!({
            "sequence":self.sequence, "type":kind,
            "unix_time_ms":SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis(),
            "elapsed_s":elapsed_s, "raw_bytes_received":self.raw_bytes,
            "swing_id":self.active_swing, "data":data,
        }))?;
        bytes.push(b'\n');
        self.events.record(&bytes)?;
        Ok(elapsed_s)
    }

    pub fn begin_swing(&mut self, frame_number: u32, arm: &str) -> io::Result<()> {
        self.swing_sequence += 1;
        self.active_swing = Some(self.swing_sequence);
        self.event(
            "swing_started",
            json!({"frame_number":frame_number, "arm_id":arm}),
        )
    }

    pub fn complete_swing(
        &mut self,
        report: Value,
        arm: Option<&str>,
        frame: Option<u32>,
    ) -> io::Result<()> {
        let mut track_rejections = BTreeMap::new();
        for reason in report["tracks"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|track| track["rejection_reason"].as_str())
        {
            *track_rejections.entry(reason).or_insert(0usize) += 1;
        }
        eprintln!(
            "Radar swing #{}: {} ({} points, {} motion candidates, {} flight hypotheses); point rejections: {}",
            self.active_swing.unwrap_or(0),
            report["outcome"].as_str().unwrap_or("unknown"),
            report["points_evaluated"],
            report["ball_candidates"],
            report["tracks"].as_array().map_or(0, Vec::len),
            report["point_rejections"]
        );
        if !track_rejections.is_empty() {
            eprintln!("Radar hypothesis rejections: {}", json!(track_rejections));
        }
        self.event(
            "swing_completed",
            json!({"arm_id":arm, "end_frame":frame, "report":report}),
        )?;
        self.active_swing = None;
        self.checkpoint()
    }

    pub fn checkpoint(&self) -> io::Result<()> {
        self.raw.file.sync_data()?;
        self.events.file.sync_data()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotation_preserves_raw_bytes_and_whole_event_lines_without_overwriting() {
        let root = std::env::temp_dir().join(format!(
            "radar-log-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&root).unwrap();
        let mut raw = Segments::new(&root, "raw", "dat", 5).unwrap();
        raw.bytes(b"abcdefghijkl").unwrap();
        let actual: Vec<_> = (1..=3)
            .flat_map(|index| fs::read(root.join(format!("raw-{index:06}.dat"))).unwrap())
            .collect();
        assert_eq!(actual, b"abcdefghijkl");
        let mut events = Segments::new(&root, "events", "jsonl", 10).unwrap();
        events.record(b"{\"a\":1}\n").unwrap();
        events.record(b"{\"a\":2}\n").unwrap();
        for index in 1..=2 {
            let text = fs::read_to_string(root.join(format!("events-{index:06}.jsonl"))).unwrap();
            assert!(text.ends_with('\n'));
            assert_eq!(serde_json::from_str::<Value>(&text).unwrap()["a"], index);
        }
        assert!(Segments::new(&root, "raw", "dat", 5).is_err());
        drop((raw, events));
        fs::remove_dir_all(root).unwrap();
    }
}
