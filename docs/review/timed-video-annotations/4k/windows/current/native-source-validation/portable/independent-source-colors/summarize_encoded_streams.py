"""Read-only concise encoding/timeline observations from saved actual ffprobe.
Run after the three validators: python3 summarize_encoded_streams.py ARTIFACT_DIRECTORY
This adds metadata observations, not new acceptance gates or another encode.
"""
from pathlib import Path
from fractions import Fraction
from collections import Counter
import json, sys

root = Path(sys.argv[1]).resolve()
out = root / "media-validation"
prior = json.loads((out / "media-validation.json").read_text())
source = prior["videos"]["source"]["stream"]
source_duration = int(source["duration_ts"]) * Fraction(source["time_base"])
results = {}
for name, fps in [("high", 30), ("balanced", 24), ("step", 30)]:
    probe = json.loads((out / (name + "-color-ffprobe.json")).read_text())
    stream = probe["streams"][0]
    frames = probe["frames"]
    base = Fraction(stream["time_base"])
    times = [int(frame["best_effort_timestamp"]) * base for frame in frames]
    last_duration = int(frames[-1]["duration"]) * base
    gaps = [b - a for a, b in zip(times, times[1:])]
    expected_count = -(-source_duration.numerator * fps // source_duration.denominator)
    results[name] = {
        "file": "video-editor-4k-" + name + ".mp4", "codec": stream["codec_name"],
        "profile": stream.get("profile"), "level": stream.get("level"), "pixelFormat": stream.get("pix_fmt"),
        "width": stream["width"], "height": stream["height"], "actualVideoStreamBitrateBitsPerSecond": int(stream["bit_rate"]),
        "ffprobeNominalFrameRate": stream["r_frame_rate"], "ffprobeAverageFrameRate": stream["avg_frame_rate"],
        "actualDecodedFrames": len(frames), "sourceDurationExpectedFrameCount": expected_count,
        "actualFirstPresentationSeconds": float(times[0]), "actualLastPresentationSeconds": float(times[-1]),
        "actualFinalSampleDurationSeconds": float(last_duration), "actualDecodedCoverageEndSeconds": float(times[-1] + last_duration),
        "sourceDurationSeconds": float(source_duration), "actualContainerTrackDurationSeconds": float(int(stream["duration_ts"]) * base),
        "actualGapHistogramSeconds": dict(Counter(map(str, gaps))), "actualPictureTypeHistogram": dict(Counter(frame["pict_type"] for frame in frames)),
        "actualHasBFrames": stream.get("has_b_frames"),
        "actualColorRange": stream.get("color_range"), "actualColorMatrix": stream.get("color_space"),
        "actualColorPrimaries": stream.get("color_primaries"), "actualColorTransfer": stream.get("color_transfer"),
        "observations": {"countMatchesSourceDurationCeiling": len(frames) == expected_count,
            "firstPTSIsZeroWithin100ns": abs(times[0]) <= Fraction(1, 10000000),
            "gapsMatchConfiguredCadenceWithin100ns": all(abs(gap - Fraction(1, fps)) <= Fraction(1, 10000000) for gap in gaps),
            "decodedCoverageMatchesSourceWithin1ms": abs(times[-1] + last_duration - source_duration) <= Fraction(1, 1000)}
    }
report = {"sourceCommit": prior["sourceCommit"], "prHeadCommit": prior["prHeadCommit"], "githubRunId": prior["githubRunId"],
    "scope": "Observations from actual decoded ffprobe frame records and stream metadata for High/Balanced/Step. Bitrate and compression metadata are measured outputs, not a claim that encoding choices or hardware processing are unchanged. A final partial frame makes average frame rate differ from the otherwise constant PTS cadence. The three original acceptance validators and their tolerances remain unchanged.",
    "streams": results, "nativePerformanceAcceptanceFailures": prior["nativePerformanceAcceptanceFailures"]}
(out / "actual-encoding-summary.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
