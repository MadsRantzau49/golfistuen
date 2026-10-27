use crate::radar::frame::{PointSideInfo, RadarFrame, RadarPoint};

pub const MAGIC_WORD: [u8; 8] = [0x02, 0x01, 0x04, 0x03, 0x06, 0x05, 0x08, 0x07];

pub const HEADER_SIZE: usize = 40;

#[derive(Debug, PartialEq)]
pub struct PacketHeader {
    pub total_packet_len: u32,
    pub frame_number: u32,
    pub num_detected_objects: u32,
    pub num_tlvs: u32,
}

pub struct PacketDecoder {
    buffer: Vec<u8>,
}

pub fn parse_side_info(bytes: &[u8]) -> Option<PointSideInfo> {
    if bytes.len() != 4 {
        return None;
    }

    let snr = i16::from_le_bytes(bytes[0..2].try_into().ok()?);

    let noise = i16::from_le_bytes(bytes[2..4].try_into().ok()?);

    Some(PointSideInfo {
        snr_db: snr as f32 / 10.0,
        noise_db: noise as f32 / 10.0,
    })
}

pub fn parse_frame(packet: &[u8]) -> Option<RadarFrame> {
    let header = parse_header(packet)?;

    if packet.len() != header.total_packet_len as usize {
        return None;
    }

    let mut offset = HEADER_SIZE;
    let mut points = Vec::new();
    let mut found_points_tlv = false;
    let mut side_info: Option<Vec<PointSideInfo>> = None;

    for _ in 0..header.num_tlvs {
        if packet.len().checked_sub(offset)? < 8 {
            return None;
        }

        let tlv_type = u32::from_le_bytes(packet[offset..offset + 4].try_into().ok()?);

        let tlv_length =
            u32::from_le_bytes(packet[offset + 4..offset + 8].try_into().ok()?) as usize;

        offset += 8;

        let end = offset.checked_add(tlv_length)?;

        if end > packet.len() {
            return None;
        }

        let payload = &packet[offset..end];

        match tlv_type {
            1 => {
                if found_points_tlv {
                    return None;
                }

                points = parse_detected_points(payload)?;
                found_points_tlv = true;
            }

            7 => {
                if side_info.is_some() {
                    return None;
                }

                side_info = Some(parse_side_info_list(payload)?);
            }
            _ => {}
        }
        offset = end;
    }

    if found_points_tlv {
        if points.len() != header.num_detected_objects as usize {
            return None;
        }
    } else if header.num_detected_objects != 0 {
        return None;
    }

    if let Some(infos) = side_info {
        if infos.len() != points.len() {
            return None;
        }
        for (point, info) in points.iter_mut().zip(infos) {
            point.side_info = Some(info);
        }
    }

    Some(RadarFrame {
        frame_number: header.frame_number,
        points,
    })
}

pub fn parse_point(bytes: &[u8]) -> Option<RadarPoint> {
    if bytes.len() != 16 {
        return None;
    }

    let x = f32::from_le_bytes(bytes[0..4].try_into().ok()?);

    let y = f32::from_le_bytes(bytes[4..8].try_into().ok()?);

    let z = f32::from_le_bytes(bytes[8..12].try_into().ok()?);

    let radial_velocity = f32::from_le_bytes(bytes[12..16].try_into().ok()?);

    let side_info = None;
    Some(RadarPoint {
        x,
        y,
        z,
        radial_velocity,
        side_info,
    })
}

pub fn parse_side_info_list(payload: &[u8]) -> Option<Vec<PointSideInfo>> {
    if payload.len() % 4 != 0 {
        return None;
    }

    let mut result = Vec::new();

    for chunk in payload.chunks_exact(4) {
        result.push(parse_side_info(chunk)?);
    }

    Some(result)
}

pub fn parse_detected_points(payload: &[u8]) -> Option<Vec<RadarPoint>> {
    if payload.len() % 16 != 0 {
        return None;
    }

    let mut points = Vec::new();

    for chunk in payload.chunks(16) {
        let point = parse_point(chunk)?;
        points.push(point);
    }
    Some(points)
}

