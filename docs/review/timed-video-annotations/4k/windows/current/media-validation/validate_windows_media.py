"""Independent decoded-frame validation of native Windows review artifacts.

Run: python3 validate_windows_media.py ARTIFACT_DIRECTORY RUN_ID PR_HEAD_SHA
Only derived evidence is written; the source/native artifacts are unchanged.
"""
from pathlib import Path
from fractions import Fraction
from collections import Counter
from bisect import bisect_right
import sys, subprocess, json, hashlib, statistics, shutil
from PIL import Image, ImageChops, ImageStat, ImageDraw

root = Path(sys.argv[1]).resolve()
out = root / "media-validation"
out.mkdir(exist_ok=True)
summary = root / "video-editor-4k-validation.json"
if summary.exists():
    native = json.loads(summary.read_text())
else:
    high = json.loads((root / "video-editor-4k-high-cadence-validation.json").read_text())
    balanced = json.loads((root / "video-editor-4k-balanced-validation.json").read_text())["validation"]
    native = {"sourceCommit": high["sourceCommit"], "frames": high["submittedFrames"],
        "balancedResize": balanced, "acceptanceFailures": None,
        "encoderDiagnostics": high["encoderDiagnostics"], "stageValidationFailures": balanced["ValidationFailures"]}
ffprobe, ffmpeg = shutil.which("ffprobe"), shutil.which("ffmpeg")
if ffprobe is None or ffmpeg is None:
    raise SystemExit("Install ffmpeg and ffprobe and make both executables available on PATH.")
names = ["source", "high", "balanced"]
targets = [Fraction(15, 100), Fraction(7, 10), Fraction(125, 100)]
states = ["before", "during", "after"]
videos, exact_pts = {}, {}

def command(args):
    return subprocess.check_output(args)

def inspect(name):
    path = root / ("video-editor-4k-" + name + ".mp4")
    probe_command = [ffprobe, "-v", "error", "-select_streams", "v:0", "-count_frames",
        "-show_streams", "-show_frames", "-show_packets", "-show_format", "-of", "json", str(path)]
    raw = command(probe_command)
    (out / (name + "-ffprobe.json")).write_bytes(raw)
    probe = json.loads(raw)
    stream = probe["streams"][0]
    frames = [item for item in probe["packets_and_frames"] if item["type"] == "frame"]
    packets = [item for item in probe["packets_and_frames"] if item["type"] == "packet"]
    time_base = Fraction(stream["time_base"])
    pts = [int(frame["best_effort_timestamp"]) * time_base for frame in frames]
    exact_pts[name] = pts
    gaps = [second - first for first, second in zip(pts, pts[1:])]
    scale = stream["width"] / 3840
    w, h, x, y = [int(value * scale) for value in (64, 32, 180, 12)]
    crop = command([ffmpeg, "-v", "error", "-threads", "2", "-i", str(path), "-vf",
        f"crop={w}:{h}:{x}:{y},format=rgb24", "-fps_mode", "passthrough", "-f", "rawvideo", "-"])
    frame_bytes = w * h * 3
    means = [statistics.fmean(crop[start + 2:start + frame_bytes:3]) for start in range(0, len(crop), frame_bytes)]
    checksums = command([ffmpeg, "-v", "error", "-threads", "2", "-i", str(path),
        "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", "-"])
    (out / (name + "-decoded-framemd5.txt")).write_bytes(checksums)
    md5s = [line.rsplit(",", 1)[1].strip() for line in checksums.decode().splitlines() if line and not line.startswith("#")]
    selected = [min(range(len(pts)), key=lambda index: abs(pts[index] - target)) for target in targets]
    selection = "+".join(f"eq(n\\,{index})" for index in selected)
    command([ffmpeg, "-v", "error", "-threads", "2", "-i", str(path), "-vf", "select=" + selection,
        "-fps_mode", "passthrough", "-frames:v", "3", "-y", str(out / (name + "-%02d.png"))])
    rate = 24 if name == "balanced" else 30
    expected_gap = Fraction(1, rate)
    decoded_count = len(frames)
    submitted = native["frames"] if name == "high" else native["balancedResize"]["SubmittedFrames"] if name == "balanced" else None
    result = {
        "file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "stream": stream, "format": probe["format"], "actualDecodedFrameCount": decoded_count,
        "actualEncodedPacketCount": len(packets), "pictureTypeHistogram": dict(Counter(frame["pict_type"] for frame in frames)),
        "containsEncodedBFrames": any(frame["pict_type"] == "B" for frame in frames), "ffprobeNbReadFrames": int(stream["nb_read_frames"]),
        "rawDecodedChecksumCount": len(md5s), "adjacentIdenticalWholeDecodedFrames": sum(a == b for a, b in zip(md5s, md5s[1:])),
        "configuredFramesPerSecond": rate, "presentationTimesSeconds": list(map(float, pts)),
        "exactPresentationTimesSeconds": list(map(str, pts)), "gapHistogramSeconds": dict(Counter(map(str, gaps))),
        "uniformQualityCadenceWithinOneMicrosecond": all(abs(gap - expected_gap) <= Fraction(1, 1000000) for gap in gaps),
        "maximumDeviationFromQualityCadenceSeconds": float(max(abs(gap - expected_gap) for gap in gaps)),
        "nativeSubmittedFrames": submitted, "decodedCountMatchesNativeSubmittedFrames": decoded_count == submitted if submitted is not None else None,
        "movingStripeBlueMeans": means,
        "extractedFrames": [{"requestedSeconds": float(target), "intervalState": state, "zeroBasedDecodedFrameIndex": index,
            "actualPresentationSeconds": float(pts[index]), "file": name + f"-{number:02}.png"}
            for number, (target, state, index) in enumerate(zip(targets, states, selected), 1)],
    }
    if name == "balanced":
        ignored = json.loads(command([ffprobe, "-v", "error", "-ignore_editlist", "1", "-select_streams", "v:0",
            "-count_frames", "-show_streams", "-show_frames", "-of", "json", str(path)]))
        (out / "balanced-ignore-editlist-ffprobe.json").write_text(json.dumps(ignored, indent=2) + "\n")
        result["decodedFramesIgnoringEditList"] = len(ignored["frames"])
        result["firstDtsSeconds"] = packets[0].get("dts_time")
        result["lastPresentationSeconds"] = float(pts[-1])
    assert decoded_count == len(means) == len(md5s) == int(stream["nb_read_frames"])
    return result

