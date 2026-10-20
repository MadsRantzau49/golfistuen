"""Hardware-free integration/regression tests. All writes use temporary project roots."""
from __future__ import annotations

import csv
import io
import json
import struct
import tempfile
import threading
import time
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from radar_analyzer.analyze import MAGIC, analyze
from radar_app.analysis import inspect
from radar_app.api import ROOT, create_app
from radar_app.configuration import apply_commands, digest, validate
from radar_app.decoding import StreamDecoder
from radar_app.serial_service import CommandFailure, RadarService
from radar_app.simulation import SimulatedTransport
from radar_app.storage import SessionStore, safe_child

CFG = (ROOT / "radar_analyzer/example_input/profile.cfg").read_text()
DATA = (ROOT / "radar_analyzer/example_input/recording.dat").read_bytes()


def packet(number=1, points=(), side=(), reverse=False):
    tlvs = [struct.pack("<II", 1, 16*len(points)) + b"".join(struct.pack("<4f", *p) for p in points)]
    if side:
        tlvs.append(struct.pack("<II", 7, 4*len(side)) + b"".join(struct.pack("<hh", *s) for s in side))
    if reverse:
        tlvs.reverse()
    payload = b"".join(tlvs)
    size = (40 + len(payload) + 31) // 32 * 32
    return MAGIC + struct.pack("<8I", 0x03060200, size, 0xA6843, number, number*4000000 & 0xFFFFFFFF, len(points), len(tlvs), 0) + payload + b"\xff"*(size-40-len(payload))


def wait_for(predicate, seconds=4):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("Timed out waiting for simulated reader")


class DecoderTests(unittest.TestCase):
    def test_real_sample_and_incremental_parity(self):
        r = analyze(DATA, CFG)
        self.assertEqual(len(DATA), 36320)
        self.assertEqual((r["summary"]["frames"], r["summary"]["points"], r["summary"]["nonempty_frames"]), (500, 143, 131))
        self.assertEqual((r["summary"]["first_frame"], r["summary"]["last_frame"]), (12887, 13386))
        self.assertEqual(r["frames"][0]["version"], "3.6.2.0")
        self.assertEqual(r["config"]["frame_period_ms"], 20)
        self.assertEqual(sorted({round(p["v"], 3) for f in r["frames"] for p in f["points"]}), [-0.783, 0.783, 1.566, 2.35])
        for size in (1, 7, 13, 39, 61, 1024):
            decoder, frames = StreamDecoder(20), []
            for offset in range(0, len(DATA), size):
                frames.extend(decoder.feed(DATA[offset:offset+size]))
            decoder.finish()
            self.assertEqual(frames, r["frames"])
            self.assertEqual(decoder.frames, 500)
            self.assertEqual(decoder.detections, 143)
            self.assertEqual(decoder.diagnostics["missing_frames"], 0)
            self.assertEqual(decoder.diagnostics["malformed_packets"], 0)

    def test_corrupt_empty_padding_truncated_and_side_order(self):
        malformed = bytearray(packet(2))
        struct.pack_into("<I", malformed, 44, 10000)
        data = b"garbage" + packet(1) + malformed + packet(4, [(1,2,-2,-3)], [(145,361)], True) + packet(5)[:27]
        decoder, frames = StreamDecoder(), []
        for b in data:
            frames.extend(decoder.feed(bytes([b])))
        decoder.finish()
        self.assertEqual([f["number"] for f in frames], [1,4])
        self.assertEqual(frames[0]["points"], [])
        self.assertEqual(frames[1]["points"][0]["snr"], 14.5)
        self.assertEqual(frames[1]["points"][0]["noise"], 36.1)
        self.assertEqual(decoder.diagnostics["missing_frames"], 2)
        self.assertEqual(decoder.diagnostics["malformed_packets"], 1)
        self.assertEqual(decoder.diagnostics["trailing_bytes"], 27)
        self.assertAlmostEqual(frames[1]["t"], .06)

    def test_wrap_and_invalid_side(self):
        decoder = StreamDecoder()
        frames = decoder.feed(packet(0xFFFFFFFF) + packet(0) + packet(3))
        self.assertEqual([f["t"] for f in frames], [0,.02,.08])
        self.assertEqual(decoder.diagnostics["missing_frames"], 2)
        bad = packet(5, [(0,1,0,1)], [(100,200),(200,300)])
        self.assertEqual(decoder.feed(bad + packet(6))[0]["number"], 6)
        self.assertEqual(decoder.diagnostics["malformed_packets"], 1)

    def test_incomplete_claim_resync_and_bounded_noise(self):
        corrupt = bytearray(packet())
        struct.pack_into("<I", corrupt, 12, 5000)
        decoder = StreamDecoder()
        self.assertEqual(decoder.feed(corrupt + packet(2))[0]["number"], 2)
        decoder.feed(b"x"*100000)
        self.assertLessEqual(len(decoder.buffer),7)


