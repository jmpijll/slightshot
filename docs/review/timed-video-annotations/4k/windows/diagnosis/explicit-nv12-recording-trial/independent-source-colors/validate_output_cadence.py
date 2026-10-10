"""Strict output timing checks from the independently saved ffprobe JSON.

Run after validate_windows_media.py: python3 validate_output_cadence.py ARTIFACT_DIR
The source recording's existing initial timestamp is reported without requiring
it to be zero. Newly rendered exports are scheduled from position zero.
"""
from pathlib import Path
from fractions import Fraction
import json, sys

root = Path(sys.argv[1]).resolve()
out = root / "media-validation"
base = json.loads((out / "media-validation.json").read_text())
source = base["videos"]["source"]["stream"]
source_duration = int(source["duration_ts"]) * Fraction(source["time_base"])
checks = {}
for name, fps, dimensions in [("high", 30, (3840, 2160)), ("balanced", 24, (1920, 1080))]:
    probe = json.loads((out / (name + "-ffprobe.json")).read_text())
    stream = probe["streams"][0]
    frames = [item for item in probe["packets_and_frames"] if item["type"] == "frame"]
    time_base = Fraction(stream["time_base"])
    pts = [int(frame["best_effort_timestamp"]) * time_base for frame in frames]
    last_duration = int(frames[-1]["duration"]) * time_base if "duration" in frames[-1] else Fraction(frames[-1]["duration_time"])
    expected_count_value = source_duration * fps
    expected_count = -(-expected_count_value.numerator // expected_count_value.denominator)
    expected_last_pts = Fraction(expected_count - 1, fps)
    expected_last_duration = min(Fraction(1, fps), source_duration - expected_last_pts)
    gap_tolerance, end_tolerance = Fraction(1, 10000000), Fraction(1, 1000)
    result = {
        "actualDecodedFrames": len(frames), "expectedDecodedFramesFromSourceDurationCeiling": expected_count,
        "actualFrameCountMatchesSourceDurationCeiling": len(frames) == expected_count,
        "actualDimensions": [stream["width"], stream["height"]], "dimensionsPass": (stream["width"], stream["height"]) == dimensions,
        "actualFirstPresentationSeconds": float(pts[0]), "firstOutputPTSIsZeroWithin100ns": abs(pts[0]) <= gap_tolerance,
        "configuredFramesPerSecond": fps,
        "allFrameGapsMatchCadenceWithin100ns": all(second > first and abs(second - first - Fraction(1, fps)) <= gap_tolerance for first, second in zip(pts, pts[1:])),
        "actualLastPresentationSeconds": float(pts[-1]), "expectedLastPresentationSeconds": float(expected_last_pts),
        "actualLastFrameDurationSeconds": float(last_duration), "expectedFinalPartialDurationSeconds": float(expected_last_duration),
        "finalPartialDurationMatchesSourceWithin1ms": abs(last_duration - expected_last_duration) <= end_tolerance,
        "actualDecodedCoverageEndSeconds": float(pts[-1] + last_duration),
        "decodedCoverageMatchesSourceEndWithin1ms": abs(pts[-1] + last_duration - source_duration) <= end_tolerance,
        "sourceDurationSeconds": float(source_duration),
        "containerDurationSeconds": float(stream["duration"]),
        "containerDurationMatchesSourceWithin1ms": abs(Fraction(stream["duration"]) - source_duration) <= end_tolerance,
    }
    result["passed"] = all(result[key] for key in ["actualFrameCountMatchesSourceDurationCeiling", "dimensionsPass",
        "firstOutputPTSIsZeroWithin100ns", "allFrameGapsMatchCadenceWithin100ns", "finalPartialDurationMatchesSourceWithin1ms",
        "decodedCoverageMatchesSourceEndWithin1ms", "containerDurationMatchesSourceWithin1ms"])
    checks[name] = result
report = {
    "sourceCommit": base["sourceCommit"], "prHeadCommit": base["prHeadCommit"], "githubRunId": base["githubRunId"],
    "method": "Independent saved ffprobe raw decoded samples/packets, exact fractions in each MP4 stream time base. Expected count is ceil(source track duration times quality FPS), with exported sample scheduling beginning at zero. Final partial sample and decoded coverage/container end permit 1ms for MP4 timescale conversion; this is smaller than the previously missing 8.342ms final sample.",
    "sourceInitialPresentationSeconds": base["videos"]["source"]["presentationTimesSeconds"][0],
    "sourceDurationSeconds": float(source_duration), "checks": checks,
    "allOutputCadenceAndDurationChecksPass": all(item["passed"] for item in checks.values()),
    "nativePerformanceAcceptanceFailures": base["nativePerformanceAcceptanceFailures"],
}
(out / "media-cadence-validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
sys.exit(0 if report["allOutputCadenceAndDurationChecksPass"] else 1)