for name in names:
    videos[name] = inspect(name)

def longest_plateau(means, rate):
    longest = run = 1
    for first, second in zip(means, means[1:]):
        run = run + 1 if abs(second - first) < .75 else 1
        longest = max(longest, run)
    return {"frames": longest, "seconds": longest / rate, "criterion": "Adjacent stripe blue means differ by less than 0.75 channel values; H.264 quantization can create short plateaus."}

for name in names:
    videos[name]["longestQuantizedStripePlateau"] = longest_plateau(videos[name]["movingStripeBlueMeans"], 24 if name == "balanced" else 30)
for name in ["high", "balanced"]:
    source_origin = exact_pts["source"][0]
    quantization_tolerance = Fraction(1, 10000000)
    source_indices = [max(0, bisect_right(exact_pts["source"], position + source_origin + quantization_tolerance) - 1) for position in exact_pts[name]]
    expected = [videos["source"]["movingStripeBlueMeans"][index] for index in source_indices]
    actual = videos[name]["movingStripeBlueMeans"]
    delta = [abs(first - second) for first, second in zip(expected, actual)]
    videos[name]["sourceMotionCorrespondence"] = {
        "method": "Compare the unannotated top stripe against the last actual source PTS at or before output PTS plus the source initial PTS, with 100 ns rational time-base quantization tolerance. Output zero denotes the first source frame; raw source PTS remains unchanged. H.264 RGB quantization means this signal does not prove exact identity for every individual frame.",
        "sourceInitialPresentationSeconds": float(source_origin), "sourceSchedulingQuantizationToleranceSeconds": float(quantization_tolerance),
        "expectedSourceFrameIndices": source_indices, "expectedSourceStripeBlueMeans": expected,
        "maximumMeanBlueDelta": max(delta), "meanBlueDelta": statistics.fmean(delta),
        "sourceSignalAdvance": expected[-1] - expected[0], "outputSignalAdvance": actual[-1] - actual[0],
        "sourceSignalTracksWithinEightBlueValues": max(delta) <= 8,
        "overallMotionRetained": actual[-1] - actual[0] >= .75 * (expected[-1] - expected[0]),
    }

def scaled_box(rect, scale):
    x, y, width, height = rect
    return tuple(round(value * scale) for value in (x, y, x + width, y + height))

def delta(first, second, box):
    return statistics.fmean(ImageStat.Stat(ImageChops.difference(first.crop(box), second.crop(box))).mean[:3])

