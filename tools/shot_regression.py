#!/usr/bin/env python3
"""Context-aware regression testing of Pinewater shot-note recordings (stdlib only).

inventory: inspect datasets; configure: choose numeric criteria; run: replay and score.
Run without --profile to choose numeric criteria interactively before replay starts.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LABEL_METRICS = {"speed": "speed_mps", "direction": "direction_deg", "elevation": "elevation_deg"}
STANDARD_CONTEXT = ["room", "radar_setup", "cfg_sha256", "ball_type", "launch_surface", "launch_motion"]
KEY = re.compile(r"[A-Za-z0-9_]{1,64}\Z")


def read_json(path):
    with Path(path).open() as stream:
        return json.load(stream)


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, allow_nan=False).encode()).hexdigest()


def file_digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            result.update(chunk)
    return result.hexdigest()


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def discover(roots):
    """Read labels only; do not load point clouds until selected sessions are replayed."""
    paths = set()
    for root in roots:
        root = Path(root).resolve()
        if not root.is_dir():
            raise ValueError(f"Recording directory does not exist: {root}")
        paths.update(root.rglob("captures/*.json"))
    cases, configs, ids = [], {}, set()
    for path in sorted(paths):
        record = read_json(path)
        session = path.parent.parent
        if session not in configs:
            configs[session] = file_digest(session / "radar.cfg")
        if record.get("capture_id") != path.stem or record.get("session_id") != session.name:
            raise ValueError(f"Capture identity does not match its recording: {path}")
        case_id = session.name + "/" + record["capture_id"]
        if case_id in ids:
            raise ValueError(f"Duplicate case identity across recording roots: {case_id}")
        ids.add(case_id)
        annotation = record.get("annotation", {})
        context = dict(annotation.get("context", {}))
        if any(not KEY.fullmatch(k) or not isinstance(v, str) for k, v in context.items()):
            raise ValueError(f"Invalid context in {path}")
        # Actual bytes override any manually supplied label; filenames are not CFG identity.
        context["cfg_sha256"] = configs[session]
        cases.append({"id": case_id, "path": path, "session": session, "capture": record,
                      "annotation": annotation, "context": context})
    return cases


def matches(context, where):
    return all(context.get(key) in (value if isinstance(value, list) else [value])
               for key, value in where.items())


def parse_where(items):
    where = {}
    for item in items:
        key, separator, value = item.partition("=")
        if not separator or not KEY.fullmatch(key) or not value:
            raise ValueError("Use --where key=value (repeat a key to select several values)")
        where.setdefault(key, []).append(value)
    return where


def validate_where(where):
    if not isinstance(where, dict):
        raise ValueError("where must be an object of context keys and string values/lists")
    for key, value in where.items():
        values = value if isinstance(value, list) else [value]
        if not KEY.fullmatch(key) or not values or any(not isinstance(v, str) or not v for v in values):
            raise ValueError(f"Invalid context filter: {key}")


def validate_criteria(criteria):
    if not isinstance(criteria, dict) or set(criteria) - {"ranges", "tolerances"}:
        raise ValueError("Criteria support ranges and tolerances only")
    for field, labels in criteria.get("ranges", {}).items():
        if field not in LABEL_METRICS or not isinstance(labels, dict):
            raise ValueError(f"Unknown qualitative field: {field}")
        for label, bounds in labels.items():
            if not isinstance(bounds, list) or len(bounds) != 2 or not all(number(v) for v in bounds) or bounds[0] > bounds[1]:
                raise ValueError(f"{field}.{label} needs finite inclusive [minimum, maximum]")
            metric = LABEL_METRICS[field]
            if (metric == "speed_mps" and bounds[0] < 0) or (metric == "direction_deg" and (bounds[0] < -180 or bounds[1] > 180)) or (metric == "elevation_deg" and (bounds[0] < -90 or bounds[1] > 90)):
                raise ValueError(f"Out-of-domain range for {field}.{label}")
    for metric, tolerance in criteria.get("tolerances", {}).items():
        if not KEY.fullmatch(metric) or not number(tolerance) or tolerance < 0:
            raise ValueError(f"{metric} needs a finite nonnegative absolute tolerance")


def validate_profile(profile):
    if not isinstance(profile, dict) or profile.get("schema_version") != 1:
        raise ValueError("Expected a schema_version: 1 regression profile")
    if set(profile) - {"schema_version", "where", "group_by", "criteria", "rules"}:
        raise ValueError("Unknown profile field")
    validate_where(profile.get("where", {}))
    groups = profile.get("group_by", [])
    if not isinstance(groups, list) or any(not isinstance(k, str) or not KEY.fullmatch(k) for k in groups):
        raise ValueError("group_by must be a list of context keys")
    validate_criteria(profile.get("criteria", {}))
    if not isinstance(profile.get("rules", []), list):
        raise ValueError("rules must be a list")
    for rule in profile.get("rules", []):
        if not isinstance(rule, dict) or set(rule) != {"where", "criteria"}:
            raise ValueError("Each context rule needs where and criteria")
        validate_where(rule["where"])
        validate_criteria(rule["criteria"])


def criteria_for(profile, context):
    result = {"ranges": {}, "tolerances": {}}
    layers = [profile.get("criteria", {})] + [rule["criteria"] for rule in profile.get("rules", []) if matches(context, rule["where"])]
    for layer in layers:
        for field, labels in layer.get("ranges", {}).items():
            result["ranges"].setdefault(field, {}).update(labels)
        result["tolerances"].update(layer.get("tolerances", {}))
    return result


def expectations(annotation, criteria):
    """Exact truth takes priority per axis. Other measured metrics remain extensible."""
    expected, problems = {}, []
    measured = annotation.get("measurements", {})
    if not isinstance(measured, dict):
        return {}, ["measurements must be an object"]
    if "speed_mps" in measured and "speed_kph" in measured:
        problems.append("Exact speed must use either speed_mps or speed_kph")
    for metric, target in measured.items():
        if not KEY.fullmatch(metric) or not number(target):
            problems.append(f"Invalid measurement: {metric}")
            continue
        tolerance = criteria.get("tolerances", {}).get(metric)
        if tolerance is None:
            problems.append(f"No exact tolerance configured for {metric}")
        expected[metric] = {"source": "measurement", "target": target, "tolerance": tolerance}
    for field, metric in LABEL_METRICS.items():
        if metric in measured or (field == "speed" and "speed_kph" in measured):
            continue
        label = annotation.get(field)
        if label is None:
            continue
        bounds = criteria.get("ranges", {}).get(field, {}).get(label)
        if bounds is None:
            problems.append(f"No numeric range configured for {field}={label}")
        expected[metric] = {"source": "label", "label": label, "range": bounds}
    return expected, problems


def prompt_number(message):
    while True:
        text = input(message).strip()
        try:
            value = float(text)
            if math.isfinite(value):
                return value
        except ValueError:
            pass
        print("Enter a finite number; no thresholds are assumed.")


def configure(cases, where):
    if not sys.stdin.isatty():
        raise ValueError("Numeric criteria are required. Run configure interactively or supply --profile FILE.")
    inventory(cases)
    print('\nChoose matching conditions as JSON, e.g. {"room":"living-room", "ball_type":"foam"}.')
    print("Empty object selects all contexts; results remain grouped by conditions.")
    chosen = json.loads(input("Context filters [{}]: ").strip() or "{}")
    validate_where(chosen)
    chosen.update(where)
    selected = [case for case in cases if matches(case["context"], chosen)]
    if not selected:
        raise ValueError("No captures match the selected conditions")
    labels, metrics = defaultdict(set), set()
    for case in selected:
        annotation = case["annotation"]
        if case["capture"].get("state") != "complete" or annotation.get("outcome") != "hit":
            continue
        measured = annotation.get("measurements", {})
        metrics.update(measured)
        for field, metric in LABEL_METRICS.items():
            if annotation.get(field) is not None and metric not in measured and not (field == "speed" and "speed_kph" in measured):
                labels[field].add(annotation[field])
    criteria = {"ranges": {}, "tolerances": {}}
    print("\nInclusive ranges: speed in m/s; direction/elevation in degrees. Left is negative, right positive.")
    for field, values in sorted(labels.items()):
        criteria["ranges"][field] = {}
        for label in sorted(values):
            while True:
                bounds = [prompt_number(f"{field} / {label}: minimum: "), prompt_number("  maximum: ")]
                try:
                    validate_criteria({"ranges": {field: {label: bounds}}})
                    break
                except ValueError as error:
                    print(error)
            criteria["ranges"][field][label] = bounds
    for metric in sorted(metrics):
        while True:
            tolerance = prompt_number(f"Exact {metric}: allowed ± tolerance: ")
            if tolerance >= 0:
                break
            print("Tolerance must be nonnegative.")
        criteria["tolerances"][metric] = tolerance
    return {"schema_version": 1, "where": chosen, "criteria": criteria, "rules": []}


def group_keys(cases, profile):
    # By default every supplied context tag contributes to cluster identity.
    return profile.get("group_by") or STANDARD_CONTEXT + sorted(set().union(*(case["context"] for case in cases)) - set(STANDARD_CONTEXT))


def inventory(cases):
    print(f"Found {len(cases)} captures in {len({c['session'] for c in cases})} sessions.")
    for key in group_keys(cases, {}):
        counts = Counter(case["context"].get(key, "<not recorded>") for case in cases)
        print(f"  {key}: " + "; ".join(f"{value} ({count})" for value, count in sorted(counts.items())))
    print("  outcomes: " + str(dict(Counter(case["annotation"].get("outcome") or "unknown" for case in cases))))
    print("  states: " + str(dict(Counter(case["capture"].get("state", "unknown") for case in cases))))


def base_metrics(shot):
    result = {key: shot[key] for key in ("speed_mps", "direction_deg", "elevation_deg") if number(shot.get(key))}
    if "speed_mps" in result:
        result["speed_kph"] = result["speed_mps"] * 3.6
    return result


def metric_check(actual, expected, metric):
    if (expected["source"] == "measurement" and expected.get("tolerance") is None) or (expected["source"] == "label" and expected.get("range") is None):
        return {**expected, "actual": actual if number(actual) else None, "pass": None, "problem": "No numeric acceptance criterion configured"}
    if not number(actual):
        return {**expected, "actual": None, "pass": None, "problem": "Estimator does not provide this metric"}
    if expected["source"] == "measurement":
        error = actual - expected["target"]
        if metric == "direction_deg":
            error = (error + 180) % 360 - 180
        outside = max(0.0, abs(error) - expected["tolerance"])
        return {**expected, "actual": actual, "error": error, "absolute_error": abs(error),
                "outside_by": outside, "pass": outside <= 1e-9}
    low, high = expected["range"]
    outside = max(0.0, low - actual, actual - high)
    return {**expected, "actual": actual, "outside_by": outside, "pass": outside <= 1e-9}


def evaluate(case, shots, criteria, adapter=None):
    record, annotation = case["capture"], case["annotation"]
    outcome = annotation.get("outcome")
    expected, problems = expectations(annotation, criteria) if outcome == "hit" else ({}, [])
    eligible = record.get("state") == "complete" and record.get("ended") is not None and record.get("frame_count", 0) > 0 and outcome in ("hit", "miss")
    if not eligible:
        problems.append("Needs a complete, nonempty window and independent hit/miss annotation")
    detection_pass = (len(shots) == (1 if outcome == "hit" else 0)) if eligible else None
    checks = {}
    if eligible and outcome == "hit" and len(shots) == 1:
        metrics = base_metrics(shots[0])
        if adapter:
            extra = adapter(shots[0], record, case["context"])
            if not isinstance(extra, dict) or any(not isinstance(k, str) or not KEY.fullmatch(k) or not number(v) for k, v in extra.items()):
                raise ValueError("Metric adapter must return a dict of finite numeric metrics")
            if set(extra) & set(metrics):
                raise ValueError("Metric adapters may add metrics, not overwrite detector speed/angles")
            metrics.update(extra)
        for metric, target in expected.items():
            checks[metric] = metric_check(metrics.get(metric), target, metric)
            if checks[metric]["pass"] is None:
                problems.append(f"{metric}: {checks[metric]['problem']}")
    # Missing detections and duplicates fail regardless of incomplete quality criteria.
    if detection_pass is False or any(check["pass"] is False for check in checks.values()):
        status = "fail"
    elif problems:
        status = "unscored"
    else:
        status = "pass"
    return {"id": case["id"], "context": case["context"], "annotation": annotation,
            "outcome": outcome, "eligible": eligible, "detected_count": len(shots),
            "detection_pass": detection_pass, "status": status, "problems": problems,
            "expected_metrics": expected if outcome == "hit" else {}, "metrics": checks,
            "quality_scope": "numeric" if expected else "detection_only", "shots": shots}


def summarize(results):
    eligible = [r for r in results if r["eligible"]]
    hits = [r for r in eligible if r["outcome"] == "hit"]
    misses = [r for r in eligible if r["outcome"] == "miss"]
    tp = sum(r["detected_count"] > 0 for r in hits)
    fp = sum(r["detected_count"] for r in misses)
    duplicates = sum(max(0, r["detected_count"] - 1) for r in hits)
    summary = {"cases": len(results), "eligible": len(eligible), "hits": len(hits), "misses": len(misses),
               "passed": sum(r["status"] == "pass" for r in results),
               "failed": sum(r["status"] == "fail" for r in results),
               "unscored": sum(r["status"] == "unscored" for r in results),
               "true_positive_hits": tp, "false_negative_hits": len(hits) - tp,
               "true_negative_misses": sum(r["detected_count"] == 0 for r in misses),
               "false_positive_misses": sum(r["detected_count"] > 0 for r in misses),
               "false_positive_balls": fp, "duplicate_balls": duplicates,
               "recall": tp / len(hits) if hits else None,
               "precision": tp / (tp + fp + duplicates) if tp + fp + duplicates else None,
               "detection_accuracy": sum(r["detection_pass"] is True for r in eligible) / len(eligible) if eligible else None,
               "detection_only_cases": sum(r["quality_scope"] == "detection_only" for r in hits), "metrics": {}}
    summary["numeric_quality_passes"] = sum(r["status"] == "pass" and bool(r["expected_metrics"]) for r in hits)
    names = sorted({m for r in hits for m in r["expected_metrics"]})
    for metric in names:
        checks = [r["metrics"][metric] for r in hits if metric in r["metrics"] and r["metrics"][metric]["pass"] is not None]
        errors = [c["absolute_error"] for c in checks if "absolute_error" in c]
        summary["metrics"][metric] = {"expected": sum(metric in r["expected_metrics"] for r in hits),
            "evaluated": len(checks), "passed": sum(c["pass"] for c in checks),
            "pass_rate": sum(c["pass"] for c in checks) / len(checks) if checks else None,
            "mean_outside_by": sum(c["outside_by"] for c in checks) / len(checks) if checks else None,
            "exact_mean_absolute_error": sum(errors) / len(errors) if errors else None}
    return summary


def compare(report, baseline):
    if baseline.get("schema_version") != 1 or report["evaluation_fingerprint"] != baseline.get("evaluation_fingerprint"):
        raise ValueError("Baseline is not comparable: dataset, labels, filters, grouping or numeric criteria changed. Save a new baseline.")
    previous = {case["id"]: case for case in baseline["cases"]}
    improved, regressed, changed = [], [], []
    for case in report["cases"]:
        old = previous[case["id"]]
        if case["status"] == "pass" and old["status"] != "pass":
            improved.append(case["id"])
        elif case["status"] != "pass" and old["status"] == "pass":
            regressed.append(case["id"])
        if case["detected_count"] != old["detected_count"] or case["metrics"] != old["metrics"]:
            changed.append(case["id"])
    def deltas(current, old):
        return {key: value - old[key] for key, value in current.items()
                if number(value) and number(old.get(key))}
    def metric_deltas(current, old):
        return {key: deltas(values, old["metrics"].get(key, {})) for key, values in current["metrics"].items()}
    return {"improved_cases": improved, "regressed_cases": regressed, "changed_predictions": changed,
            "summary_delta": deltas(report["summary"], baseline["summary"]),
            "metric_delta": metric_deltas(report["summary"], baseline["summary"]),
            "group_delta": [{"context": group["context"],
                "delta": deltas(group["summary"], old["summary"]),
                "metric_delta": metric_deltas(group["summary"], old["summary"])}
                for group, old in zip(report["groups"], baseline["groups"])]}


def git_provenance():
    def git(*args):
        try:
            result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
        except FileNotFoundError:
            return None
        return result.stdout.strip() if result.returncode == 0 else None
    return {"commit": git("rev-parse", "HEAD"), "working_tree": git("status", "--porcelain"),
            "tracked_diff_sha256": digest(git("diff", "HEAD"))}


def snapshot_session(directory, cases, target):
    """Freeze completed windows, even while the live service appends new events."""
    target.mkdir()
    shutil.copyfile(directory / "radar.cfg", target / "radar.cfg")
    (target / "captures").mkdir()
    for case in cases:
        write_json(target / "captures" / (case["capture"]["capture_id"] + ".json"), case["capture"])
    ends = [case["capture"].get("ended") or {} for case in cases]
    if any(end and (not isinstance(end.get("event_sequence"), int) or end["event_sequence"] <= 0) for end in ends):
        raise ValueError(f"A selected window has no valid end-event marker: {directory}")
    cutoff = max((end.get("event_sequence", 0) for end in ends), default=0)
    source = hashlib.sha256()
    last = 0
    paths = sorted(directory.glob("events-*.jsonl"))
    if not paths:
        raise ValueError(f"No recorded frame events: {directory}")
    with (target / "events-000001.jsonl").open("wb") as output:
        for path in paths:
            if cutoff == 0 or last >= cutoff:
                break
            with path.open("rb") as stream:
                for line in stream:
                    event = json.loads(line)
                    last = event["sequence"]
                    if last > cutoff:
                        break
                    source.update(line)
                    output.write(line)
                    if last == cutoff:
                        break
    if cutoff and last != cutoff:
        raise ValueError(f"Recording is missing the end event for a selected window: {directory}")
    return source.hexdigest()


def run_suite(cases, profile, binary, detector, adapter_path=None):
    validate_profile(profile)
    # Equivalent omitted/empty optional fields must compare as the same profile.
    def normalized_criteria(value):
        return {"ranges": value.get("ranges", {}), "tolerances": value.get("tolerances", {})}
    profile = {"schema_version": 1, "where": profile.get("where", {}),
               "group_by": profile.get("group_by") or [],
               "criteria": normalized_criteria(profile.get("criteria", {})),
               "rules": [{"where": rule["where"], "criteria": normalized_criteria(rule["criteria"])}
                         for rule in profile.get("rules", [])]}
    cases = [case for case in cases if matches(case["context"], profile.get("where", {}))]
    if not cases:
        raise ValueError("No captures match this profile; an empty suite cannot pass")
    adapter = None
    if adapter_path:
        spec = importlib.util.spec_from_file_location("shot_metric_adapter", adapter_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        adapter = module.derive_metrics
    results, inputs, sessions = [], [], []
    by_session = defaultdict(list)
    for case in cases:
        by_session[case["session"]].append(case)
    for directory, selected in sorted(by_session.items(), key=lambda item: item[0].name):
        print(f"Replaying {directory.name} ({len(selected)} selected captures)…", flush=True)
        with tempfile.TemporaryDirectory(prefix="shot-regression-") as temporary:
            output = Path(temporary) / "replay.json"
            snapshot = Path(temporary) / directory.name
            source_hash = snapshot_session(directory, selected, snapshot)
            subprocess.run([str(binary), "replay-live", str(snapshot), str(detector), str(output)],
                           cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
            replay = read_json(output)
        sessions.append({"session": directory.name, "source_events_sha256": source_hash,
                         "configuration": replay["configuration"], "statistics": replay["statistics"]})
        predictions = {capture["capture_id"]: capture for capture in replay["captures"]}
        for case in selected:
            prediction = predictions.get(case["capture"]["capture_id"])
            if prediction is None:
                raise ValueError(f"Replay omitted capture {case['id']}")
            result = evaluate(case, prediction["replayed_shots"], criteria_for(profile, case["context"]), adapter)
            # Keep original decisions separate from revised predictions.
            result["recorded_confirmed_balls"] = case["capture"].get("confirmed_balls")
            result["recorded_results"] = case["capture"].get("detector_results", [])
            results.append(result)
            record = case["capture"]
            inputs.append({"id": case["id"], "source": source_hash, "context": case["context"],
                           "annotation": case["annotation"], "window": {k: record.get(k) for k in
                               ("state", "started", "ended", "first_frame", "last_frame", "frame_count")}})
    keys = group_keys(cases, profile)
    groups = defaultdict(list)
    for result in results:
        groups[json.dumps({key: result["context"].get(key) for key in keys}, sort_keys=True)].append(result)
    return {"schema_version": 1, "created_at": datetime.now(timezone.utc).isoformat(),
            "evaluation_fingerprint": digest({"inputs": inputs, "profile": profile, "group_by": keys}),
            "profile": profile, "group_by": keys,
            "provenance": {**git_provenance(), "binary_sha256": file_digest(binary),
                "detector_file": str(detector), "detector_sha256": file_digest(detector),
                "metric_adapter": str(adapter_path) if adapter_path else None,
                "metric_adapter_sha256": file_digest(adapter_path) if adapter_path else None},
            "summary": summarize(results), "groups": [{"context": json.loads(key), "summary": summarize(group)} for key, group in sorted(groups.items())],
            "sessions": sessions, "cases": results}


def print_report(report):
    summary = report["summary"]
    print(f"\n{summary['passed']} PASS / {summary['failed']} FAIL / {summary['unscored']} UNSCORED")
    print(f"Hits detected {summary['true_positive_hits']}/{summary['hits']}; false-positive miss windows {summary['false_positive_misses']}/{summary['misses']}; duplicate balls {summary['duplicate_balls']}")
    for metric, values in summary["metrics"].items():
        print(f"  {metric}: {values['passed']} pass / {values['evaluated']} evaluated / {values['expected']} expected; exact MAE={values['exact_mean_absolute_error']}")
    for group in report["groups"]:
        values = group["summary"]
        print(f"  Cluster {json.dumps(group['context'], sort_keys=True)}: {values['passed']} pass, {values['failed']} fail, {values['unscored']} unscored")
    for case in report["cases"]:
        if case["status"] != "pass":
            reasons = list(case["problems"])
            if case["detection_pass"] is False:
                reasons.append(f"expected {'1 ball' if case['outcome'] == 'hit' else 'no ball'}, detected {case['detected_count']}")
            reasons.extend(f"{key} outside criterion by {value['outside_by']:.3f}" for key, value in case["metrics"].items() if value["pass"] is False)
            print(f"  {case['status'].upper()} {case['id']}: {'; '.join(reasons)}")
    if "comparison" in report:
        comparison = report["comparison"]
        print(f"Baseline: {len(comparison['improved_cases'])} improved / {len(comparison['regressed_cases'])} regressed cases")
        print("  Metric changes: " + json.dumps(comparison["metric_delta"], sort_keys=True))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["inventory", "configure", "run"])
    parser.add_argument("recordings", type=Path, nargs="+", help="Session directories or roots containing sessions")
    parser.add_argument("--where", action="append", default=[], metavar="KEY=VALUE")
    parser.add_argument("--profile", type=Path, help="Numeric criteria JSON (configure writes it; run reads it)")
    parser.add_argument("--report", type=Path, help="Output report JSON (required for run)")
    parser.add_argument("--baseline", type=Path, help="Previous report on identical data/criteria")
    parser.add_argument("--detector", type=Path, default=ROOT / "radar_app/configs/swing.json")
    parser.add_argument("--binary", type=Path, help="Use an explicit existing Rust binary instead of building current source")
    parser.add_argument("--metrics-module", type=Path, help="Python extension defining derive_metrics(shot, capture, context)")
    parser.add_argument("--allow-unscored", action="store_true", help="Allow partial coverage, still shown as UNSCORED")
    parser.add_argument("--fail-on-regression", action="store_true", help="Also fail if a previously passing case regresses")
    args = parser.parse_args(argv)
    where = parse_where(args.where)
    cases = discover(args.recordings)
    if not cases:
        raise ValueError("No shot-note captures found")
    if args.command == "inventory":
        inventory([case for case in cases if matches(case["context"], where)])
        return 0
    if args.command == "configure":
        if not args.profile:
            parser.error("configure requires --profile OUTPUT.json")
        profile = configure(cases, where)
        write_json(args.profile, profile)
        print(f"Saved numeric criteria: {args.profile}")
        return 0
    if not args.report:
        parser.error("run requires --report OUTPUT.json")
    if args.baseline and args.report.resolve() == args.baseline.resolve():
        raise ValueError("Use a new report path to preserve the baseline")
    if args.fail_on_regression and not args.baseline:
        parser.error("--fail-on-regression requires --baseline")
    profile = read_json(args.profile) if args.profile else configure(cases, where)
    validate_profile(profile)
    profile.setdefault("where", {}).update(where)
    # Validate the whole selection before building or replaying.
    if not any(matches(case["context"], profile.get("where", {})) for case in cases):
        raise ValueError("No captures match the profile")
    suffix = ".exe" if sys.platform == "win32" else ""
    binary = args.binary.resolve() if args.binary else ROOT / f"radar_app/target/release/radar_app{suffix}"
    if not args.binary:
        cargo = shutil.which("cargo") or str(Path.home() / f".cargo/bin/cargo{suffix}")
        if not Path(cargo).is_file():
            raise ValueError("Install the Rust toolchain (cargo), or supply --binary PATH")
        subprocess.run([cargo, "build", "--release", "--manifest-path", str(ROOT / "radar_app/Cargo.toml")], cwd=ROOT, check=True)
    baseline = read_json(args.baseline) if args.baseline else None
    report = run_suite(cases, profile, binary, args.detector.resolve(), args.metrics_module.resolve() if args.metrics_module else None)
    if baseline:
        report["comparison"] = compare(report, baseline)
        report["baseline"] = str(args.baseline)
    write_json(args.report, report)
    print_report(report)
    print(f"Full report: {args.report}")
    if report["summary"]["failed"] or (args.fail_on_regression and report.get("comparison", {}).get("regressed_cases")):
        return 1
    if not report["summary"]["eligible"] or (report["summary"]["unscored"] and not args.allow_unscored):
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, TypeError, AttributeError, EOFError, subprocess.SubprocessError) as error:
        print(f"Shot regression: {error}", file=sys.stderr)
        raise SystemExit(2)
