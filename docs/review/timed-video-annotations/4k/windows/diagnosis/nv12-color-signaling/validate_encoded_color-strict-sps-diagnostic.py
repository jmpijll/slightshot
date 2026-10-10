"""Inspect encoded H.264 color signaling and solid production annotation RGB.

Run: python3 validate_encoded_color.py ARTIFACT_DIRECTORY
Requires ffmpeg/ffprobe on PATH and Pillow. Native composition PNGs are the
production renderer references, not independently reconstructed illustrations.
Only derived evidence is written; source/native artifacts are unchanged.
"""
from pathlib import Path
from fractions import Fraction
import sys, subprocess, json, hashlib, re, shutil, statistics
from PIL import Image, ImageChops, ImageFilter, ImageDraw

root = Path(sys.argv[1]).resolve()
out = root / "media-validation"
out.mkdir(exist_ok=True)
ffprobe, ffmpeg = shutil.which("ffprobe"), shutil.which("ffmpeg")
if ffprobe is None or ffmpeg is None:
    raise SystemExit("Install ffmpeg and ffprobe and make both executables available on PATH.")
native = json.loads((root / "video-editor-4k-validation.json").read_text())
prior_file = out / "media-validation.json"
prior = json.loads(prior_file.read_text()) if prior_file.exists() else {}
expected_tags = {"color_range": "tv", "color_space": "bt709", "color_transfer": "bt709", "color_primaries": "bt709"}
expected_sps = {"video_full_range_flag": 0, "colour_description_present_flag": 1,
    "colour_primaries": 1, "transfer_characteristics": 1, "matrix_coefficients": 1}
findings, results, tiles = [], {}, []

def command(args):
    return subprocess.check_output(args)

