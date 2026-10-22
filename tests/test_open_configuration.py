"""Regressions for the SDK's fatal open-configuration change assertion.

Uses simulated UARTs and the included baseline CFG; no recorded fixtures needed.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from radar_app.serial_service import RadarService
from radar_app.simulation import SimulatedTransport
from radar_app.storage import SessionStore


CFG = (Path(__file__).resolve().parents[1] / "configs/default.cfg").read_text()


class OpenConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.transport = SimulatedTransport()
        self.radar = RadarService(SessionStore(Path(self.temp.name)), self.transport, command_timeout=.5)
        self.radar.connect("sim-command", "sim-data")

    def tearDown(self):
        self.radar.disconnect()
        self.temp.cleanup()

    def test_open_changes_are_rejected_before_any_write_and_keep_active_cfg(self):
        self.radar.apply(CFG)
        writes = self.transport.command.writes.copy()
        for old, new in (("channelCfg 15 5 0", "channelCfg 15 7 0"),
                         ("adcCfg 2 1", "adcCfg 2 0"),
                         ("lowPower 0 0", "lowPower 0 1")):
            with self.subTest(command=old):
                with self.assertRaisesRegex(ValueError, "board reboot"):
                    self.radar.apply(CFG.replace(old, new))
                self.assertEqual(self.transport.command.writes, writes)
                self.assertEqual(self.radar.applied_text, CFG)
                self.assertEqual(self.radar.state, "measuring")
                self.assertTrue(self.radar.status()["connected"])

    def test_uart_reconnect_does_not_forget_latched_board_settings(self):
        self.radar.apply(CFG)
        self.radar.disconnect()
        self.transport = SimulatedTransport()
        self.radar.factory = self.transport
        self.radar.connect("sim-command", "sim-data")
        with self.assertRaisesRegex(ValueError, "board reboot"):
            self.radar.apply(CFG.replace("channelCfg 15 5 0", "channelCfg 15 7 0"))
        self.assertEqual(self.transport.command.writes, [])

    def test_frame_changes_with_same_open_settings_remain_supported(self):
        self.radar.apply(CFG)
        changed = CFG.replace("frameCfg 0 1 16 0 100 1 0", "frameCfg 0 1 16 0 150 1 0")
        self.radar.apply(changed)
        self.assertEqual(self.radar.state, "measuring")
        self.assertEqual(self.radar.applied_summary["frame_period_ms"], 150)

    def test_separate_sensor_start_also_latches_open_settings(self):
        self.radar.apply(CFG.replace("sensorStart", ""))
        self.assertEqual(self.radar.state, "configured")
        self.radar.sensor(True)
        writes = self.transport.command.writes.copy()
        with self.assertRaisesRegex(ValueError, "board reboot"):
            self.radar.apply(CFG.replace("channelCfg 15 5 0", "channelCfg 15 7 0"))
        self.assertEqual(self.transport.command.writes, writes)


if __name__ == "__main__":
    unittest.main()
