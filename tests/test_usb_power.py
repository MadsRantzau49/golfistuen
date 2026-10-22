"""The Pi 5 radar requires a full four-hub power cycle."""
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from radar_app.serial_service import RadarService
from radar_app.storage import SessionStore
from radar_app.usb_power import PowerSwitch


class UsbPowerTests(unittest.TestCase):
    def test_all_hubs_switch_in_verified_order_before_reporting_reset(self):
        hub_states = {hub: "on" for hub in (5, 4, 3, 2)}
        actions = []
        def run(args, **kwargs):
            self.assertEqual(args[:3], ["uhubctl", "-e", "-l"])
            hub = int(args[3])
            if "-a" in args:
                hub_states[hub] = args[-1]
                actions.append((hub, args[-1]))
            state = "02a0 power 5gbps Rx.Detect" if hub_states[hub] == "on" else "0080 off"
            count = 2 if hub in (4, 2) else 1
            return SimpleNamespace(stdout="\n".join(f"  Port {port}: {state}" for port in range(1, count + 1)))
        waits = []
        switch = PowerSwitch(run=run, sleep=waits.append)
        self.assertEqual(switch.set("on"), {"state": "on", "board_power_cycled": False})
        self.assertEqual(waits, [])
        self.assertEqual(switch.set("off")["state"], "off")
        self.assertEqual(actions[-4:], [(hub, "off") for hub in (5, 4, 3, 2)])
        self.assertEqual(switch.set("on"), {"state": "on", "board_power_cycled": True})
        self.assertEqual(actions[-4:], [(hub, "on") for hub in (5, 4, 3, 2)])
        self.assertEqual(waits, [5])
        self.assertEqual(set(hub_states.values()), {"on"})

        hub_states[2] = "off"
        self.assertEqual(switch.status(), "partial")
        self.assertEqual(switch.set("on")["board_power_cycled"], False)

    def test_only_a_completed_four_hub_cycle_clears_latched_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            radar = RadarService(SessionStore(Path(directory)))
            radar._started_open_configuration = ("latched",)
            with patch.object(radar, "_usb_request", side_effect=[{"board_power_cycled": False}, {"board_power_cycled": True}]):
                radar.usb_power("on")
                self.assertEqual(radar._started_open_configuration, ("latched",))
                radar.usb_power("on")
                self.assertIsNone(radar._started_open_configuration)

    def test_recording_must_stop_before_power_off(self):
        with tempfile.TemporaryDirectory() as directory:
            store = SessionStore(Path(directory))
            radar = RadarService(store)
            with patch.object(store, "status", return_value={"id": "recording"}), patch.object(radar, "_usb_request") as request:
                with self.assertRaisesRegex(ValueError, "Stop recording"):
                    radar.usb_power("off")
                request.assert_not_called()
