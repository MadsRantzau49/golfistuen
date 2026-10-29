//! Live serial -> frame -> track -> shot, served as newline-delimited JSON over TCP.
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use crate::processing::estimation::ShotOutput;
use crate::processing::shot::{DetectionEvent, ShotDetector, SwingConfig};
use crate::processing::sensor::SensorModel;
use crate::live_logging::LiveLog;
use crate::debug_view::{DebugFeed, OUTPUT_LIMIT, CONTROL_RESERVE};
use crate::radar::device::RadarDevice;
use crate::radar::frame::RadarFrame;
use crate::radar::protocol::{PacketDecoder, parse_frame};

const FRAME_TIMEOUT: Duration = Duration::from_secs(1);

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

    pub fn configuration(&self) -> Value { self.detector.configuration() }

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
    debug_enabled: bool,
    debug: Option<DebugFeed>,
    debug_requests: Vec<Value>,
}

impl Client {
    fn new(socket: TcpStream) -> io::Result<Self> {
        socket.set_nonblocking(true)?;
        socket.set_nodelay(true)?;
        Ok(Self { socket, input: Vec::new(), output: Vec::new(), arm: None, consumed_arm: None, last_heard: Instant::now(),
            debug_enabled:false, debug:None, debug_requests:Vec::new() })
    }

    fn queue(&mut self, message: Value) -> io::Result<()> {
        let bytes=serde_json::to_vec(&message)?;
        if self.output.len()+bytes.len()+1 > OUTPUT_LIMIT { return Err(io::Error::other("Game is not reading events")); }
        self.output.extend(bytes);
        self.output.push(b'\n');
        Ok(())
    }

    fn poll(&mut self) -> io::Result<bool> {
        self.flush()?;
        if self.debug_enabled && self.output.len()>OUTPUT_LIMIT-CONTROL_RESERVE {
            return Err(io::Error::other("Debug viewer is not reading telemetry; recordings continue on the radar computer"));
        }
        let mut changed = false;
        let mut buffer = [0; 4096];
        loop {
            match self.socket.read(&mut buffer) {
                Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
                Ok(n) => self.input.extend_from_slice(&buffer[..n]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
            if self.input.len() > 65536 { return Err(io::Error::other("Oversized game message")); }
        }
        while let Some(end) = self.input.iter().position(|&b| b == b'\n') {
            let line: Vec<_> = self.input.drain(..=end).collect();
            let message: Value = serde_json::from_slice(&line)?;
            if message["type"]=="debug_subscribe" {
                self.last_heard=Instant::now();
                let enabled=message["enabled"]==true;
                changed|=self.debug_enabled!=enabled;
                self.debug_enabled=enabled;
                let arm=enabled.then(||"radar-debug".to_owned());
                changed|=self.arm!=arm; self.arm=arm; self.consumed_arm=None;
                continue;
            }
            if self.debug_enabled && matches!(message["type"].as_str(),Some("debug_sessions"|"debug_attempts"|"debug_clip"|"debug_mark")) {
                self.last_heard=Instant::now();
                if self.debug_requests.len()<4 {self.debug_requests.push(message);}
                else {self.queue(json!({"type":"debug_error","request_id":message["request_id"],"message":"Too many pending archive requests; retry after the current transfer"}))?;}
                continue;
            }
            if self.debug_enabled {continue;}
            if message["type"] != "ready" { continue; }
            self.last_heard = Instant::now();
            let arm = if message["ready"] == true {
                message["arm_id"].as_str().filter(|s| !s.is_empty() && s.len() <= 128).map(str::to_owned)
            } else { None };
            if arm.is_some() && arm == self.consumed_arm { continue; }
            changed |= self.arm != arm;
            self.arm = arm;
        }
        if self.last_heard.elapsed() > Duration::from_secs(3) {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "Game heartbeat stopped"));
        }
        if let Some(debug)=self.debug.as_mut() {debug.pump(&mut self.output)?;}
        self.flush()?;
        Ok(changed)
    }

