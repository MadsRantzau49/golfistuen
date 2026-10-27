"""TI xWR68xx SDK 3.x OOB decoding and offline exports for the radar workbench.

Payload-only TLV lengths, 40-byte headers, arbitrary UART padding.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import statistics
import struct
from collections import Counter
from pathlib import Path

MAGIC = bytes.fromhex("0201040306050807")
HEADER = struct.Struct("<8I")
MAX_PACKET = 16 * 1024 * 1024


def parse_config(text: str) -> dict:
    rows = [line.split('%', 1)[0].split('#', 1)[0].split() for line in text.splitlines()]
    rows = [r for r in rows if r]
    def last(name):
        found = [r for r in rows if r[0] == name]
        if not found:
            raise ValueError(f"Configuration is missing {name}.")
        return found[-1]
    if last('dfeDataOutputMode')[1:] != ['1']:
        raise ValueError('Only normal frame mode (dfeDataOutputMode 1) is supported.')
    frame = last('frameCfg')
    if len(frame) != 8:
        raise ValueError('frameCfg must have seven arguments.')
    first, end, loops = map(int, frame[1:4])
    period = float(frame[5])
    if first < 0 or end < first or end > 511 or loops < 1 or not math.isfinite(period) or period <= 0:
        raise ValueError('Invalid chirp indices, loops or frame period.')
    channel = last('channelCfg')
    rx, tx = int(channel[1]), int(channel[2])
    chirps = {}
    for r in rows:
        if r[0] == 'chirpCfg' and len(r) == 9:
            for i in range(max(first, int(r[1])), min(end, int(r[2])) + 1):
                chirps[i] = r
    if any(i not in chirps for i in range(first, end + 1)):
        raise ValueError('A chirp used by frameCfg has no chirpCfg definition.')
    selected = [chirps[i] for i in range(first, end + 1)]
    masks = [int(r[8]) for r in selected]
    if any(m & ~tx for m in masks):
        raise ValueError('A chirp uses a transmitter disabled in channelCfg.')
    profiles = {int(r[1]): r for r in rows if r[0] == 'profileCfg' and len(r) == 15}
    ids = {int(r[3]) for r in selected}
    if any(i not in profiles for i in ids):
        raise ValueError('The chirp references an undefined profileCfg.')
    warnings = []
    result = dict(frame_period_ms=period, frame_rate_hz=1000/period, loops=loops,
                  chirps_per_loop=len(selected), chirps_per_frame=len(selected)*loops,
                  enabled_rx=rx.bit_count(), enabled_tx=tx.bit_count(), active_tx=len(set(masks)), warnings=warnings)
    for kind, name in [('0', 'range_filter_m'), ('1', 'velocity_filter_mps')]:
        found = [r for r in rows if r[0] == 'cfarFovCfg' and len(r) == 5 and r[2] == kind and r[1] in ('-1','0')]
        result[name] = list(map(float, found[-1][3:])) if found else None
    bpm = any(r[0] == 'bpmCfg' and len(r) > 2 and r[2] != '0' for r in rows)
    simple = len(ids) == 1 and len(set(masks)) == len(masks) and not bpm and loops & (loops-1) == 0
    simple = simple and all(m > 0 and m & (m-1) == 0 for m in masks) and all(all(float(v) == 0 for v in r[4:8]) for r in selected)
    result['elevation_supported'] = bool(tx == 7 and set(masks) == {1,2,4} and not bpm)
    if simple:
        p = profiles[next(iter(ids))]
        if not all(math.isfinite(float(v)) for v in p[1:]):
            raise ValueError('Non-finite profile parameter.')
        start, idle, adc_start, ramp = map(float, p[2:6])
        slope, samples, rate = float(p[8]), int(p[10]), float(p[11])
        if min(start, ramp, slope, samples, rate) <= 0 or min(idle, adc_start) < 0:
            raise ValueError('Invalid profile timing or ADC sampling parameters.')
        window = samples/rate*1000
        cycle = idle+ramp
        center = start+slope*(adc_start+window/2)/1000
        vmax = 299792458/(center*1e9)/(4*cycle*1e-6*len(masks))
        active = cycle*len(selected)*loops/1000
        result.update(chirp_cycle_us=cycle, adc_window_us=window, center_frequency_ghz=center,
                      active_chirp_time_ms=active, max_unambiguous_radial_mps=vmax,
                      doppler_bin_mps=2*vmax/loops, range_resolution_m=299792458/(2*slope*1e12*window*1e-6),
                      duty_cycle_percent=100*active/period)
        if adc_start+window > ramp+.01:
            warnings.append('ADC sampling extends beyond the configured ramp.')
        if active > period/2:
            warnings.append("Active chirp time exceeds the SDK demo's 50% frame duty-cycle guidance.")
        vf = result['velocity_filter_mps']
        if vf and max(map(abs, vf)) > vmax:
            warnings.append(f'Velocity filter {vf[0]:g} to {vf[1]:g} m/s exceeds the calculated basic limit of about ±{vmax:.2f} m/s. Faster motion may alias.')
    else:
        warnings.append('Speed/range estimate unavailable: unsupported chirp/BPM/Doppler arrangement.')
    if any(r[0] == 'extendedMaxVelocity' and r[-1] != '0' for r in rows):
        warnings.append('Extended velocity enabled; the estimate describes basic TDM ambiguity only.')
    return result


def decode_stream(data: bytes, config: dict) -> tuple[list[dict], dict]:
    frames, types, unknown = [], Counter(), Counter()
    diagnostic = dict(file_bytes=len(data), skipped_bytes=0, trailing_bytes=0, malformed_packets=0,
                      missing_frames=0, duplicate_frames=0, counter_discontinuities=0)
    offset = ticks = 0
    while offset < len(data):
        start = data.find(MAGIC, offset)
        if start < 0:
            diagnostic['trailing_bytes'] += len(data)-offset
            break
        diagnostic['skipped_bytes'] += start-offset
        if len(data)-start < 40:
            diagnostic['trailing_bytes'] += len(data)-start
            break
        version, size, platform, number, cycles, n, ntlv, subframe = HEADER.unpack_from(data, start+8)
        if version >> 24 != 3 or platform != 0xA6843:
            raise ValueError(f'Unsupported firmware/platform at byte {start}: expected xWR68xx SDK 3.x OOB.')
        if subframe != 0:
            raise ValueError('Advanced subframes are not supported.')
        if size < 40 or size > MAX_PACKET or ntlv > 128 or n > 100000:
            diagnostic['malformed_packets'] += 1
            diagnostic['skipped_bytes'] += 1
            offset = start+1
            continue
        if start+size > len(data):
            if data.find(MAGIC, start+8) < 0:
                diagnostic['trailing_bytes'] += len(data)-start
                break
            diagnostic['malformed_packets'] += 1
            diagnostic['skipped_bytes'] += 1
            offset = start+1
            continue
        cursor, points, side, packet_types, stats = start+40, None, None, [], None
        try:
            for _ in range(ntlv):
                if cursor+8 > start+size:
                    raise ValueError('Truncated TLV header')
                typ, length = struct.unpack_from('<II', data, cursor)
                cursor += 8
                if length > start+size-cursor:
                    raise ValueError('TLV exceeds packet boundary')
                packet_types.append(typ)
                if typ == 1:
                    if points is not None or length != 16*n:
                        raise ValueError('Detected-points count mismatch')
                    points = []
                    for i in range(n):
                        x,y,z,v = struct.unpack_from('<4f', data, cursor+16*i)
                        if not all(map(math.isfinite,(x,y,z,v))):
                            raise ValueError('Non-finite point')
                        points.append(dict(x=x,y=y,z=z,v=v,range=math.hypot(x,y,z),snr=None,noise=None))
                elif typ == 7:
                    if side is not None or length != 4*n:
                        raise ValueError('Side-information count mismatch')
                    side = [struct.unpack_from('<hh',data,cursor+4*i) for i in range(n)]
                elif typ == 6:
                    if length != 24:
                        raise ValueError('Stats length mismatch')
                    stats = list(struct.unpack_from('<6I',data,cursor))
                cursor += length
            if points is None and n:
                raise ValueError('Missing points TLV')
            points = points or []
            if side is not None:
                for point, (snr,noise) in zip(points,side):
                    point.update(snr=snr/10,noise=noise/10)
        except (ValueError, struct.error):
            diagnostic['malformed_packets'] += 1
            diagnostic['skipped_bytes'] += 1
            offset = start+1
            continue
        if frames:
            delta = (number-frames[-1]['number']) & 0xFFFFFFFF
            if delta == 0:
                diagnostic['duplicate_frames'] += 1
            elif delta < 1000000:
                diagnostic['missing_frames'] += delta-1
                ticks += delta
            else:
                diagnostic['counter_discontinuities'] += 1
                ticks += 1
        frames.append(dict(number=number,t=ticks*config['frame_period_ms']/1000,cycles=cycles,points=points,
                           stats=stats,packet_bytes=size,offset=start,
                           version='.'.join(str((version>>s)&255) for s in (24,16,8,0))))
        types.update(packet_types)
        unknown.update(t for t in packet_types if t not in (1,6,7))
        offset = start+size
    diagnostic.update(tlv_counts=dict(types),unknown_tlvs=dict(unknown))
    if not frames:
        raise ValueError('No complete valid xWR68xx SDK 3.x OOB frames found.')
    return frames, diagnostic


def analyze(data: bytes, cfg_text: str, data_name='recording.dat', cfg_name='profile.cfg') -> dict:
    config = parse_config(cfg_text)
    frames, diagnostics = decode_stream(data, config)
    points = [p for f in frames for p in f['points']]
    def bounds(key):
        values = [p[key] for p in points if p[key] is not None]
        return [min(values),max(values)] if values else None
    summary = dict(frames=len(frames),points=len(points),nonempty_frames=sum(bool(f['points']) for f in frames),
                   duration_s=frames[-1]['t']+config['frame_period_ms']/1000,first_frame=frames[0]['number'],last_frame=frames[-1]['number'],
                   range_m=bounds('range'),radial_velocity_mps=bounds('v'),snr_db=bounds('snr'),
                   highest_reported_speed_mps=max((abs(p['v']) for p in points),default=None),snr_points=sum(p['snr'] is not None for p in points))
    intervals = [((b['cycles']-a['cycles'])&0xFFFFFFFF)/200e6/delta*1000 for a,b in zip(frames,frames[1:]) if 0<(delta:=((b['number']-a['number'])&0xFFFFFFFF))<1000000]
    if intervals:
        summary['median_cycle_interval_ms_at_200mhz'] = statistics.median(intervals)
        if abs(statistics.median(intervals)-config['frame_period_ms']) > max(.2,config['frame_period_ms']*.05):
            config['warnings'].append('Header CPU cycles disagree with CFG timing at the standard 200 MHz clock. Verify the pairing.')
    activity = []
    for i,f in enumerate(frames):
        if f['points']:
            if not activity or f['t']-activity[-1]['end_s'] > .120000001:
                activity.append(dict(start_s=f['t'],end_s=f['t'],first_index=i,last_index=i,points=0))
            activity[-1].update(end_s=f['t'],last_index=i,points=activity[-1]['points']+len(f['points']))
    return dict(schema_version=1,data_name=data_name,cfg_name=cfg_name,cfg_text=cfg_text,config=config,summary=summary,
                diagnostics=diagnostics,frames=frames,activity=activity,sha256=hashlib.sha256(data).hexdigest())


def write_outputs(recording: dict,out: Path,force=False):
    paths=[out/name for name in ('recording.json','summary.json','points.csv','frames.csv','replay.html')]
    if not force and any(path.exists() for path in paths):
        raise ValueError('Output exists; choose another directory or use --force.')
    out.mkdir(parents=True,exist_ok=True)
    payload=json.dumps(recording,allow_nan=False)
    paths[0].write_text(payload)
    paths[1].write_text(json.dumps({key:recording[key] for key in ('summary','diagnostics','config','activity')},indent=2))
    with paths[2].open('w',newline='') as output:
        writer=csv.writer(output)
        writer.writerow(['frame_number','time_s','point_index','x_m','y_m','z_m','range_m','radial_velocity_mps','snr_db','noise_db'])
        for frame in recording['frames']:
            for i,p in enumerate(frame['points']):writer.writerow([frame['number'],frame['t'],i,*[p[k] for k in ('x','y','z','range','v','snr','noise')]])
    with paths[3].open('w',newline='') as output:
        writer=csv.writer(output);writer.writerow(['frame_number','time_s','point_count','cpu_cycles','packet_bytes','byte_offset'])
        for f in recording['frames']:writer.writerow([f['number'],f['t'],len(f['points']),f['cycles'],f['packet_bytes'],f['offset']])
    paths[4].write_text((Path(__file__).with_name('static') / 'viewer.html').read_text().replace('__EMBEDDED_RECORDING__',payload.replace('<','\\u003c')))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('data',type=Path)
    parser.add_argument('config',type=Path)
    parser.add_argument('--out',type=Path,default=Path('analysis'))
    parser.add_argument('--force',action='store_true')
    args = parser.parse_args()
    recording = analyze(args.data.read_bytes(),args.config.read_text(encoding='utf-8-sig'),args.data.name,args.config.name)
    write_outputs(recording,args.out,args.force)
    print(json.dumps(recording['summary'],indent=2))


if __name__ == '__main__':
    main()