privacy = []
for name in ["high", "balanced"]:
    scale = videos[name]["stream"]["width"] / 3840
    for number, state in enumerate(states, 1):
        source = Image.open(out / f"source-{number:02}.png").convert("RGB")
        frame = Image.open(out / f"{name}-{number:02}.png").convert("RGB")
        source = source.resize(frame.size, Image.Resampling.BILINEAR)
        blur = delta(source, frame, scaled_box((240, 1180, 450, 530), scale))
        pixel = delta(source, frame, scaled_box((1030, 1180, 450, 530), scale))
        caption = delta(source, frame, scaled_box((1830, 550, 1500, 200), scale))
        item = {"quality": name, "intervalState": state,
            "actualPresentationSeconds": videos[name]["extractedFrames"][number - 1]["actualPresentationSeconds"],
            "blurMeanRGBDeltaFromUnannotatedSource": blur, "pixelationMeanRGBDeltaFromUnannotatedSource": pixel,
            "captionMeanRGBDeltaFromUnannotatedSource": caption,
            "timedRasterEffectsPass": blur > 35 and pixel > 35 if state == "during" else blur < 25 and pixel < 25,
            "timedCaptionPass": caption > 10 if state == "during" else caption < 25}
        if state == "during":
            prefix = "video-editor-4k-balanced" if name == "balanced" else "video-editor-4k"
            reference = Image.open(root / (prefix + "-screenshot-strength-reference.png")).convert("RGB")
            fit_video = frame.resize(reference.size, Image.Resampling.BILINEAR)
            fit_scale = reference.width / 3840
            item["blurScreenshotReferenceMeanRGBDelta"] = delta(reference, fit_video, scaled_box((240, 1180, 450, 530), fit_scale))
            item["pixelationScreenshotReferenceMeanRGBDelta"] = delta(reference, fit_video, scaled_box((1030, 1180, 450, 530), fit_scale))
            item["screenshotEquivalentStrengthPass"] = max(item["blurScreenshotReferenceMeanRGBDelta"], item["pixelationScreenshotReferenceMeanRGBDelta"]) <= 18
            if name == "balanced":
                composition = Image.open(root / "video-editor-4k-balanced-composition-reference.png").convert("RGB")
                item["resizedNativeCompositionMeanRGBDelta"] = delta(composition, frame, scaled_box((120, 1000, 1680, 960), scale))
                item["resizedNativeCompositionPass"] = item["resizedNativeCompositionMeanRGBDelta"] < 30
        privacy.append(item)

contact = Image.new("RGB", (1710, 1134), "#f4f4f4")
draw = ImageDraw.Draw(contact)
for row, name in enumerate(names):
    label = {"source": "Decoded unannotated source 3840x2160", "high": "Decoded High 3840x2160", "balanced": "Decoded Balanced 1920x1080"}[name]
    draw.text((12, row * 378 + 8), label, fill="black")
    for column, point in enumerate(videos[name]["extractedFrames"]):
        image = Image.open(out / point["file"]).convert("RGB")
        scale = image.width / 3840
        crop = image.crop(scaled_box((120, 1000, 1680, 960), scale)).resize((560, 320), Image.Resampling.BILINEAR)
        x, y = column * 570 + 5, row * 378 + 52
        contact.paste(crop, (x, y))
        draw.text((x, y - 22), f"{point['intervalState']}  actual PTS {point['actualPresentationSeconds']:.6f}s", fill="black")
contact.save(out / "decoded-before-during-after.png")

findings = []
for name in ["high", "balanced"]:
    if not videos[name]["decodedCountMatchesNativeSubmittedFrames"]:
        findings.append({"quality": name, "kind": "submitted-decoded-count-mismatch",
            "nativeSubmittedFrames": videos[name]["nativeSubmittedFrames"],
            "actualDecodedFrameCount": videos[name]["actualDecodedFrameCount"],
            "actualEncodedPacketCount": videos[name]["actualEncodedPacketCount"],
            "note": "This is a real encoded packet-count difference; disabling MP4 edit lists does not reveal an extra frame. The exact encoder cause is not established by this media inspection."})
report = {
    "sourceCommit": native["sourceCommit"], "prHeadCommit": sys.argv[3], "githubRunId": sys.argv[2],
    "method": "Independent ffprobe-count_frames/frame+packet inspection, exact stream-time-base PTS, ffmpeg passthrough decoded frame checksums/crop signal and exact-index PNGs. Actual decoded counts are separate from native submitted-frame counters.",
    "tools": {"ffprobe": command([ffprobe, "-version"]).decode().splitlines()[0], "ffmpeg": command([ffmpeg, "-version"]).decode().splitlines()[0]},
    "videos": videos, "privacyPixelChecks": privacy, "findings": findings,
    "allOutputFrameGapsMatchConfiguredCadence": all(videos[name]["uniformQualityCadenceWithinOneMicrosecond"] for name in ["high", "balanced"]),
    "decodedCountsMatchSubmittedCounters": not findings,
    "privacyChecksPass": all(point["timedRasterEffectsPass"] and point["timedCaptionPass"] and point.get("screenshotEquivalentStrengthPass", True) and point.get("resizedNativeCompositionPass", True) for point in privacy),
    "nativePerformanceAcceptanceFailures": native["acceptanceFailures"],
    "nativeFinalAcceptanceAvailable": summary.exists(), "nativeStageValidationFailures": native.get("stageValidationFailures", []),
    "limits": ["The synthetic stripe changes only slightly per frame; H.264 quantization creates genuine short plateaus, so coarse signal matching is not proof of exact identity for each frame.",
        "This bounded native recording does not establish behavior for arbitrary videos or arbitrary durations.",
        "PNG source/output comparisons include H.264 quantization and YUV-to-RGB conversion; they are not exact byte equality."]
}
(out / "media-validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"sourceCommit": report["sourceCommit"], "counts": {name: videos[name]["actualDecodedFrameCount"] for name in names},
    "cadencePass": report["allOutputFrameGapsMatchConfiguredCadence"], "privacyPass": report["privacyChecksPass"],
    "findings": findings, "nativePerformanceFailures": native["acceptanceFailures"]}, indent=2))