pub fn parse_header(bytes: &[u8]) -> Option<PacketHeader> {
    if bytes.len() < HEADER_SIZE {
        return None;
    }

    if !bytes.starts_with(&MAGIC_WORD) {
        return None;
    }

    let total_packet_len = u32::from_le_bytes(bytes[12..16].try_into().ok()?);

    let frame_number = u32::from_le_bytes(bytes[20..24].try_into().ok()?);

    let num_detected_objects = u32::from_le_bytes(bytes[28..32].try_into().ok()?);

    let num_tlvs = u32::from_le_bytes(bytes[32..36].try_into().ok()?);

    Some(PacketHeader {
        total_packet_len,
        frame_number,
        num_detected_objects,
        num_tlvs,
    })
}

impl PacketDecoder {
    pub fn new() -> Self {
        Self { buffer: Vec::new() }
    }

    pub fn push(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    pub fn next_packet(&mut self) -> Option<Vec<u8>> {
        self.buffer
            .windows(MAGIC_WORD.len())
            .position(|window| window == MAGIC_WORD);

        if self.buffer.len() < HEADER_SIZE {
            return None;
        }

        let header = parse_header(&self.buffer)?;

        let packet_length = header.total_packet_len as usize;

        if self.buffer.len() < packet_length {
            return None;
        }

        let packet: Vec<u8> = self.buffer.drain(..packet_length).collect();

        return Some(packet);
    }
}

#[test]
fn decodes_packet_split_across_reads() {
    let mut decoder = PacketDecoder::new();

    let mut packet = vec![0u8; 256];

    packet[..8].copy_from_slice(&MAGIC_WORD);
    packet[12..16].copy_from_slice(&256u32.to_le_bytes());
    packet[20..24].copy_from_slice(&42u32.to_le_bytes());

    // Receive only the first 20 bytes
    decoder.push(&packet[..20]);

    // Not enough data yet
    assert!(decoder.next_packet().is_none());

    // Receive the remaining bytes
    decoder.push(&packet[20..]);

    // Complete packet should now be available
    let decoded = decoder.next_packet().unwrap();

    assert_eq!(decoded, packet);

    // No additional packets
    assert!(decoder.next_packet().is_none());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_header() {
        let mut bytes = [0u8; 40];

        // Magic word
        bytes[0..8].copy_from_slice(&MAGIC_WORD);

        // Packet length = 256
        bytes[12..16].copy_from_slice(&256u32.to_le_bytes());

        // Frame number = 42
        bytes[20..24].copy_from_slice(&42u32.to_le_bytes());

        let header = parse_header(&bytes).unwrap();

        assert_eq!(header.total_packet_len, 256);
        assert_eq!(header.frame_number, 42);
    }

    #[test]
    fn rejects_incomplete_header() {
        let bytes = [0u8; 20];

        assert!(parse_header(&bytes).is_none());
    }

    #[test]
    fn rejects_invalid_magic_word() {
        let bytes = [0u8; 40];

        assert!(parse_header(&bytes).is_none());
    }
}

#[test]
fn parses_radar_point() {
    let values = [1.5f32, 2.0, 0.5, -3.2];

    let mut bytes = Vec::new();

    for value in values {
        bytes.extend_from_slice(&value.to_le_bytes());
    }

    let point = parse_point(&bytes).expect("Valid radar point should be parsed");

    assert_eq!(point.x, 1.5);
    assert_eq!(point.y, 2.0);
    assert_eq!(point.z, 0.5);
    assert_eq!(point.radial_velocity, -3.2);
}

#[test]
fn parses_multiple_detected_points() {
    let mut payload = Vec::new();

    let values = [[1.0f32, 2.0, 3.0, 4.0], [5.0f32, 6.0, 7.0, 8.0]];

    for point in values {
        for value in point {
            payload.extend_from_slice(&value.to_le_bytes());
        }
    }

    let points = parse_detected_points(&payload).unwrap();

    assert_eq!(points.len(), 2);

    assert_eq!(points[0].x, 1.0);
    assert_eq!(points[0].y, 2.0);
    assert_eq!(points[0].z, 3.0);
    assert_eq!(points[0].radial_velocity, 4.0);

    assert_eq!(points[1].x, 5.0);
    assert_eq!(points[1].radial_velocity, 8.0);
}

#[test]
fn rejects_invalid_point_payload() {
    let payload = [0u8; 25];

    assert!(parse_detected_points(&payload).is_none());
}

#[test]
fn accepts_empty_point_payload() {
    let points = parse_detected_points(&[]).unwrap();

    assert!(points.is_empty());
}

#[test]
fn parses_complete_radar_frame() {
    let mut packet = vec![0u8; 64];

    // Packet header
    packet[0..8].copy_from_slice(&MAGIC_WORD);
    packet[12..16].copy_from_slice(&64u32.to_le_bytes());
    packet[20..24].copy_from_slice(&42u32.to_le_bytes());

    // One detected object
    packet[28..32].copy_from_slice(&1u32.to_le_bytes());

    // One TLV
    packet[32..36].copy_from_slice(&1u32.to_le_bytes());

    // TLV header: type 1, payload length 16
    packet[40..44].copy_from_slice(&1u32.to_le_bytes());
    packet[44..48].copy_from_slice(&16u32.to_le_bytes());

    // Radar point
    let values = [0.5f32, 2.0, 0.3, 12.0];

    for (index, value) in values.iter().enumerate() {
        let start = 48 + index * 4;
        packet[start..start + 4].copy_from_slice(&value.to_le_bytes());
    }

    let frame = parse_frame(&packet).unwrap();

    assert_eq!(frame.frame_number, 42);
    assert_eq!(frame.points.len(), 1);

    let point = &frame.points[0];

    assert_eq!(point.x, 0.5);
    assert_eq!(point.y, 2.0);
    assert_eq!(point.z, 0.3);
    assert_eq!(point.radial_velocity, 12.0);
}

#[test]
fn parses_side_information() {
    let mut bytes = Vec::new();

    // SNR = 25.3 dB
    bytes.extend_from_slice(&253i16.to_le_bytes());

    // Noise = 12.1 dB
    bytes.extend_from_slice(&121i16.to_le_bytes());

    let info = parse_side_info(&bytes).unwrap();

    assert!((info.snr_db - 25.3).abs() < 0.001);
    assert!((info.noise_db - 12.1).abs() < 0.001);
}

#[test]
fn rejects_invalid_side_information() {
    assert!(parse_side_info(&[0u8; 3]).is_none());
}

#[test]
fn rejects_mismatched_side_info_count() {
    // Packet layout:
    // 40 bytes: packet header
    // 8 bytes:  detected points TLV header
    // 32 bytes: two radar points
    // 8 bytes:  side information TLV header
    // 4 bytes:  one side information entry
    // 4 bytes:  padding
    // Total:     96 bytes

    let mut packet = vec![0u8; 96];

    // Packet header
    packet[0..8].copy_from_slice(&MAGIC_WORD);
    packet[12..16].copy_from_slice(&96u32.to_le_bytes());
    packet[20..24].copy_from_slice(&42u32.to_le_bytes());

    // Two detected objects
    packet[28..32].copy_from_slice(&2u32.to_le_bytes());

    // Two TLVs
    packet[32..36].copy_from_slice(&2u32.to_le_bytes());

    // TLV 1: Detected points
    packet[40..44].copy_from_slice(&1u32.to_le_bytes());
    packet[44..48].copy_from_slice(&32u32.to_le_bytes());

    // Two points, each containing x, y, z, velocity
    let points = [
        [0.5f32, 2.0, 0.3, 12.0],
        [0.6f32, 2.2, 0.4, 13.0],
    ];

    for (index, point) in points.iter().enumerate() {
        for (field, value) in point.iter().enumerate() {
            let offset = 48 + index * 16 + field * 4;

            packet[offset..offset + 4]
                .copy_from_slice(&value.to_le_bytes());
        }
    }

    // TLV 7: Side information
    packet[80..84].copy_from_slice(&7u32.to_le_bytes());
    packet[84..88].copy_from_slice(&4u32.to_le_bytes());

    // Only ONE side information entry (should be TWO)
    packet[88..90].copy_from_slice(&253i16.to_le_bytes()); // SNR: 25.3 dB
    packet[90..92].copy_from_slice(&121i16.to_le_bytes()); // Noise: 12.1 dB

    // The packet must be rejected because the counts differ
    assert!(parse_frame(&packet).is_none());
}
