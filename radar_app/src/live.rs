//! Live serial capture, gameplay shots, and operator-timed shot notes over NDJSON.
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::live_logging::LiveLog;
use crate::processing::estimation::ShotOutput;
use crate::processing::sensor::SensorModel;
use crate::processing::shot::{DetectionEvent, ShotDetector, SwingConfig};
use crate::radar::device::RadarDevice;
use crate::radar::frame::RadarFrame;
use crate::radar::protocol::{PacketDecoder, parse_frame};
use crate::shot_notes::{Annotation, ShotNotes};
use serde_json::{Value, json};

const FRAME_TIMEOUT: Duration = Duration::from_secs(1);
const OUTPUT_LIMIT: usize = 2 * 1024 * 1024;

pub struct LiveDetector {
    detector: ShotDetector,
    pub state: &'static str,
}

impl LiveDetector {
    pub fn new(sensor: SensorModel, swing: SwingConfig) -> Self {
        Self {
            detector: ShotDetector::new(sensor, swing),
            state: "waiting_for_swing",
        }
    }
    pub fn reset(&mut self) {
        self.detector.reset();
        self.state = "waiting_for_swing";
    }
    pub fn configuration(&self) -> Value {
        self.detector.configuration()
    }
    pub fn update(&mut self, frame: &RadarFrame) -> Option<ShotOutput> {
        match self.detector.update(frame)? {
            DetectionEvent::SwingDetected => self.state = "swing_detected",
            DetectionEvent::NoBallDetected => self.state = "no_ball_detected",
            DetectionEvent::BallDetected(shot) => {
                self.state = "ball_detected";
                return Some(shot);
            }
        }
        None
    }
}

struct Client {
    socket: TcpStream,
    input: Vec<u8>,
    output: Vec<u8>,
    arm: Option<String>,
    consumed_arm: Option<String>,
    last_heard: Instant,
    notes_enabled: bool,
    notes_announced: bool,
    requests: Vec<Value>,
    failed: bool,
}

impl Client {
    fn new(socket: TcpStream) -> io::Result<Self> {
        socket.set_nonblocking(true)?;
        socket.set_nodelay(true)?;
        Ok(Self {
            socket,
            input: Vec::new(),
            output: Vec::new(),
            arm: None,
            consumed_arm: None,
            last_heard: Instant::now(),
            notes_enabled: false,
            notes_announced: false,
            requests: Vec::new(),
            failed: false,
        })
    }

    fn queue(&mut self, message: Value) -> io::Result<()> {
        let bytes = serde_json::to_vec(&message)?;
        if self.output.len() + bytes.len() + 1 > OUTPUT_LIMIT {
            return Err(io::Error::other("Client is not reading events"));
        }
        self.output.extend(bytes);
        self.output.push(b'\n');
        Ok(())
    }

    fn send(&mut self, message: Value) {
        if self.queue(message).is_err() {
            self.failed = true;
        }
    }

