//! Live serial -> frame -> track -> shot, served as newline-delimited JSON over TCP.
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use crate::processing::detection::{DetectionConfig, detect_candidates};
use crate::processing::estimation::ShotOutput;
use crate::processing::tracking::{BallTrack, BallTracker, TrackingConfig};
use crate::radar::analysis::select_shot;
use crate::radar::device::RadarDevice;
use crate::radar::frame::RadarFrame;
use crate::radar::protocol::{PacketDecoder, parse_frame};

const FRAME_TIMEOUT: Duration = Duration::from_secs(1);

pub struct LiveDetector {
    tracker: BallTracker,
    completed: Vec<BallTrack>,
    detection: DetectionConfig,
    tracking: TrackingConfig,
    burst_start: Option<u32>,
    cooldown_until: f64,
}

impl LiveDetector {
    pub fn new(frame_period_s: f64) -> Self {
        Self {
            tracker: BallTracker::new(), completed: Vec::new(),
            detection: DetectionConfig { min_distance_m: 0.2, max_distance_m: 4.0,
                min_radial_speed_mps: 2.0, min_snr_db: 10.0 },
            tracking: TrackingConfig { frame_period_s, ..TrackingConfig::default() },
            burst_start: None, cooldown_until: 0.0,
        }
    }

    pub fn reset(&mut self) {
        self.tracker = BallTracker::new();
        self.completed.clear();
        self.burst_start = None;
        self.cooldown_until = 0.0;
    }

    pub fn update(&mut self, frame: &RadarFrame) -> Option<ShotOutput> {
        let now = frame.frame_number as f64 * self.tracking.frame_period_s;
        if now < self.cooldown_until { return None; }
        let candidates = detect_candidates(frame, &self.detection);
        if !candidates.is_empty() && self.burst_start.is_none() {
            self.burst_start = Some(frame.frame_number);
        }
        self.tracker.update(frame, &candidates, &self.tracking);
        self.completed.extend(self.tracker.take_completed_tracks());
        let start = self.burst_start?;
        // Wait for the short ball track to end, then choose one best track for
        // this swing. Cap the burst so persistent clutter cannot grow forever.
        let elapsed = frame.frame_number.saturating_sub(start) as f64 * self.tracking.frame_period_s;
        if !self.tracker.active_tracks().is_empty() && elapsed < 0.5 { return None; }
        self.tracker.finish();
        self.completed.extend(self.tracker.take_completed_tracks());
        let shot = select_shot(&self.completed);
        self.reset();
        self.cooldown_until = now + 0.5;
        shot
    }
}

struct Client {
    socket: TcpStream,
    input: Vec<u8>,
    output: Vec<u8>,
    arm: Option<String>,
    consumed_arm: Option<String>,
    last_heard: Instant,
}

impl Client {
    fn new(socket: TcpStream) -> io::Result<Self> {
        socket.set_nonblocking(true)?;
        socket.set_nodelay(true)?;
        Ok(Self { socket, input: Vec::new(), output: Vec::new(), arm: None, consumed_arm: None, last_heard: Instant::now() })
    }

    fn queue(&mut self, message: Value) -> io::Result<()> {
        if self.output.len() > 65536 { return Err(io::Error::other("Game is not reading events")); }
        self.output.extend(serde_json::to_vec(&message)?);
        self.output.push(b'\n');
        Ok(())
    }

    fn poll(&mut self) -> io::Result<bool> {
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
pub fn run(device: &mut RadarDevice, listener: TcpListener, frame_period_s: f64) -> io::Result<()> {
    listener.set_nonblocking(true)?;
    let session = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    let mut sequence = 0u64;
    let mut decoder = PacketDecoder::new();
    let mut detector = LiveDetector::new(frame_period_s);
    let mut client: Option<Client> = None;
    let mut last_frame: Option<Instant> = None;
    let mut last_number: Option<u32> = None;
    let mut heartbeat = Instant::now() - Duration::from_secs(1);
    let mut buffer = [0; 8192];
    loop {
        match listener.accept() {
            Ok((socket, address)) => {
                eprintln!("Golf game connected: {address}");
                client = Some(Client::new(socket)?);
                detector.reset(); heartbeat = Instant::now() - Duration::from_secs(1);
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e),
        }
        if let Some(game) = client.as_mut() {
            match game.poll() {
                Ok(true) => detector.reset(),
                Ok(false) => {}
                Err(e) => { eprintln!("Golf game disconnected: {e}"); client = None; detector.reset(); }
            }
        }
        let fresh = last_frame.is_some_and(|time| time.elapsed() < FRAME_TIMEOUT);
        if !fresh {
            detector.reset();
            if let Some(game) = client.as_mut() { game.arm = None; }
        }
        match device.read_data(&mut buffer) {
            Ok(n) => decoder.push(&buffer[..n]),
            Err(e) if matches!(e.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock) => {}
            Err(e) => return Err(e),
        }
        while let Some(packet) = decoder.next_packet() {
            let Some(frame) = parse_frame(&packet) else { continue; };
            if last_number.is_some_and(|number| frame.frame_number <= number) { detector.reset(); }
            last_number = Some(frame.frame_number);
            last_frame = Some(Instant::now());
            let Some(game) = client.as_mut() else { continue; };
            if game.arm.is_none() { continue; }
            if let Some(mut shot) = detector.update(&frame) {
                sequence += 1;
                shot.shot_id = format!("live-{session}-{sequence}");
                println!("{}", serde_json::to_string(&shot)?);
                let arm = game.arm.take().unwrap();
                game.consumed_arm = Some(arm.clone());
                game.queue(json!({"type":"shot", "arm_id":arm, "shot":shot}))?;
                detector.reset();
            }
        }
        if heartbeat.elapsed() >= Duration::from_millis(250) {
            heartbeat = Instant::now();
            if let Some(game) = client.as_mut() {
                let fresh = last_frame.is_some_and(|time| time.elapsed() < FRAME_TIMEOUT);
                game.queue(json!({"type":"status", "radar_ready":fresh, "protocol":1, "arm_id":game.arm}))?;
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
    fn emits_one_best_shot_per_burst_and_rearms_for_next_swing() {
        let mut detector = LiveDetector::new(0.02);
        // Two reflections from one swing must yield one shot, not two.
        for number in 1..=3 {
            assert!(detector.update(&frame(number, &[1.0 + number as f32 * 0.2,
                2.5 + number as f32 * 0.1])).is_none());
        }
        let mut shots = Vec::new();
        for number in 4..40 {
            if let Some(shot) = detector.update(&frame(number, &[])) { shots.push(shot); }
        }
        assert_eq!(shots.len(), 1);
        assert!((shots[0].speed_mps - 10.0).abs() < 0.001);
        for number in 40..43 {
            assert!(detector.update(&frame(number, &[1.0 + (number - 40) as f32 * 0.3])).is_none());
        }
        let mut count = 0;
        for number in 43..50 { count += usize::from(detector.update(&frame(number, &[])).is_some()); }
        assert_eq!(count, 1);
    }

    #[test]
    fn reset_discards_partial_shots_when_turn_is_revoked() {
        let mut detector = LiveDetector::new(0.02);
        for number in 1..=3 { detector.update(&frame(number, &[1.0 + number as f32 * 0.2])); }
        detector.reset();
        for number in 4..20 { assert!(detector.update(&frame(number, &[])).is_none()); }
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
