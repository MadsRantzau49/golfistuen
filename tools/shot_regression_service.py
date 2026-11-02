#!/usr/bin/env python3
"""Private JSON worker for the game's guided regression tool. No shell commands."""
from contextlib import redirect_stdout
from collections import Counter, defaultdict
from pathlib import Path
import json
import sys
import tempfile
import uuid

try:
    from . import shot_regression as regression
except ImportError:
    import shot_regression as regression


PAGE = 20


def store(root, kind):
    directory = root / ".regression" / kind
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def artifact(root, kind, identity):
    if not isinstance(identity, str) or not regression.KEY.fullmatch(identity):
        raise ValueError("Choose a saved item from the list")
    return store(root, kind) / (identity + ".json")


def title(request):
    value = str(request.get("name", "Detection check")).strip()
    if not value or len(value) > 120:
        raise ValueError("Give this test a name of 1–120 characters")
    return value


def profile_for(request):
    profile = request.get("profile", {"schema_version": 1, "where": {}, "criteria": {}})
    regression.validate_profile(profile)
    return profile


def view_report(report, request):
    offset = max(0, int(request.get("offset", 0)))
    group_offset = max(0, int(request.get("group_offset", 0)))
    result = {key: report.get(key) for key in ("schema_version", "id", "name", "created_at", "summary", "profile", "group_by", "provenance", "comparison_error")}
    result["cases"] = report["cases"][offset:offset + PAGE]
    result["groups"] = report["groups"][group_offset:group_offset + PAGE]
    result["offset"] = offset
    result["group_offset"] = group_offset
    result["next_offset"] = offset + PAGE if offset + PAGE < len(report["cases"]) else None
    result["next_group_offset"] = group_offset + PAGE if group_offset + PAGE < len(report["groups"]) else None
    comparison = report.get("comparison")
    if comparison:
        result["comparison"] = {"improved_count": len(comparison["improved_cases"]),
                                "regressed_count": len(comparison["regressed_cases"]),
                                "changed_count": len(comparison["changed_predictions"]),
                                "summary_delta": comparison["summary_delta"], "metric_delta": comparison["metric_delta"]}
        improved, regressed = set(comparison["improved_cases"]), set(comparison["regressed_cases"])
        result["cases"] = [{**case, "comparison_change": "improved" if case["id"] in improved else "regressed" if case["id"] in regressed else "unchanged"} for case in result["cases"]]
    # Omit diagnostic archives from TCP responses; they remain in the saved full report.
    result["cases"] = [{key: value for key, value in case.items() if key != "recorded_results"} for case in result["cases"]]
    return result


def execute(root, binary, tuning, request):
    root = Path(root).resolve()
    operation = request["type"]
    if operation == "regression_inventory":
        cases = regression.discover([root])
        facets = defaultdict(Counter)
        cfg_names = defaultdict(set)
        for session in {case["session"] for case in cases}:
            try:
                name = regression.read_json(session / "session.json")["settings"]["config_path"]
                cfg_names[regression.file_digest(session / "radar.cfg")].add(str(name).replace("\\", "/").rsplit("/", 1)[-1])
            except (OSError, ValueError, KeyError, TypeError):
                pass
        for case in cases:
            for key, value in case["context"].items():
                facets[key][value] += 1
        profiles = [regression.read_json(path) for path in sorted(store(root, "profiles").glob("*.json"))]
        reports = [regression.read_json(path) for path in store(root, "reports").glob("*.meta.json")]
        reports.sort(key=lambda item: item["created_at"], reverse=True)
        return {"type": "regression_inventory", "total": len(cases), "sessions": len({c['session'] for c in cases}),
                "facets": {key: [{"value": value, "count": count,
                    "label": (", ".join(sorted(cfg_names[value])) or "Recorded CFG") + " · " + value[:12] + "…" if key == "cfg_sha256" else value}
                    for value, count in sorted(values.items())] for key, values in sorted(facets.items())},
                "profiles": profiles, "reports": reports[:100],
                "message": "Tests use the radar service's running detector and tuning."}
    if operation == "regression_prepare":
        profile = profile_for(request)
        cases = [case for case in regression.discover([root]) if regression.matches(case["context"], profile.get("where", {}))]
        ranges, tolerances = Counter(), Counter()
        eligible = 0
        for case in cases:
            record, annotation = case["capture"], case["annotation"]
            if record.get("state") != "complete" or not record.get("ended") or not record.get("frame_count") or annotation.get("outcome") not in ("hit", "miss"):
                continue
            eligible += 1
            if annotation["outcome"] != "hit":
                continue
            measured = annotation.get("measurements", {})
            tolerances.update(measured.keys())
            for field, metric in regression.LABEL_METRICS.items():
                if annotation.get(field) is not None and metric not in measured and not (field == "speed" and "speed_kph" in measured):
                    ranges[(field, annotation[field])] += 1
        return {"type": "regression_prepared", "profile": profile, "total": len(cases), "eligible": eligible,
                "unscored": len(cases) - eligible,
                "ranges": [{"field": field, "label": label, "count": count} for (field, label), count in sorted(ranges.items())],
                "tolerances": [{"metric": metric, "count": count, "supported": metric in ("speed_mps", "speed_kph", "direction_deg", "elevation_deg")} for metric, count in sorted(tolerances.items())]}
    if operation == "regression_profile_save":
        profile = profile_for(request)
        identity = request.get("profile_id") or "profile_" + uuid.uuid4().hex
        value = {"id": identity, "name": title(request), "profile": profile}
        regression.write_json(artifact(root, "profiles", identity), value)
        return {"type": "regression_profile_saved", "saved": value}
    if operation == "regression_report":
        report = regression.read_json(artifact(root, "reports", request.get("report_id")))
        return {"type": "regression_result", "report": view_report(report, request)}
    if operation != "regression_run":
        raise ValueError("Unknown regression tool operation")
    profile = profile_for(request)
    cases = regression.discover([root])
    with tempfile.TemporaryDirectory(prefix="regression-tuning-") as temporary:
        config = Path(temporary) / "detector.json"
        regression.write_json(config, tuning)
        with redirect_stdout(sys.stderr):
            report = regression.run_suite(cases, profile, Path(binary), config)
    report["provenance"]["detector_file"] = "Running radar service settings"
    report["id"] = "report_" + uuid.uuid4().hex
    report["name"] = title(request)
    baseline_id = request.get("baseline_id")
    if baseline_id:
        baseline = regression.read_json(artifact(root, "reports", baseline_id))
        try:
            report["comparison"] = regression.compare(report, baseline)
            report["baseline_id"] = baseline_id
        except ValueError as error:
            report["comparison_error"] = str(error)
    path = artifact(root, "reports", report["id"])
    regression.write_json(path, report)
    regression.write_json(path.with_suffix(".meta.json"), {key: report[key] for key in ("id", "name", "created_at", "summary")})
    return {"type": "regression_result", "report": view_report(report, {}), "saved_to": str(path)}


def main():
    envelope = json.load(sys.stdin)
    try:
        response = execute(envelope["root"], envelope["binary"], envelope["tuning"], envelope["request"])
    except Exception as error:
        response = {"type": "regression_error", "message": str(error)}
    json.dump(response, sys.stdout, allow_nan=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
