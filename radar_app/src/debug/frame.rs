use std::io;

use crate::radar::device::RadarDevice;
use crate::radar::protocol::{PacketDecoder, parse_frame};

pub fn print_frames(device: &mut RadarDevice) -> io::Result<()>{

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
                                if point.radial_velocity > 10.0{
                                    println!("{point:?}");
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