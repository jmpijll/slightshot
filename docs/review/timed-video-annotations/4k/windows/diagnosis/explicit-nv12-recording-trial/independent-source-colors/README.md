# Independent Windows encoded-media validation

These scripts inspect actual MP4 packets, decoded frames, pixels and H.264 SPS metadata produced by the native review fixture. They do not edit the source application or original artifacts. They write derived files into `ARTIFACT_DIRECTORY/media-validation/`.

Requirements: Python 3, Pillow, and `ffmpeg` / `ffprobe` on PATH. Install Pillow using the package manager appropriate to the environment.

Run in order, with the GitHub native PR run ID and full PR head SHA recorded alongside the merge checkout SHA inside the native JSON:

```sh
python3 validate_windows_media.py ARTIFACT_DIRECTORY RUN_ID PR_HEAD_SHA
python3 validate_output_cadence.py ARTIFACT_DIRECTORY
python3 validate_encoded_color.py ARTIFACT_DIRECTORY
```

`validate_windows_media.py` separates submitted counters from independent packet and decoded counts. It checks before/during/after timed effects, screenshot-renderer strength, Balanced source-coordinate downscaling and a coarse moving-stripe signal. The native source recorder can have a positive initial PTS. The output comparison normalizes the source origin: output time zero denotes the first source frame, using exact rational PTS and a 100ns quantization tolerance. Original raw source PTS is preserved. Prior raw-source correspondence scripts/reports remain separate diagnosis records. Small H.264 quantized signal plateaus do not establish individual-frame identity.

`validate_output_cadence.py` requires the actual output count to equal ceil(source track duration × configured output FPS), zero initial output PTS, cadence within 100ns, actual final partial duration and decoded/container coverage within 1ms of source end. A lost short tail is a failure even if the average reported FPS appears plausible.

`validate_encoded_color.py` requires the actual MP4 ffprobe tags to expose limited-range BT.709 range/matrix/primaries/transfer in High/Balanced/Step. It separately inspects and reports actual SPS VUI; that observation is not an additional acceptance requirement for this MP4 export. It compares actual decoded blue caption and red Step pixels to native production-renderer composition-reference PNGs. A color mask accepts reference pixels within 2 RGB values of the nominal color, then erodes 2–3 pixels to exclude glyph/ring edges and the Step's white digit. Each channel's mean absolute delta must be ≤6 and the 95th percentile largest-channel delta ≤12. These are codec tolerances, not exact byte equality. Contact sheets are literal decoded/reference crops with only nearest-neighbor enlargement and labels.

Semantic validation reports preserve the native fixture's acceptance failures separately. Independent media success does not imply the throughput, UI responsiveness, cancellation or private-memory gates pass.

The initial f1bab14 strict SPS diagnostic is preserved as `encoded-color-validation-strict-sps-diagnostic.json` and its matching script. All three real MP4s expose `tv` / `bt709` container signaling and their decoded solid colors pass. Their H.264 SPS has `video_signal_type_present_flag=0`, so it omits explicit color VUI. The accepted MP4 color report states this distinction; no SPS-VUI or raw-H.264 color claim is made and no bitstream was altered.


`inspect_moving_stripe.py ARTIFACT_DIRECTORY [ARTIFACT_DIRECTORY ...]` is a separate timing diagnosis. It saves every actual source/High/Balanced/Step decoded RGB crop, the first/last five frames, integer-shift affine correlations and raw-source versus normalized-origin scheduling alternatives. The affine fit separates a fixed source decoder color offset from motion correlation. It does not establish exact full-frame identity, and quantized first/last plateaus remain explicit. The native source's raw PTS is retained in the report. Failed pre-normalization artifacts showed best same-cadence shift -1; the product fix is evaluated on fresh artifacts with same-index alignment.

`summarize_encoded_streams.py ARTIFACT_DIRECTORY` records actual High/Balanced/Step codec, profile, level, bitrate, pixel format, count, timestamps, tail duration and container color metadata from the independently saved probes. It adds no new acceptance gates.


`inspect_native_source_colors.py NATIVE_640_ARTIFACT_DIRECTORY RUN_ID PR_HEAD_SHA` independently decodes the actual source MP4's known red/green/blue/neutral fixture patches with FFmpeg. It reports actual container color tags, nominal-input RGB errors at the same eight-pixel-interior ROIs and unchanged native tolerance8, plus literal decoded source crops/contact. A forced601 conversion is a separate diagnostic hypothesis; it does not override discovered source tags or nominal acceptance. The explicit `actualTaggedSourceRetainsKnownNominalRGB` and native nominal booleans must be read; this inspector writes diagnosis rather than adding a CI gate. Native source-preview, sequential-decoder and output endpoint fixture assertions cover the runtime paths separately.
