"""Independent truth, context selection, scoring and baseline comparability contracts."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import shot_regression as regression
from tools import shot_regression_service as service


class ShotRegressionTest(unittest.TestCase):
    def case(self, outcome="hit", **annotations):
        annotation = {"outcome": outcome, **annotations}
        return {"id": "session/shot", "annotation": annotation, "context": {"room": "room-a"},
                "capture": {"state": "complete", "ended": {"elapsed_s": 2}, "frame_count": 10,
                            "annotation": annotation}}

    def test_hit_miss_and_duplicates_are_independent_of_recorded_verdict(self):
        hit, miss = self.case(), self.case("miss", speed="low")
        shot = {"speed_mps": 10, "direction_deg": 0, "elevation_deg": 5}
        hit["capture"]["confirmed_balls"] = 0
        cases = [regression.evaluate(hit, [shot], {}), regression.evaluate(hit, [], {}),
                 regression.evaluate(miss, [shot], {}), regression.evaluate(miss, [], {}),
                 regression.evaluate(hit, [shot, shot], {})]
        self.assertEqual([r["status"] for r in cases], ["pass", "fail", "fail", "pass", "fail"])
        summary = regression.summarize(cases)
        self.assertEqual(summary["false_negative_hits"], 1)
        self.assertEqual(summary["false_positive_misses"], 1)
        self.assertEqual(summary["duplicate_balls"], 1)
        self.assertAlmostEqual(summary["precision"], 0.5)

    def test_exact_measurements_override_abstract_labels_and_convert_kph(self):
        case = self.case(speed="high", direction="left", elevation="medium",
                         measurements={"speed_kph": 36, "direction_deg": -10, "elevation_deg": 12})
        criteria = {"tolerances": {"speed_kph": 1, "direction_deg": 2, "elevation_deg": 1}}
        passed = regression.evaluate(case, [{"speed_mps": 10, "direction_deg": -11, "elevation_deg": 12.5}], criteria)
        self.assertEqual(passed["status"], "pass")
        self.assertEqual(passed["metrics"]["speed_kph"]["actual"], 36)
        self.assertEqual(passed["metrics"]["direction_deg"]["absolute_error"], 1)
        failed = regression.evaluate(case, [{"speed_mps": 10, "direction_deg": 10, "elevation_deg": 12}], criteria)
        self.assertEqual(failed["status"], "fail")
        self.assertEqual(failed["metrics"]["direction_deg"]["outside_by"], 18)

    def test_qualitative_ranges_are_numeric_inclusive_and_not_invented(self):
        case = self.case(speed="low", direction="straight")
        shot = {"speed_mps": 8, "direction_deg": -3}
        self.assertEqual(regression.evaluate(case, [shot], {})["status"], "unscored")
        criteria = {"ranges": {"speed": {"low": [2, 8]}, "direction": {"straight": [-3, 3]}}}
        result = regression.evaluate(case, [shot], criteria)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["metrics"]["speed_mps"]["source"], "label")

    def test_distance_is_not_confused_with_radar_extent_and_can_be_extended(self):
        case = self.case(measurements={"distance_m": 4.0})
        criteria = {"tolerances": {"distance_m": 0.2}}
        shot = {"speed_mps": 8, "furthest_range_m": 4.0}
        result = regression.evaluate(case, [shot], criteria)
        self.assertEqual(result["status"], "unscored")
        self.assertIsNone(result["metrics"]["distance_m"]["pass"])
        self.assertTrue(result["detection_pass"])
        result = regression.evaluate(case, [shot], criteria, lambda shot, capture, context: {"distance_m": 4.1})
        self.assertEqual(result["status"], "pass")
        with self.assertRaisesRegex(ValueError, "not overwrite"):
            regression.evaluate(case, [shot], criteria, lambda *args: {"speed_mps": 10})

    def test_unfinished_empty_and_unknown_windows_cannot_pass(self):
        self.assertEqual(regression.evaluate(self.case(None), [], {})["status"], "unscored")
        interrupted = self.case()
        interrupted["capture"]["state"] = "interrupted"
        self.assertEqual(regression.evaluate(interrupted, [], {})["status"], "unscored")
        empty = self.case()
        empty["capture"]["frame_count"] = 0
        self.assertEqual(regression.evaluate(empty, [], {})["status"], "unscored")

    def test_context_rules_are_extensible_and_do_not_mix_unmatched_cohorts(self):
        profile = {"schema_version": 1, "criteria": {"ranges": {"speed": {"low": [1, 5]}}},
                   "rules": [{"where": {"ball_type": "foam", "custom_tag": "new"},
                              "criteria": {"ranges": {"speed": {"low": [2, 9]}}}}]}
        regression.validate_profile(profile)
        self.assertEqual(regression.criteria_for(profile, {"ball_type": "real"})["ranges"]["speed"]["low"], [1, 5])
        self.assertEqual(regression.criteria_for(profile, {"ball_type": "foam", "custom_tag": "new"})["ranges"]["speed"]["low"], [2, 9])
        self.assertFalse(regression.matches({}, {"room": "room-a"}))
        self.assertTrue(regression.matches({"room": "room-b"}, {"room": ["room-a", "room-b"]}))
        self.assertIn("custom_tag", regression.group_keys([{"context": {"custom_tag": "new"}}], {}))

    def test_invalid_thresholds_fail_early(self):
        for criteria in [{"tolerances": {"speed_kph": -1}}, {"tolerances": {"speed_kph": float("nan")}},
                         {"ranges": {"speed": {"low": [9, 2]}}}, {"ranges": {"direction": {"left": [-200, 0]}}},
                         {"unknown": {}}]:
            with self.assertRaises(ValueError):
                regression.validate_profile({"schema_version": 1, "criteria": criteria})

    def test_direction_exact_error_wraps_at_180_degrees(self):
        checked = regression.metric_check(-179, {"source": "measurement", "target": 179, "tolerance": 3}, "direction_deg")
        self.assertTrue(checked["pass"])
        self.assertEqual(checked["absolute_error"], 2)

    def test_interactive_setup_requests_only_needed_ranges_and_exact_tolerances(self):
        cases = [self.case(speed="medium", direction="straight", measurements={"speed_kph": 36})]
        cases[0]["session"] = Path("session")
        with patch.object(regression.sys.stdin, "isatty", return_value=True), patch("builtins.input", side_effect=["{}", "-4", "4", "2"]):
            profile = regression.configure(cases, {})
        self.assertEqual(profile["criteria"]["ranges"], {"direction": {"straight": [-4, 4]}})
        self.assertEqual(profile["criteria"]["tolerances"], {"speed_kph": 2})

    def test_baselines_reject_changed_data_or_criteria_and_report_quality_deltas(self):
        case = self.case(measurements={"speed_mps": 10})
        criteria = {"tolerances": {"speed_mps": 1}}
        old = regression.evaluate(case, [{"speed_mps": 12}], criteria)
        new = regression.evaluate(case, [{"speed_mps": 10.5}], criteria)
        def report(result):
            return {"schema_version": 1, "evaluation_fingerprint": "same-data-and-criteria", "cases": [result],
                    "summary": regression.summarize([result]),
                    "groups": [{"context": result["context"], "summary": regression.summarize([result])}]}
        comparison = regression.compare(report(new), report(old))
        self.assertEqual(comparison["improved_cases"], ["session/shot"])
        self.assertAlmostEqual(comparison["metric_delta"]["speed_mps"]["exact_mean_absolute_error"], -1.5)
        self.assertAlmostEqual(comparison["group_delta"][0]["metric_delta"]["speed_mps"]["exact_mean_absolute_error"], -1.5)
        changed = report(new)
        changed["evaluation_fingerprint"] = "changed-labels-or-recording"
        with self.assertRaisesRegex(ValueError, "not comparable"):
            regression.compare(changed, report(old))

    def test_discovery_uses_actual_cfg_and_preserves_legacy_unknowns(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, cfg in [("session-a", "first cfg"), ("session-b", "different cfg")]:
                session = root / name
                (session / "captures").mkdir(parents=True)
                (session / "radar.cfg").write_text(cfg)
                (session / "captures/shot.json").write_text(json.dumps({
                    "capture_id": "shot", "session_id": name, "annotation": {"speed": "low"}}))
            cases = regression.discover([root, root / "session-a"])
            self.assertEqual(len(cases), 2, "Overlapping roots must not duplicate cases")
            self.assertNotEqual(cases[0]["context"]["cfg_sha256"], cases[1]["context"]["cfg_sha256"])
            self.assertIsNone(cases[0]["annotation"].get("outcome"))

    def test_live_append_does_not_invalidate_a_completed_window_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session = root / "session"
            session.mkdir()
            (session / "radar.cfg").write_text("recorded config")
            event_file = session / "events-000001.jsonl"
            lines = [json.dumps({"sequence": 1, "type": "frame"}) + "\n",
                     json.dumps({"sequence": 2, "type": "shot_capture_ended"}) + "\n"]
            event_file.write_text("".join(lines))
            case = self.case()
            case["capture"].update({"capture_id": "shot", "ended": {"event_sequence": 2}})
            before = regression.snapshot_session(session, [case], root / "snapshot1")
            with event_file.open("a") as stream:
                stream.write(json.dumps({"sequence": 3, "type": "frame"}) + "\n")
                stream.write('{"sequence":4,"partial_uart_write":')
            after = regression.snapshot_session(session, [case], root / "snapshot2")
            self.assertEqual(before, after)
            self.assertEqual((root / "snapshot2/events-000001.jsonl").read_text(), "".join(lines))
            event_file.write_text("".join(lines).replace('"frame"', '"changed_frame"'))
            changed = regression.snapshot_session(session, [case], root / "snapshot3")
            self.assertNotEqual(changed, before)

    def test_ui_worker_discovers_requirements_and_persists_reusable_profiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session = root / "session"
            (session / "captures").mkdir(parents=True)
            (session / "deleted-captures").mkdir()
            (session / "radar.cfg").write_text("cfg")
            regression.write_json(session / "session.json", {"settings": {"config_path": "/configs/foam-room.cfg"}})
            record = self.case(speed="high", direction="straight", measurements={"speed_kph": 40})["capture"]
            record.update({"capture_id": "shot", "session_id": "session"})
            record["annotation"]["context"] = {"room": "room-a", "launch_surface": "moving pillow"}
            regression.write_json(session / "captures/shot.json", record)
            regression.write_json(session / "deleted-captures/deleted.json", {**record, "capture_id": "deleted"})
            inventory = service.execute(root, "unused", {}, {"type": "regression_inventory"})
            self.assertEqual(inventory["total"], 1)
            self.assertEqual(inventory["facets"]["room"][0]["value"], "room-a")
            self.assertIn("foam-room.cfg", inventory["facets"]["cfg_sha256"][0]["label"])
            profile = {"schema_version": 1, "where": {"room": "room-a"}, "criteria": {}}
            prepared = service.execute(root, "unused", {}, {"type": "regression_prepare", "profile": profile})
            self.assertEqual(prepared["eligible"], 1)
            self.assertEqual(prepared["ranges"], [{"field": "direction", "label": "straight", "count": 1}])
            self.assertEqual(prepared["tolerances"][0]["metric"], "speed_kph")
            service.execute(root, "unused", {}, {"type": "regression_profile_save", "profile": profile, "name": "Foam in room A"})
            reloaded = service.execute(root, "unused", {}, {"type": "regression_inventory"})
            self.assertEqual(reloaded["profiles"][0]["profile"], profile)
            with self.assertRaisesRegex(ValueError, "saved item"):
                service.execute(root, "unused", {}, {"type": "regression_report", "report_id": "../../outside"})

    def test_ui_report_pages_exclude_large_diagnostic_archives(self):
        case = regression.evaluate(self.case(), [{"speed_mps": 10}], {})
        case["recorded_results"] = ["a large diagnostic archive"]
        report = {"cases": [dict(case, id=str(index)) for index in range(45)], "groups": [], "summary": {}}
        page = service.view_report(report, {"offset": 20})
        self.assertEqual(len(page["cases"]), 20)
        self.assertEqual(page["cases"][0]["id"], "20")
        self.assertEqual(page["next_offset"], 40)
        self.assertNotIn("recorded_results", page["cases"][0])


if __name__ == "__main__":
    unittest.main()
