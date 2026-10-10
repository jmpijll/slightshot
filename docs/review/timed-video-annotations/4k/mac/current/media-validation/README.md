# Actual 4K export validation

Source commit: `3885ab05d1358839068d9ee9bb05d0c6c688853d`. These files inspect actual MP4s exported by the native macOS editor driven by the automated 4K review fixture. The synthetic source has no personal data. Native UI captures and performance/cancellation measurements are in the parent directory.

`media-validation.json` records source/export SHA256 hashes, complete decoded presentation timestamps, dimensions, frame counts, raw pixel measurements, explicit thresholds and limitations. `source-ffprobe.json`, `high-ffprobe.json` and `balanced-ffprobe.json` preserve raw ffprobe results.

The source, High export (3840×2160) and Balanced export (1920×1080) each contain **48 frames over 2.000 seconds**. Every presentation timestamp matches the 24 fps source; the 47 gaps are 41.666/41.667 ms with at most 0.667 µs decimal rounding. High has a configured maximum of 30 fps and preserves this slower source cadence. No duplicate-frame upsampling is claimed.

`privacy-before-during-after.png` is a contact sheet of actual decoded source and export pixels, sampled by exact zero-based frame indices 6, 24 and 42 (0.25, 1.00 and 1.75 seconds). Fixed rectangles cover moving synthetic account details. Native interactions set both marks to the interval [0.6, 1.4). The details remain visible before and after; the middle frame is blurred/pixelated. This contact sheet is derived from exported video, not a mockup or a generated illustration.

The privacy rectangles are independently rendered using the production `Renderer`, `Annotation` and `RasterEffects` source. The full-resolution reference uses the saved raster scale, 4.137931. A separate screenshot reference downsizes the source to the actual 928×522 displayed canvas, then renders the same displayed rectangles with screenshot-default strength. Both qualities match this reference within codec/resampling tolerance: average RGB difference is 5.46/255 for blur and 7.69/255 for pixelation. Export blur reduces the native-resolution mean fine-edge gradient to 4.4–4.9% of the source; pixelation reduces it to 10.2–10.4%. The inactive rectangles retain their fine edges. All 20 recorded pixel checks pass.

Reproduction scripts are `validate-media.py`, `analyze-privacy.py` and `render-reference.swift`. The Python scripts use the durable files in this directory, ffprobe/ffmpeg on PATH and NumPy/Pillow. Run `python3 validate-media.py` then `python3 analyze-privacy.py` from this directory to repeat the recorded checks. Compile the reference helper against the source commit with:

```sh
swiftc -O -swift-version 6 -default-isolation MainActor -parse-as-library \
  Sources/Slightshot/Editor/Renderer.swift Sources/Slightshot/Editor/Annotation.swift \
  Sources/Slightshot/Editor/RasterEffect.swift Sources/Slightshot/Support/Geometry.swift \
  render-reference.swift -o render-reference
./render-reference /absolute/path/to/media-validation
```

The production renderer source paths and file hashes are recorded in the JSON. H.264 quantization, YUV-to-RGB conversion, interpolation and integer block rounding prevent byte-identical comparisons between different output resolutions. Pixel measurements establish interval behavior and comparable visible strength for this fixture; they do not prove anonymity against OCR or establish arbitrary variable-rate input behavior. Automated media tests separately cover exact half-open boundaries, current frame effects, cancellation/destination preservation and quality caps.
