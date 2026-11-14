//! Continuous frame acquisition with the golf game's TCP status protocol.
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::radar::device::RadarDevice;
use crate::radar::protocol::{PacketDecoder, parse_frame};

const FRAME_TIMEOUT: Duration = Duration::from_secs(1);

struct Client {
    socket: TcpStream,
    input: Vec<u8>,
    output: Vec<u8>,
    arm: Option<String>,
    last_heard: Instant,
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
            last_heard: Instant::now(),
        })
    }

    fn queue(&mut self, message: Value) -> io::Result<()> {
        if self.output.len() > 65536 {
            return Err(io::Error::other("Game is not reading events"));
        }
        self.output.extend(serde_json::to_vec(&message)?);
        self.output.push(b'\n');
        Ok(())
    }

    fn poll(&mut self) -> io::Result<()> {
        let mut buffer = [0; 4096];
        loop {
            match self.socket.read(&mut buffer) {
                Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
                Ok(n) => self.input.extend_from_slice(&buffer[..n]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
            if self.input.len() > 65536 {
                return Err(io::Error::other("Oversized game message"));
            }
        }
        while let Some(end) = self.input.iter().position(|&b| b == b'\n') {
            let line: Vec<_> = self.input.drain(..=end).collect();
            let message: Value = serde_json::from_slice(&line)?;
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
            self.arm = arm;
        }
        if self.last_heard.elapsed() > Duration::from_secs(3) {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Game heartbeat stopped",
            ));
        }
        self.flush()
    }

    fn flush(&mut self) -> io::Result<()> {
        while !self.output.is_empty() {
            match self.socket.write(&self.output) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(n) => {
                    self.output.drain(..n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
}

/// Read and decode frames continuously, independently of the game's ready turn.
/// Status reports frame freshness only; no detection or shot events are produced.
pub fn run(device: &mut RadarDevice, listener: TcpListener) -> io::Result<()> {
    listener.set_nonblocking(true)?;
    let mut decoder = PacketDecoder::new();
    let mut client: Option<Client> = None;
    let mut last_frame: Option<Instant> = None;
    let mut heartbeat = Instant::now() - Duration::from_secs(1);
    let mut buffer = [0; 8192];
    loop {
        match listener.accept() {
            Ok((socket, address)) => {
                eprintln!("Golf game connected: {address}");
                client = Some(Client::new(socket)?);
                heartbeat = Instant::now() - Duration::from_secs(1);
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e),
        }
        if let Some(game) = client.as_mut() {
            if let Err(e) = game.poll() {
                eprintln!("Golf game disconnected: {e}");
                client = None;
            }
        }
        let fresh = last_frame.is_some_and(|time| time.elapsed() < FRAME_TIMEOUT);
        if !fresh {
            if let Some(game) = client.as_mut() {
                game.arm = None;
            }
        }
        match device.read_data(&mut buffer) {
            Ok(n) => decoder.push(&buffer[..n]),
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) => {}
            Err(e) => return Err(e),
        }
        while let Some(packet) = decoder.next_packet() {
            let Some(_frame) = parse_frame(&packet) else {
                continue;
            };
            last_frame = Some(Instant::now());
            // Decoded RadarFrame is available here for future frame handling.
        }
        if heartbeat.elapsed() >= Duration::from_millis(250) {
            heartbeat = Instant::now();
            if let Some(game) = client.as_mut() {
                let fresh = last_frame.is_some_and(|time| time.elapsed() < FRAME_TIMEOUT);
                game.queue(
                    json!({"type":"status", "radar_ready":fresh, "protocol":1, "arm_id":game.arm}),
                )?;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn receives_fragmented_readiness_and_turn_changes() {
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
        remote
            .write_all(b"{\"type\":\"ready\",\"ready\":false}\n")
            .unwrap();
        for _ in 0..100 {
            client.poll().unwrap();
            if client.arm.is_none() {
                break;
            }
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