def inspect(name, reference_name, color, rectangle, erosion):
    path = root / ("video-editor-4k-" + name + ".mp4")
    raw_probe = command([ffprobe, "-v", "error", "-select_streams", "v:0", "-show_streams", "-show_frames", "-of", "json", str(path)])
    probe = json.loads(raw_probe)
    (out / (name + "-color-ffprobe.json")).write_bytes(raw_probe)
    stream = probe["streams"][0]
    actual_tags = {key: stream.get(key) for key in expected_tags}
    tags_pass = actual_tags == expected_tags
    trace = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "verbose", "-i", str(path), "-map", "0:v:0",
        "-c:v", "copy", "-bsf:v", "trace_headers", "-frames:v", "1", "-f", "null", "-"], check=True, capture_output=True).stderr.decode()
    (out / (name + "-h264-sps-trace.txt")).write_text(trace)
    fields = {key: sorted(set(int(value) for value in re.findall(r"\b" + key + r"\s+[01]+\s*=\s*(\d+)", trace))) for key in expected_sps}
    sps_pass = all(fields[key] == [value] for key, value in expected_sps.items())
    frames = probe["frames"]
    time_base = Fraction(stream["time_base"])
    pts = [int(frame["best_effort_timestamp"]) * time_base for frame in frames]
    target = Fraction(7, 10)
    index = min(range(len(pts)), key=lambda item: abs(pts[item] - target))
    decoded_path = out / (name + "-color-during.png")
    command([ffmpeg, "-v", "error", "-threads", "2", "-i", str(path), "-vf", "select=eq(n\\," + str(index) + ")",
        "-fps_mode", "passthrough", "-frames:v", "1", "-y", str(decoded_path)])
    reference_path = root / reference_name
    reference = Image.open(reference_path).convert("RGB")
    decoded = Image.open(decoded_path).convert("RGB")
    if reference.size != decoded.size:
        raise ValueError(f"Production reference/output dimensions disagree for {name}: {reference.size} vs {decoded.size}")
    cropped_reference = reference.crop(rectangle)
    cropped_decoded = decoded.crop(rectangle)
    solid = Image.new("RGB", cropped_reference.size, tuple(color))
    difference = ImageChops.difference(cropped_reference, solid)
    channels = difference.split()
    largest = ImageChops.lighter(ImageChops.lighter(channels[0], channels[1]), channels[2])
    mask = largest.point(lambda value: 255 if value <= 2 else 0).filter(ImageFilter.MinFilter(2 * erosion + 1))
    mask.save(out / (name + "-solid-color-reference-mask.png"))
    selected = [index for index, value in enumerate(mask.getdata()) if value == 255]
    original_pixels = list(cropped_reference.getdata())
    decoded_pixels = list(cropped_decoded.getdata())
    sample_count = len(selected)
    if sample_count < 100:
        raise ValueError(f"Insufficient eroded solid production-reference pixels for {name}: {sample_count}")
    reference_means = [statistics.fmean(original_pixels[index][channel] for index in selected) for channel in range(3)]
    decoded_means = [statistics.fmean(decoded_pixels[index][channel] for index in selected) for channel in range(3)]
    absolute_means = [statistics.fmean(abs(decoded_pixels[index][channel] - original_pixels[index][channel]) for index in selected) for channel in range(3)]
    largest_errors = sorted(max(abs(decoded_pixels[index][channel] - original_pixels[index][channel]) for channel in range(3)) for index in selected)
    p95 = largest_errors[max(0, (sample_count * 95 + 99) // 100 - 1)]
    rgb_pass = max(absolute_means) <= 6 and p95 <= 12
    result = {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "width": stream["width"], "height": stream["height"], "actualDecodedFrames": len(frames),
        "codec": stream["codec_name"], "profile": stream.get("profile"), "hasBFrames": stream.get("has_b_frames"),
        "ffprobeColorTags": actual_tags, "ffprobeColorTagsPass": tags_pass,
        "h264SpsColorFields": fields, "h264SpsLimitedBt709Pass": sps_pass,
        "referenceFile": reference_path.name, "referenceSha256": hashlib.sha256(reference_path.read_bytes()).hexdigest(),
        "requestedSeconds": float(target), "zeroBasedDecodedFrameIndex": index, "actualPresentationSeconds": float(pts[index]),
        "sourceRectangle": rectangle, "nominalAnnotationRGB": color, "maskErosionPixels": erosion,
        "solidReferencePixelCount": sample_count, "productionReferenceMeanRGB": reference_means, "actualEncodedDecodedMeanRGB": decoded_means,
        "meanAbsoluteRGBDelta": absolute_means, "p95MaximumRGBChannelDelta": p95,
        "codecTolerance": {"maximumMeanAbsoluteDeltaInEachChannel": 6, "maximumP95LargestChannelDelta": 12},
        "solidAnnotationColorPass": rgb_pass,
        "passed": tags_pass and sps_pass and rgb_pass}
    if not tags_pass: findings.append(name + " ffprobe color tags do not expose limited BT.709 range/matrix/primaries/transfer")
    if not sps_pass: findings.append(name + " H.264 SPS VUI does not expose limited BT.709 range/matrix/primaries/transfer")
    if not rgb_pass: findings.append(name + " decoded solid annotation color differs from production reference beyond codec tolerance")
    # These are literal crops of the real decoded/reference images, enlarged
    # only for review. The eroded mask excludes glyph edges and the Step digit.
    ref_tile, decoded_tile = cropped_reference.copy(), cropped_decoded.copy()
    tile_width = 660
    scale = tile_width / cropped_reference.width
    tile_height = round(cropped_reference.height * scale)
    ref_tile = ref_tile.resize((tile_width, tile_height), Image.Resampling.NEAREST)
    decoded_tile = decoded_tile.resize((tile_width, tile_height), Image.Resampling.NEAREST)
    tile = Image.new("RGB", (tile_width * 2 + 10, tile_height + 52), "#f4f4f4")
    draw = ImageDraw.Draw(tile)
    draw.text((4, 4), f"{name} production reference | actual decoded MP4 PTS {float(pts[index]):.6f}s", fill="black")
    draw.text((4, 23), f"Solid pixels {sample_count}; mean RGB delta {tuple(round(value, 3) for value in absolute_means)}; p95 max channel {p95}", fill="black")
    tile.paste(ref_tile, (0, 52)); tile.paste(decoded_tile, (tile_width + 10, 52))
    tiles.append(tile)
    return result

results["high"] = inspect("high", "video-editor-4k-high-composition-reference.png", [10, 132, 255], (1830, 550, 3330, 750), 3)
results["balanced"] = inspect("balanced", "video-editor-4k-balanced-composition-reference.png", [10, 132, 255], (915, 275, 1665, 375), 2)
results["step"] = inspect("step", "video-editor-4k-step-composition-reference.png", [255, 59, 48], (3050, 150, 3550, 650), 3)
width, height = max(tile.width for tile in tiles), sum(tile.height for tile in tiles)
contact = Image.new("RGB", (width, height), "#f4f4f4")
y = 0
for tile in tiles:
    contact.paste(tile, (0, y)); y += tile.height
contact.save(out / "encoded-annotation-color.png")
report = {"sourceCommit": native["sourceCommit"], "prHeadCommit": prior.get("prHeadCommit"), "githubRunId": prior.get("githubRunId"),
    "method": "Inspect ffprobe stream color metadata and actual H.264 SPS VUI via trace_headers. Decode a real during-interval MP4 sample and compare against the native production-renderer PNG at reference pixels within 2 RGB values of the nominal solid annotation color, then erode 2 or 3 pixels to exclude glyph/ring edges and the white Step digit. Decoded RGB includes limited-range YUV conversion, 4:2:0 chroma sampling and H.264 quantization; exact byte equality is not claimed.",
    "tools": {"ffprobe": command([ffprobe, "-version"]).decode().splitlines()[0], "ffmpeg": command([ffmpeg, "-version"]).decode().splitlines()[0]},
    "expectedFfprobeColorTags": expected_tags, "expectedH264SpsColorFields": expected_sps,
    "checks": results, "findings": findings, "allEncodedColorChecksPass": not findings,
    "nativePerformanceAcceptanceFailures": native["acceptanceFailures"]}
(out / "encoded-color-validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"sourceCommit": report["sourceCommit"], "allEncodedColorChecksPass": report["allEncodedColorChecksPass"],
    "meanAbsoluteRGBDelta": {name: result["meanAbsoluteRGBDelta"] for name, result in results.items()}, "findings": findings}, indent=2))
sys.exit(0 if not findings else 1)