    fn poll(&mut self) -> io::Result<bool> {
        if self.failed {
            return Err(io::Error::other(
                "Client output backlog exceeded its budget",
            ));
        }
        self.flush()?;
        let mut changed = false;
        let mut buffer = [0; 4096];
        loop {
            match self.socket.read(&mut buffer) {
                Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
                Ok(n) => self.input.extend_from_slice(&buffer[..n]),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error),
            }
            if self.input.len() > 65536 {
                return Err(io::Error::other("Oversized client message"));
            }
        }
        while let Some(end) = self.input.iter().position(|&byte| byte == b'\n') {
            let line: Vec<_> = self.input.drain(..=end).collect();
            let message: Value = serde_json::from_slice(&line)?;
            if message["type"] == "notes_subscribe" {
                self.last_heard = Instant::now();
                let enabled = message["enabled"] == true;
                if enabled != self.notes_enabled {
                    self.notes_enabled = enabled;
                    self.notes_announced = false;
                    self.arm = None;
                    self.consumed_arm = None;
                    changed = true;
                }
                continue;
            }
            if self.notes_enabled {
                if matches!(
                    message["type"].as_str(),
                    Some(
                        "capture_start"
                            | "capture_end"
                            | "capture_annotate"
                            | "capture_get"
                            | "notes_list"
                    )
                ) {
                    self.last_heard = Instant::now();
                    if self.requests.len() < 8 {
                        self.requests.push(message);
                    } else {
                        self.send(json!({"type":"notes_error","request_id":message["request_id"],"message":"Too many pending note requests; retry saving"}));
                    }
                }
                continue;
            }
            if message["type"] != "ready" {
                continue;
            }
            self.last_heard = Instant::now();
            let arm = if message["ready"] == true {
                message["arm_id"]
                    .as_str()
                    .filter(|s| !s.is_empty() && s.len() <= 128)
                    .map(str::to_owned)
            } else {
                None
            };
            if arm.is_some() && arm == self.consumed_arm {
                continue;
            }
            changed |= self.arm != arm;
            self.arm = arm;
        }
        if self.last_heard.elapsed() > Duration::from_secs(3) {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Client heartbeat stopped",
            ));
        }
        self.flush()?;
        Ok(changed)
    }

    fn flush(&mut self) -> io::Result<()> {
        while !self.output.is_empty() {
            match self.socket.write(&self.output) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(n) => {
                    self.output.drain(..n);
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
}

fn save_report(
    detector: &mut LiveDetector,
    notes: &mut ShotNotes,
    log: &mut LiveLog,
    arm: Option<&str>,
    frame: Option<u32>,
) -> io::Result<()> {
    if let Some(report) = detector.detector.take_report() {
        notes.detector_report(&report, frame);
        log.complete_swing(report, arm, frame)?;
    }
    Ok(())
}

fn reset_detector(
    detector: &mut LiveDetector,
    notes: &mut ShotNotes,
    log: &mut LiveLog,
    reason: &str,
    arm: Option<&str>,
    frame: Option<u32>,
) -> io::Result<()> {
    if let Some(report) = detector.detector.abort_report(reason) {
        notes.detector_report(&report, frame);
        log.complete_swing(report, arm, frame)?;
    }
    detector.reset();
    Ok(())
}

fn close_client(
    detector: &mut LiveDetector,
    notes: &mut ShotNotes,
    log: &mut LiveLog,
    reason: &str,
    arm: Option<&str>,
    frame: Option<u32>,
) -> io::Result<()> {
    reset_detector(detector, notes, log, reason, arm, frame)?;
    notes.interrupt(reason, log, frame)?;
    Ok(())
}

fn notes_request(
    game: &mut Client,
    request: &Value,
    detector: &mut LiveDetector,
    notes: &mut ShotNotes,
    log: &mut LiveLog,
    frame: Option<u32>,
) -> io::Result<()> {
    let result = (|| -> io::Result<Value> {
        match request["type"].as_str() {
            Some("notes_list") => Ok(notes.info(request["offset"].as_u64().unwrap_or(0) as usize)),
            Some("capture_get") => {
                let session = request["session_id"]
                    .as_str()
                    .ok_or_else(|| io::Error::other("Missing session ID"))?;
                let id = request["capture_id"]
                    .as_str()
                    .ok_or_else(|| io::Error::other("Missing capture ID"))?;
                Ok(json!({"type":"capture_loaded","capture":notes.get(session,id)?}))
            }
            Some("capture_start") => {
                let id = request["capture_id"]
                    .as_str()
                    .ok_or_else(|| io::Error::other("Missing capture ID"))?;
                let capture = notes.start(id, request["client_time_ms"].as_u64(), log, frame)?;
                game.arm = notes.active_id().map(str::to_owned);
                Ok(json!({"type":"capture_started","capture":capture}))
            }
            Some("capture_end") => {
                let id = request["capture_id"]
                    .as_str()
                    .ok_or_else(|| io::Error::other("Missing capture ID"))?;
                if notes.active_id() == Some(id) {
                    // Evaluate only observations already inside the operator's window.
                    let event = detector.detector.finish();
                    if let Some(DetectionEvent::BallDetected(shot)) = event {
                        if let Some(mut report) = detector.detector.take_report() {
                            report["selected_shot"] = json!(shot);
                            notes.detector_report(&report, frame);
                            log.complete_swing(report, Some(id), frame)?;
                        }
                    } else {
                        save_report(detector, notes, log, Some(id), frame)?;
                    }
                    detector.reset();
                }
                let capture = notes.end(
                    id,
                    request["client_time_ms"].as_u64(),
                    "space_stop",
                    log,
                    frame,
                )?;
                game.arm = notes.active_id().map(str::to_owned);
                Ok(json!({"type":"capture_ended","capture":capture}))
            }
            Some("capture_annotate") => {
                let session = request["session_id"]
                    .as_str()
                    .ok_or_else(|| io::Error::other("Missing session ID"))?;
                let id = request["capture_id"]
                    .as_str()
                    .ok_or_else(|| io::Error::other("Missing capture ID"))?;
                let revision = request["annotation_revision"]
                    .as_u64()
                    .ok_or_else(|| io::Error::other("Missing annotation revision"))?;
                let annotation: Annotation = serde_json::from_value(request["annotation"].clone())?;
                let capture = notes.annotate(session, id, revision, annotation, log)?;
                Ok(json!({"type":"capture_saved","capture":capture}))
            }
            _ => Err(io::Error::other("Unknown shot-notes request")),
        }
    })();
    let mut response = match result {
        Ok(value) => value,
        Err(error) => {
            json!({"type":"notes_error","message":error.to_string(),"capture_id":request["capture_id"],"session_id":request["session_id"],"operation":request["type"]})
        }
    };
    response["request_id"] = request["request_id"].clone();
    game.send(response);
    Ok(())
}

pub fn run(
    device: &mut RadarDevice,
    listener: TcpListener,
    sensor: SensorModel,
    swing: SwingConfig,
    log: &mut LiveLog,
) -> io::Result<()> {
    let mut detector = LiveDetector::new(sensor, swing);
    let mut notes = ShotNotes::new(log);
    let result = run_loop(device, listener, &mut detector, &mut notes, log);
    close_client(
        &mut detector,
        &mut notes,
        log,
        "service_stopped",
        None,
        None,
    )?;
    log.event(
        "service_stopped",
        json!({"error":result.as_ref().err().map(ToString::to_string)}),
    )?;
    log.checkpoint()?;
    result
}

fn run_loop(
    device: &mut RadarDevice,
    listener: TcpListener,
    detector: &mut LiveDetector,
    notes: &mut ShotNotes,
    log: &mut LiveLog,
) -> io::Result<()> {
    listener.set_nonblocking(true)?;
    let session = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let mut sequence = 0u64;
    let mut decoder = PacketDecoder::new();
    let mut client: Option<Client> = None;
    let mut last_frame: Option<Instant> = None;
    let mut last_number: Option<u32> = None;
    let mut radar_was_fresh = false;
    let mut heartbeat = Instant::now() - Duration::from_secs(1);
    let mut buffer = [0; 8192];
    loop {
        match listener.accept() {
            Ok((socket, address)) => {
                close_client(
                    detector,
                    notes,
                    log,
                    "client_replaced",
                    client.as_ref().and_then(|c| c.arm.as_deref()),
                    last_number,
                )?;
                eprintln!("Golf client connected: {address}");
                log.event("game_connected", json!({"address":address.to_string()}))?;
                client = Some(Client::new(socket)?);
                heartbeat = Instant::now() - Duration::from_secs(1);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => return Err(error),
        }
        if let Some(game) = client.as_mut() {
            let previous_arm = game.arm.clone();
            let was_notes = game.notes_enabled;
            match game.poll() {
                Ok(true) => {
                    reset_detector(
                        detector,
                        notes,
                        log,
                        "arm_changed",
                        previous_arm.as_deref(),
                        last_number,
                    )?;
                    if was_notes && !game.notes_enabled {
                        notes.interrupt("notes_mode_closed", log, last_number)?;
                    }
                    log.event(
                        "arm_changed",
                        json!({"previous_arm":previous_arm,"arm_id":game.arm}),
                    )?;
                }
                Ok(false) => {}
                Err(error) => {
                    close_client(
                        detector,
                        notes,
                        log,
                        if was_notes {
                            "client_disconnected"
                        } else {
                            "game_disconnected"
                        },
                        previous_arm.as_deref(),
                        last_number,
                    )?;
                    eprintln!("Golf client disconnected: {error}");
                    log.event("game_disconnected", json!({"error":error.to_string()}))?;
                    client = None;
                }
            }
        }
        if let Some(game) = client.as_mut() {
            if game.notes_enabled {
                if !game.notes_announced {
                    game.send(notes.info(0));
                    game.notes_announced = true;
                }
                for request in std::mem::take(&mut game.requests) {
                    notes_request(game, &request, detector, notes, log, last_number)?;
                }
                game.arm = notes.active_id().map(str::to_owned);
            }
        }
        let fresh = last_frame.is_some_and(|time| time.elapsed() < FRAME_TIMEOUT);
        if !fresh {
            if radar_was_fresh {
                log.event("frame_timeout", json!({"last_frame":last_number}))?;
                radar_was_fresh = false;
            }
            let arm = client.as_ref().and_then(|game| game.arm.clone());
            reset_detector(
                detector,
                notes,
                log,
                "frame_timeout",
                arm.as_deref(),
                last_number,
            )?;
            if let Some(game) = client.as_mut() {
                if !game.notes_enabled {
                    game.arm = None;
                }
            }
        }
        match device.read_data(&mut buffer) {
            Ok(count) => {
                log.raw(&buffer[..count])?;
                decoder.push(&buffer[..count]);
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) => {}
            Err(error) => return Err(error),
        }
        while let Some(packet) = decoder.next_packet() {
            let Some(frame) = parse_frame(&packet) else {
                log.event(
                    "packet_decode_failed",
                    json!({"packet_length":packet.len()}),
                )?;
                continue;
            };
            if let Some(previous) = last_number {
                if frame.frame_number <= previous {
                    log.event(
                        "frame_number_reset",
                        json!({"previous":previous,"current":frame.frame_number}),
                    )?;
                    reset_detector(
                        detector,
                        notes,
                        log,
                        "frame_number_reset",
                        client.as_ref().and_then(|c| c.arm.as_deref()),
                        Some(frame.frame_number),
                    )?;
                } else if frame.frame_number - previous > 1 {
                    log.event("frame_gap",json!({"previous":previous,"current":frame.frame_number,"missing_frames":frame.frame_number-previous-1}))?;
                }
            }
            last_number = Some(frame.frame_number);
            last_frame = Some(Instant::now());
            notes.frame(&frame);
            if !radar_was_fresh {
                radar_was_fresh = true;
                log.event(
                    "radar_frames_available",
                    json!({"frame_number":frame.frame_number}),
                )?;
            }
            log.event("frame",json!({"arm_id":client.as_ref().and_then(|c|c.arm.as_deref()),"game_connected":client.is_some(),
                "detector_state":detector.state,"diagnostics":detector.detector.frame_diagnostics(&frame)}))?;
            let Some(game) = client.as_mut() else {
                continue;
            };
            if game.arm.is_none() {
                continue;
            }
            let previous = detector.state;
            if let Some(mut shot) = detector.update(&frame) {
                sequence += 1;
                shot.shot_id = format!("live-{session}-{sequence}");
                log.event("shot_emitted",json!({"arm_id":game.arm,"frame_number":frame.frame_number,"shot":shot,"notes_capture":game.notes_enabled}))?;
                if let Some(mut report) = detector.detector.take_report() {
                    report["selected_shot"] = json!(shot);
                    notes.detector_report(&report, last_number);
                    log.complete_swing(report, game.arm.as_deref(), last_number)?;
                }
                println!("{}", serde_json::to_string(&shot)?);
                if !game.notes_enabled {
                    let arm = game.arm.take().unwrap();
                    game.consumed_arm = Some(arm.clone());
                    game.send(json!({"type":"shot","arm_id":arm,"shot":shot}));
                    detector.reset();
                }
            } else if detector.state != previous {
                eprintln!("Radar: {}", detector.state);
                if detector.state == "swing_detected" {
                    log.begin_swing(frame.frame_number, game.arm.as_deref().unwrap())?;
                } else {
                    save_report(detector, notes, log, game.arm.as_deref(), last_number)?;
                }
                game.send(json!({"type":"detection","arm_id":game.arm,"state":detector.state}));
            }
        }
        if heartbeat.elapsed() >= Duration::from_millis(250) {
            heartbeat = Instant::now();
            if let Some(game) = client.as_mut() {
                game.send(json!({"type":"status","radar_ready":last_frame.is_some_and(|time|time.elapsed()<FRAME_TIMEOUT),"protocol":1,
                    "arm_id":game.arm,"detection_state":detector.state,"notes_mode":game.notes_enabled,"active_capture_id":notes.active_id(),"last_frame_number":last_number}));
                if game.notes_enabled {
                    if let Some(capture)=notes.active_summary() {game.send(json!({"type":"capture_progress","capture":capture}));}
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::radar::frame::RadarPoint;
    fn frame(number: u32, positions: &[f32]) -> RadarFrame {
        RadarFrame {
            frame_number: number,
            points: positions
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
    #[test]
    fn reset_discards_partial_shots_when_turn_is_revoked() {
        let commands =
            crate::radar::configuration::parse_config(include_str!("../configs/golf.cfg"));
        let mut detector = LiveDetector::new(
            SensorModel::from_commands(&commands).unwrap(),
            SwingConfig::default(),
        );
        detector.update(&frame(1, &[1.5]));
        for number in 2..=5 {
            detector.update(&frame(number, &[2.8 + (number - 2) as f32 * 0.2]));
        }
        detector.reset();
        for number in 6..25 {
            assert!(detector.update(&frame(number, &[])).is_none());
        }
    }
    #[test]
    fn consumed_arm_cannot_be_rearmed_by_delayed_game_heartbeat() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut remote = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let mut client = Client::new(listener.accept().unwrap().0).unwrap();
        remote
            .write_all(b"{\"type\":\"ready\",\"ready\":true,")
            .unwrap();
        client.poll().unwrap();
        assert!(client.arm.is_none());
        remote.write_all(b"\"arm_id\":\"turn-1\"}\n").unwrap();
        for _ in 0..100 {
            client.poll().unwrap();
            if client.arm.is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(client.arm.as_deref(), Some("turn-1"));
        client.consumed_arm = client.arm.take();
        remote
            .write_all(b"{\"type\":\"ready\",\"ready\":true,\"arm_id\":\"turn-1\"}\n")
            .unwrap();
        for _ in 0..20 {
            client.poll().unwrap();
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(client.arm.is_none());
        remote.write_all(b"{\"type\":\"ready\",\"ready\":false}\n{\"type\":\"ready\",\"ready\":true,\"arm_id\":\"turn-2\"}\n").unwrap();
        for _ in 0..100 {
            client.poll().unwrap();
            if client.arm.is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(client.arm.as_deref(), Some("turn-2"));
    }
}