class ConfigurationTests(unittest.TestCase):
    def test_values_not_comments_and_preamble(self):
        c = validate(CFG)
        self.assertEqual(c["frame_period_ms"],20)
        self.assertEqual(c["profiles"][0]["adc_samples"],256)
        self.assertAlmostEqual(c["max_unambiguous_radial_mps"],6.26,places=2)
        self.assertTrue(any("exceeds" in w for w in c["warnings"]))
        rows = apply_commands(CFG)
        self.assertEqual(rows[:2],["sensorStop","flushCfg"])
        self.assertEqual(rows.count("sensorStop"),1)
        self.assertEqual(rows.count("flushCfg"),1)
        self.assertFalse(any("%" in r for r in rows))
        self.assertEqual(apply_commands(CFG.replace("sensorStop", "").replace("flushCfg", ""))[:2],rows[:2])

    def test_unsupported_arrangements_and_rejection(self):
        self.assertNotIn("doppler_bin_mps",validate(CFG.replace("bpmCfg -1 0", "bpmCfg -1 1")))
        self.assertNotIn("doppler_bin_mps",validate(CFG.replace("chirpCfg 2 2 0 0 0 0 0 2", "chirpCfg 2 2 0 0 0 0 0 1")))
        for text in (CFG+"\nreset",CFG.replace("channelCfg 15 7", "channelCfg 31 7"),CFG.replace("frameCfg 0 2 16", "frameCfg 0 2 0"),CFG.replace("cfarFovCfg -1 1 -2 8", "cfarFovCfg -1 1 8 -2")):
            with self.assertRaises(ValueError):
                validate(text)


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = SessionStore(Path(self.temp.name))
        self.transport = SimulatedTransport()
        self.radar = RadarService(self.store,self.transport,command_timeout=.35)
        self.radar.connect("sim-command","sim-data")

    def tearDown(self):
        self.radar.disconnect()
        self.temp.cleanup()

    def test_full_record_snapshot_restart_and_replay(self):
        self.radar.apply(CFG)
        self.assertEqual(self.transport.command.writes, apply_commands(CFG))
        session = self.radar.start_recording("foam-shot-001", "foam; radar on desk")
        # Editing/saving another CFG cannot alter an applied snapshot.
        edited=CFG.replace("frameCfg 0 2 16 0 20", "frameCfg 0 2 16 0 50")
        (self.store.configs/"later.cfg").write_text(edited)
        with self.assertRaisesRegex(ValueError,"Stop recording"):
            self.radar.apply(edited)
        for offset in range(0,len(DATA),173):
            self.transport.data.feed(DATA[offset:offset+173])
        wait_for(lambda: self.store.status()["byte_count"]==len(DATA))
        final = self.store.stop()
        self.assertEqual(final["completion_status"],"complete")
        self.assertEqual(final["decoded_frames"],500)
        self.assertEqual(final["detection_count"],143)
        self.assertEqual(final["configuration_hash"],digest(CFG))
        self.assertEqual(self.store.path(session["id"],"stream.dat").read_bytes(),DATA)
        self.assertEqual(self.store.path(session["id"],"profile.cfg").read_text(),CFG)
        self.assertEqual(self.store.replay(session["id"])["summary"]["frames"],500)
        self.assertEqual(len(self.transport.command.reader_ids),1)
        self.assertEqual(len(self.transport.data.reader_ids),1)
        self.radar.sensor(False)
        self.assertEqual(self.radar.state,"configured")
        self.radar.sensor(True)
        self.assertEqual(self.radar.state,"measuring")

    def test_command_error_echo_and_no_newline_prompt(self):
        self.transport.command.replies["flushCfg"]=b"flushCfg\r\nError -1\r\nmmwDemo:/>"
        with self.assertRaises(CommandFailure):
            self.radar.apply(CFG)
        self.assertEqual(self.transport.command.writes,["sensorStop","flushCfg"])
        self.assertEqual(self.radar.failed_command["command"],"flushCfg")
        self.assertIn("Error",self.radar.failed_command["response"])
        self.assertIsNone(self.radar.applied_text)

    def test_timeout_stops_queue_and_unknown_config_cannot_record(self):
        self.transport.command.replies["flushCfg"]=None
        with self.assertRaisesRegex(CommandFailure,"timeout"):
            self.radar.apply(CFG)
        self.assertEqual(len(self.transport.command.writes),2)
        with self.assertRaisesRegex(ValueError,"known CFG"):
            self.radar.start_recording("x","")

    def test_prompt_only_and_done_only_responses(self):
        self.transport.command.replies["sensorStop"]=b"sensorStop\r\nmmwDemo:/>"
        self.transport.command.replies["flushCfg"]=b"flushCfg\r\nDone\r\n"
        self.radar.apply(CFG)
        self.assertEqual(self.radar.state,"measuring")

    def test_permission_and_busy_port_messages(self):
        self.radar.disconnect()
        def blocked(port,baud):raise PermissionError("Permission denied or device busy")
        service=RadarService(self.store,blocked)
        with self.assertRaisesRegex(ValueError,"dialout"):
            service.connect("a","b")
        self.assertEqual(service.state,"faulted")

    def test_serial_open_has_no_reset_pulse(self):
        with patch('radar_app.serial_service.serial.Serial') as constructor:
            uart=constructor.return_value
            RadarService._open_serial('/dev/example',115200)
            self.assertIsNone(constructor.call_args.kwargs['port'])
            self.assertFalse(uart.dtr)
            self.assertFalse(uart.rts)
            self.assertEqual(uart.port,'/dev/example')
            uart.open.assert_called_once_with()

    def test_disconnect_and_shutdown_finalize_recording(self):
        self.radar.apply(CFG)
        session=self.radar.start_recording("shutdown","")
        self.transport.data.feed(packet(1))
        wait_for(lambda:self.store.status()["decoded_frames"]==1)
        self.radar.disconnect("Application shutdown")
        meta=self.store.metadata(session["id"])
        self.assertEqual(meta["completion_status"],"incomplete")
        self.assertEqual(meta["interruption_reason"],"Application shutdown")
        self.assertEqual(meta["decoded_frames"],1)

    def test_competing_operation_rejected(self):
        self.transport.command.replies["sensorStop"]=None
        errors=[]
        def applying():
            try:self.radar.apply(CFG)
            except ValueError as exc:errors.append(exc)
        thread=threading.Thread(target=applying)
        thread.start()
        wait_for(lambda:self.radar.state=="applying configuration")
        with self.assertRaisesRegex(ValueError,"Another radar operation"):
            self.radar.apply(CFG)
        thread.join()
        self.assertEqual(len(errors),1)

    def test_usb_loss_finalizes_incomplete(self):
        self.radar.apply(CFG)
        session=self.radar.start_recording("interrupted","")
        self.transport.data.feed(packet(1)+packet(2)[:17])
        wait_for(lambda:self.store.status()["byte_count"]>0)
        self.transport.data.feed(OSError("USB removed"))
        wait_for(lambda:self.store.active is None)
        wait_for(lambda:self.store.metadata(session["id"])["completion_status"]=="incomplete")
        meta=self.store.metadata(session["id"])
        self.assertIn("USB removed",meta["interruption_reason"])
        self.assertEqual(meta["diagnostics"]["trailing_bytes"],17)

    def test_recording_write_failure(self):
        self.radar.apply(CFG)
        session=self.radar.start_recording("disk full","")
        real=self.store.active["stream"]
        class FailedWriter:
            def write(self, data):raise OSError("No space left on device")
            def flush(self):return real.flush()
            def fileno(self):return real.fileno()
            def close(self):return real.close()
        self.store.active["stream"]=FailedWriter()
        self.transport.data.feed(packet())
        wait_for(lambda:self.radar.state=="faulted")
        self.assertEqual(self.store.metadata(session["id"])["completion_status"],"incomplete")


class StorageApiTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.transport=SimulatedTransport()
        self.app=create_app(Path(self.temp.name),lambda store:RadarService(store,self.transport,command_timeout=.4))
        self.client=TestClient(self.app)
        self.client.__enter__()
        self.headers={"X-Radar-Local":"1","Origin":"http://testserver"}
        self.store=self.app.state.store

    def tearDown(self):
        self.client.__exit__(None,None,None)
        self.temp.cleanup()

    def post(self,path,body=None):
        return self.client.post(path,json=body,headers=self.headers)

    def import_session(self):
        (self.store.logs/"original.dat").write_bytes(DATA)
        (self.store.logs/"explicit-pair.cfg").write_text(CFG)
        response=self.post('/api/sessions/import',dict(dat="original.dat",cfg="explicit-pair.cfg",label="Imported",notes="notes"))
        self.assertEqual(response.status_code,200,response.text)
        return response.json()["id"]

    def test_import_replay_annotations_csv_and_bundle(self):
        sid=self.import_session()
        r=self.client.get(f'/api/sessions/{sid}/replay').json()
        self.assertEqual(r["summary"]["points"],143)
        refs=[[i,0] for i,f in enumerate(r["frames"]) if f["points"]][:4]
        selection=dict(from_s=0,to_s=10,impact_s=2.3,points=refs,filters={"direction":"all"})
        response=self.client.put(f'/api/sessions/{sid}/annotations',json=selection,headers=self.headers)
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(self.client.get(f'/api/sessions/{sid}').json()["annotations"]["points"],refs)
        analysis=self.post(f'/api/sessions/{sid}/analysis',selection).json()
        self.assertEqual(analysis["all_detections_in_interval"]["detection_count"],143)
        self.assertEqual(analysis["manually_selected_ball_candidates"]["detection_count"],4)
        self.assertIsNotNone(analysis["motion_estimate"])
        rows=list(csv.reader(io.StringIO(self.post(f'/api/sessions/{sid}/csv',selection).text)))
        self.assertEqual(len(rows),144)
        selection["manual_only"]=True
        self.assertEqual(len(list(csv.reader(io.StringIO(self.post(f'/api/sessions/{sid}/csv',selection).text)))),5)
        response=self.client.patch(f'/api/sessions/{sid}',json=dict(label="Renamed",notes="new"),headers=self.headers)
        self.assertEqual(response.json()["label"],"Renamed")
        bundle=self.client.get(f'/api/sessions/{sid}/bundle')
        with zipfile.ZipFile(io.BytesIO(bundle.content)) as archive:
            self.assertEqual(len(archive.namelist()),5)
            self.assertEqual(archive.read(f'{sid}/stream.dat'),DATA)
        self.assertEqual((self.store.logs/"original.dat").read_bytes(),DATA)
        self.assertEqual(self.store.metadata(sid)["pairing"],"user-supplied")

    def test_api_serial_and_browser_close_continues_capture(self):
        self.assertEqual(self.post('/api/connect',dict(command_port="sim-command",data_port="sim-data")).status_code,200)
        self.assertEqual(self.post('/api/configs/apply',dict(text=CFG)).status_code,200)
        sid=self.post('/api/recording/start',dict(label="browser gone",notes="")).json()["id"]
        with self.client.websocket_connect('/ws',headers={"origin":"http://testserver"}) as websocket:
            self.assertEqual(websocket.receive_json()["status"]["recording"]["id"],sid)
        self.transport.data.feed(DATA)
        wait_for(lambda:self.store.status()["byte_count"]==len(DATA))
        self.assertEqual(self.client.get('/api/status').json()["recording"]["id"],sid)
        self.assertEqual(self.post('/api/recording/stop').json()["detection_count"],143)

    def test_display_acknowledgement_and_gap_replay(self):
        self.assertEqual(self.post('/api/connect',dict(command_port="sim-command",data_port="sim-data")).status_code,200)
        self.assertEqual(self.post('/api/configs/apply',dict(text=CFG)).status_code,200)
        with self.client.websocket_connect('/ws',headers={"origin":"http://testserver"}) as websocket:
            first=websocket.receive_json()
            self.transport.data.feed(packet(10)+packet(14))
            wait_for(lambda:self.app.state.radar.decoder.frames==2)
            # Resume display after a lag: next update contains latest data, not
            # an accumulated queue of individual frame/display events.
            websocket.send_json({"ack":first["seq"]})
            second=websocket.receive_json()
            self.assertEqual(second["seq"],first["seq"]+1)
            self.assertEqual([f["number"] for f in second["live"]["frames"]],[10,14])
        (self.store.logs/'gap.dat').write_bytes(packet(10)+packet(14))
        (self.store.logs/'gap.cfg').write_text(CFG)
        sid=self.post('/api/sessions/import',dict(dat='gap.dat',cfg='gap.cfg',label='gap',notes='')).json()["id"]
        replay=self.client.get(f'/api/sessions/{sid}/replay').json()
        self.assertEqual(replay["frames"][1]["t"],.08)
        self.assertEqual(replay["diagnostics"]["missing_frames"],3)
        self.assertEqual(self.store.metadata(sid)["missing_frame_ranges"],[dict(after_frame=10,before_frame=14,first_missing=11,last_missing=13,count=3)])

    def test_crash_recovery_and_shutdown(self):
        meta=self.store.start("crash", "", CFG,{},[])
        self.store.write(DATA+packet(99)[:19])
        # Simulate abrupt process exit: files close but no final metadata write.
        active,self.store.active=self.store.active,None
        active["stream"].close();active["console"].close()
        self.store.recover()
        recovered=self.store.metadata(meta["id"])
        self.assertEqual(recovered["completion_status"],"incomplete")
        self.assertEqual(recovered["byte_count"],len(DATA)+19)
        self.assertEqual(recovered["decoded_frames"],500)
        self.assertEqual(recovered["diagnostics"]["trailing_bytes"],19)

    def test_exact_crlf_snapshot_and_external_hash_mismatch(self):
        text=CFG.replace('\n','\r\n')
        meta=self.store.start('Windows CFG line endings','',text,{},[])
        self.store.write(DATA)
        self.store.stop()
        sid=meta['id']
        self.assertEqual(self.store.replay(sid)['cfg_text'],text)
        self.assertEqual(self.client.get(f'/api/sessions/{sid}').json()['cfg_text'],text)
        snapshot=self.store.path(sid,'profile.cfg')
        snapshot.chmod(0o644)
        snapshot.write_text(CFG+'\n% external modification\n')
        with self.assertRaisesRegex(ValueError,'snapshot hash'):
            self.store.replay(sid)

    def test_origin_paths_symlinks_and_no_overwrite(self):
        self.assertEqual(self.client.post('/api/disconnect').status_code,403)
        self.assertEqual(self.client.post('/api/disconnect',headers={"X-Radar-Local":"1","Origin":"https://evil.invalid"}).status_code,403)
        self.assertEqual(self.client.get('/',headers={"host":"evil.invalid"}).status_code,400)
        with self.assertRaises(Exception):
            with self.client.websocket_connect('/ws',headers={"origin":"http://evil.invalid"}) as socket:
                socket.receive_json()
        for name in ("../escape.cfg","/tmp/file.cfg","..","foo/bar"):
            with self.assertRaises(ValueError):safe_child(self.store.configs,name)
        (self.store.configs/"symlink.cfg").symlink_to(ROOT/'configs/default.cfg')
        with self.assertRaises(ValueError):safe_child(self.store.configs,"symlink.cfg")
        self.assertEqual(self.post('/api/configs/save',dict(name="new.cfg",text=CFG)).status_code,200)
        self.assertEqual(self.post('/api/configs/save',dict(name="new.cfg",text=CFG)).status_code,400)
        self.assertEqual(self.client.get('/api/configs/new.cfg').json()["text"],CFG)
        self.assertEqual(self.post('/api/configs/validate',dict(text="reset")).status_code,400)

    def test_demo_pages_and_invalid_annotations(self):
        self.assertEqual(self.client.get('/').status_code,200)
        self.assertIn('viewer-extension.js',self.client.get('/viewer').text)
        self.assertEqual(self.client.get('/api/demo').json()["summary"]["frames"],500)
        self.assertEqual(self.post('/api/demo/analysis',dict(from_s=0,to_s=10)).json()["all_detections_in_interval"]["detection_count"],143)
        sid=self.import_session()
        self.assertEqual(self.client.put(f'/api/sessions/{sid}/annotations',json=dict(from_s=0,to_s=10,points=[[0,999]]),headers=self.headers).status_code,400)


class MotionTests(unittest.TestCase):
    def test_known_motion_and_ambiguous_multiple_points(self):
        raw=b"".join(packet(i,[(i*.1,1+i*.2,-i*.05,1)],[(150,200)]) for i in range(1,6))
        r=analyze(raw,CFG)
        selection=dict(from_s=0,to_s=.1,points=[[i,0] for i in range(5)])
        fit=inspect(r,selection)["motion_estimate"]
        for actual,expected in zip(fit["velocity_xyz_mps"],[5,10,-2.5]):self.assertAlmostEqual(actual,expected,places=4)
        self.assertLess(fit["rms_position_residual_m"],1e-6)
        self.assertIsNone(inspect(r,dict(from_s=0,to_s=.1,points=[[0,0],[1,0],[2,0]]))["motion_estimate"])


if __name__ == '__main__':
    unittest.main()
