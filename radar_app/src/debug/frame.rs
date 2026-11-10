use std::io;

use crate::radar::device::RadarDevice;
use crate::radar::protocol::{PacketDecoder, parse_frame};

pub fn print_frames(device: &mut RadarDevice, min_velocity: f32) -> io::Result<()>{

    let mut decoder = PacketDecoder::new();
    let mut buffer = [0u8; 8192];

    loop {
        match device.read_data(&mut buffer) {
            Ok(0) => continue,

            Ok(n) => {
                decoder.push(&buffer[..n]);

                while let Some(packet) = decoder.next_packet() {
                    match parse_frame(&packet) {
                        Some(frame) => {
                            let points = frame.points;

                            if points.is_empty(){
                                continue;
                            }
                            for point in &points{
                                if point.radial_velocity > min_velocity{
                                    println!("\n{point:?}\n");
                                } else {
                                    print!("-Slow-");
                                }
                            }                            
                        },
                        None => eprintln!("Failed to decode frame"),
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::TimedOut => {
                continue;
            }
            Err(error)  => return Err(error),
        }
    }
}