    fn flush(&mut self) -> io::Result<()> {
        while !self.output.is_empty() {
            match self.socket.write(&self.output) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(n) => { self.output.drain(..n); }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
}

/// Read continuously; never queue a shot for a later turn or reconnect.
pub fn run(device: &mut RadarDevice, listener: TcpListener, sensor: SensorModel, swing: SwingConfig, log: &mut LiveLog) -> io::Result<()> {
    let mut detector = LiveDetector::new(sensor, swing);
    let result = run_loop(device, listener, &mut detector, log);
    reset_detector(&mut detector, log, "service_stopped", None, None, None)?;
    log.event("service_stopped", json!({"error":result.as_ref().err().map(ToString::to_string)}))?;
    log.checkpoint()?;
    result
}

fn reset_detector(detector: &mut LiveDetector, log: &mut LiveLog, reason: &str, arm: Option<&str>, frame: Option<u32>, debug: Option<&mut DebugFeed>) -> io::Result<()> {
    if let Some(report) = detector.detector.abort_report(reason) {
        if let Some(debug)=debug {debug.report(&report,log.elapsed_s());}
        log.complete_swing(report, arm, frame)?;
    }
    detector.reset();
    Ok(())
}

fn run_loop(device: &mut RadarDevice, listener: TcpListener, detector: &mut LiveDetector, log: &mut LiveLog) -> io::Result<()> {
    listener.set_nonblocking(true)?;
    let session = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
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
                eprintln!("Golf game connected: {address}");
                reset_detector(detector, log, "game_connected_or_replaced", client.as_ref().and_then(|c| c.arm.as_deref()), last_number, None)?;
                log.event("game_connected", json!({"address":address.to_string()}))?;
                client = Some(Client::new(socket)?);
                heartbeat = Instant::now() - Duration::from_secs(1);
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e),
        }
        if let Some(game) = client.as_mut() {
            let previous_arm = game.arm.clone();
            match game.poll() {
                Ok(true) => {
                    reset_detector(detector, log, "arm_changed", previous_arm.as_deref(), last_number, game.debug.as_mut())?;
                    log.event("arm_changed", json!({"previous_arm":previous_arm,"arm_id":game.arm}))?;
                }
                Ok(false) => {}
                Err(e) => {
                    eprintln!("Golf game disconnected: {e}");
                    reset_detector(detector, log, "game_disconnected", previous_arm.as_deref(), last_number, None)?;
                    log.event("game_disconnected", json!({"error":e.to_string()}))?;
                    client = None;
                }
            }
        }
        if let Some(game)=client.as_mut() {
            if game.debug_enabled {
                if game.debug.is_none() {
                    game.debug=Some(DebugFeed::new(log.directory.parent().unwrap().to_owned(),log.directory.clone()));
                    game.queue(json!({"type":"debug_info","protocol":1,"configuration":detector.configuration(),
                        "session_id":log.directory.file_name().unwrap().to_string_lossy(),"session_path":log.directory}))?;
                }
                for request in std::mem::take(&mut game.debug_requests) {
                    if request["type"]=="debug_mark" {
                        let report=&request["report"];
                        let valid_label=matches!(report["operator_label"].as_str(),Some("ball_hit"|"dry_swing"));
                        let start=report["start_time_s"].as_f64().unwrap_or(-1.0);
                        let end=report["end_time_s"].as_f64().unwrap_or(-1.0);
                        let session=log.directory.file_name().unwrap().to_string_lossy();
                        if valid_label && request["session_id"].as_str()==Some(session.as_ref()) && start>=0.0 && end>=start && end-start<=10.0 && end<=log.elapsed_s()
                            && report["operator_note"].as_str().is_some_and(|note|note.len()<=2048) {
                            let clean=json!({"outcome":"operator_mark","operator_label":report["operator_label"],"operator_note":report["operator_note"],
                                "start_frame":report["start_frame"],"end_frame":report["end_frame"],"start_time_s":start,"end_time_s":end,"tracks":[]});
                            log.event("operator_mark",json!({"report":clean,"end_frame":report["end_frame"]}))?;log.checkpoint()?;
                            game.queue(json!({"type":"debug_marked","request_id":request["request_id"],"label":report["operator_label"]}))?;
                        } else {game.queue(json!({"type":"debug_error","request_id":request["request_id"],"message":"Invalid or stale operator mark"}))?;}
                        continue;
                    }
                    if let Err(error)=game.debug.as_ref().unwrap().request(request.clone()) {
                        game.queue(json!({"type":"debug_error","request_id":request["request_id"],"message":error.to_string()}))?;
                    }
                }
            } else {game.debug=None;game.debug_requests.clear();}
        }
        let fresh = last_frame.is_some_and(|time| time.elapsed() < FRAME_TIMEOUT);
        if !fresh {
            if radar_was_fresh {
                log.event("frame_timeout", json!({"last_frame":last_number}))?;
                radar_was_fresh = false;
            }
            let arm=client.as_ref().and_then(|c|c.arm.clone());
            reset_detector(detector, log, "frame_timeout", arm.as_deref(), last_number, client.as_mut().and_then(|c|c.debug.as_mut()))?;
            if let Some(game) = client.as_mut() { game.arm = None; }
        }
        match device.read_data(&mut buffer) {
            Ok(n) => {
                // Capture the exact UART stream before parsing or any readiness gates.
                log.raw(&buffer[..n])?;
                decoder.push(&buffer[..n]);
            }
            Err(e) if matches!(e.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock) => {}
            Err(e) => return Err(e),
        }
        while let Some(packet) = decoder.next_packet() {
            let Some(frame) = parse_frame(&packet) else {
                log.event("packet_decode_failed", json!({"packet_length":packet.len()}))?;
                continue;
            };
            if let Some(number) = last_number {
                if frame.frame_number <= number {
                    log.event("frame_number_reset", json!({"previous":number,"current":frame.frame_number}))?;
                    let arm=client.as_ref().and_then(|c|c.arm.clone());
                    reset_detector(detector, log, "frame_number_reset", arm.as_deref(), Some(frame.frame_number), client.as_mut().and_then(|c|c.debug.as_mut()))?;
                } else if frame.frame_number.saturating_sub(number) > 1 {
                    log.event("frame_gap", json!({"previous":number,"current":frame.frame_number,"missing_frames":frame.frame_number-number-1}))?;
                }
            }
            last_number = Some(frame.frame_number);
            last_frame = Some(Instant::now());
            if !radar_was_fresh {
                radar_was_fresh = true;
                log.event("radar_frames_available", json!({"frame_number":frame.frame_number}))?;
            }
            let frame_data=json!({"arm_id":client.as_ref().and_then(|c| c.arm.as_deref()),
                "game_connected":client.is_some(), "detector_state":detector.state,
                "diagnostics":detector.detector.frame_diagnostics(&frame)});
            let timestamp=log.timed_event("frame",frame_data.clone())?;
            if let Some(game)=client.as_mut() {
                if let Some(debug)=game.debug.as_mut() {debug.frame(&frame_data,timestamp,&mut game.output);}
            }
            let Some(game) = client.as_mut() else { continue; };
            if game.arm.is_none() { continue; }
            let previous_state = detector.state;
            if let Some(mut shot) = detector.update(&frame) {
                sequence += 1;
                shot.shot_id = format!("live-{session}-{sequence}");
                log.event("shot_emitted", json!({"arm_id":game.arm,"frame_number":frame.frame_number,"shot":shot,"debug":game.debug_enabled}))?;
                if let Some(mut report) = detector.detector.take_report() {
                    report["selected_shot"] = json!(shot);
                    if let Some(debug)=game.debug.as_mut() {debug.report(&report,log.elapsed_s());}
                    log.complete_swing(report, game.arm.as_deref(), Some(frame.frame_number))?;
                }
                println!("{}", serde_json::to_string(&shot)?);
                if !game.debug_enabled {
                    let arm = game.arm.take().unwrap();
                    game.consumed_arm = Some(arm.clone());
                    game.queue(json!({"type":"shot", "arm_id":arm, "shot":shot}))?;
                    detector.reset();
                }
            } else if detector.state != previous_state {
                eprintln!("Radar: {}", detector.state);
                if detector.state == "swing_detected" {
                    log.begin_swing(frame.frame_number, game.arm.as_deref().unwrap())?;
                } else if let Some(report) = detector.detector.take_report() {
                    if let Some(debug)=game.debug.as_mut() {debug.report(&report,log.elapsed_s());}
                    log.complete_swing(report, game.arm.as_deref(), Some(frame.frame_number))?;
                }
                game.queue(json!({"type":"detection", "arm_id":game.arm, "state":detector.state}))?;
            }
        }
        if heartbeat.elapsed() >= Duration::from_millis(250) {
            heartbeat = Instant::now();
            if let Some(game) = client.as_mut() {
                let fresh = last_frame.is_some_and(|time| time.elapsed() < FRAME_TIMEOUT);
                game.queue(json!({"type":"status", "radar_ready":fresh, "protocol":1,
                    "arm_id":game.arm, "detection_state":detector.state,"debug":game.debug_enabled,
                    "debug_dropped_frames":game.debug.as_ref().map_or(0,|feed|feed.dropped_frames),
                    "debug_dropped_reports":game.debug.as_ref().map_or(0,|feed|feed.dropped_reports)}))?;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::radar::frame::RadarPoint;

    fn frame(number: u32, positions: &[f32]) -> RadarFrame {
        RadarFrame { frame_number: number, points: positions.iter().map(|&y| RadarPoint {
            x: 0.0, y, z: 0.0, radial_velocity: 10.0, side_info: None,
        }).collect() }
    }

    #[test]
    fn reset_discards_partial_shots_when_turn_is_revoked() {
        let commands = crate::radar::configuration::parse_config(include_str!("../configs/golf.cfg"));
        let mut detector = LiveDetector::new(SensorModel::from_commands(&commands).unwrap(), SwingConfig::default());
        detector.update(&frame(1, &[1.5]));
        for number in 2..=5 { detector.update(&frame(number, &[2.8 + (number - 2) as f32 * 0.2])); }
        detector.reset();
        for number in 6..25 { assert!(detector.update(&frame(number, &[])).is_none()); }
    }

    #[test]
    fn consumed_arm_cannot_be_rearmed_by_delayed_game_heartbeat() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut remote = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let mut client = Client::new(listener.accept().unwrap().0).unwrap();
        // Test split/coalesced NDJSON messages on a real TCP socket.
        remote.write_all(b"{\"type\":\"ready\",\"ready\":true,").unwrap();
        client.poll().unwrap();
        assert!(client.arm.is_none());
        remote.write_all(b"\"arm_id\":\"turn-1\"}\n").unwrap();
        for _ in 0..100 {
            client.poll().unwrap();
            if client.arm.is_some() { break; }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(client.arm.as_deref(), Some("turn-1"));
        client.consumed_arm = client.arm.take();
        remote.write_all(b"{\"type\":\"ready\",\"ready\":true,\"arm_id\":\"turn-1\"}\n").unwrap();
        for _ in 0..20 { client.poll().unwrap(); std::thread::sleep(Duration::from_millis(1)); }
        assert!(client.arm.is_none());
        remote.write_all(b"{\"type\":\"ready\",\"ready\":false}\n{\"type\":\"ready\",\"ready\":true,\"arm_id\":\"turn-2\"}\n").unwrap();
        for _ in 0..100 {
            client.poll().unwrap();
            if client.arm.is_some() { break; }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(client.arm.as_deref(), Some("turn-2"));
    }
}
