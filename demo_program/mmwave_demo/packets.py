import struct


MAGIC_WORD = b"\x02\x01\x04\x03\x06\x05\x08\x07"

# mmWave SDK demo packet header:
# magicWord[4] uint16 + 8 uint32 fields = 40 bytes
HEADER_STRUCT = struct.Struct("<4H8I")
TLV_HEADER_STRUCT = struct.Struct("<II")


TLV_NAMES = {
    1: "Detected points",
    2: "Range profile",
    3: "Noise profile",
    4: "Azimuth static heatmap",
    5: "Range-Doppler heatmap",
    6: "Statistics",
    7: "Side info for detected points",
    8: "Azimuth/elevation static heatmap",
    9: "Temperature statistics",
}


def parse_packet(packet: bytes):
    """
    Parse one full mmWave SDK demo packet.

    The firmware has already done object detection. This parser only decodes the
    binary packet header and TLV payloads that the firmware sends over DATA UART.
    """

    if not packet.startswith(MAGIC_WORD):
        raise ValueError("Packet does not start with magic word")

    header = HEADER_STRUCT.unpack_from(packet, 0)

    version = header[4]
    total_packet_len = header[5]
    platform = header[6]
    frame_number = header[7]
    time_cpu_cycles = header[8]
    num_detected_obj = header[9]
    num_tlvs = header[10]
    subframe_number = header[11]

    tlvs = []
    offset = HEADER_STRUCT.size

    for _ in range(num_tlvs):
        if offset + TLV_HEADER_STRUCT.size > len(packet):
            break

        tlv_type, tlv_length = TLV_HEADER_STRUCT.unpack_from(packet, offset)
        offset += TLV_HEADER_STRUCT.size

        payload_start = offset
        payload_end = offset + tlv_length

        if payload_end > len(packet):
            break

        payload = packet[payload_start:payload_end]

        tlvs.append({
            "type": tlv_type,
            "name": TLV_NAMES.get(tlv_type, "Unknown"),
            "length": tlv_length,
            "payload": payload,
        })

        offset = payload_end

    return {
        "version": version,
        "total_packet_len": total_packet_len,
        "platform": platform,
        "frame_number": frame_number,
        "time_cpu_cycles": time_cpu_cycles,
        "num_detected_obj": num_detected_obj,
        "num_tlvs": num_tlvs,
        "subframe_number": subframe_number,
        "tlvs": tlvs,
    }


def parse_detected_points(tlv_payload: bytes):
    """
    Parse TLV type 1 detected points.

    Each point is x, y, z, doppler as float32, 16 bytes total.
    """

    points = []
    point_struct = struct.Struct("<ffff")
    count = len(tlv_payload) // point_struct.size

    for i in range(count):
        x, y, z, doppler = point_struct.unpack_from(tlv_payload, i * point_struct.size)
        points.append({
            "x": x,
            "y": y,
            "z": z,
            "doppler": doppler,
        })

    return points


def tlv_summary(tlvs):
    return "; ".join(
        f"{tlv['type']}:{tlv['name']}({tlv['length']} bytes)"
        for tlv in tlvs
    )
