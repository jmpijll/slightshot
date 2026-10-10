# Mac slower-source frame timing

Actual `cc9f117` 4K media inspection found 48 decoded frames over 2.000 s
in the 24 fps source, High output and Balanced output. High was not a
60-frame, constant-30-fps file: its average was 24 fps, with frame gaps
of 33.333 ms and 66.667 ms. Source and Balanced gaps were uniformly
41.667 ms. [The recorded timestamps](source-cadence-before.json) retain
the complete presentation timelines from each real MP4.

Apple's SDK documentation describes invalid `sourceTrackIDForFrameTiming`
plus `frameDuration` as a **maximum** output frame rate, rather than a
promise to duplicate slower input into constant-frame-rate output. The
[source track timing documentation](https://developer.apple.com/documentation/avfoundation/avmutablevideocomposition/sourcetrackidforframetiming)
also distinguishes deriving timing from a source track. The 48 High frames
were supported behavior, but rounding a regular 24 fps source onto a
30 fps grid unnecessarily made its motion timing irregular.

Export now uses the greater of the requested quality interval and a valid,
positive source minimum frame duration. A 24 fps source therefore uses
1/24 s even for High's 30 fps cap; a faster source still uses the selected
quality cap. Unknown source timing falls back to the quality cap. Loading
the exact rational duration also avoids deriving it from nominal-frame-rate
metadata that can vary with boundary samples. Apple's [minimum frame duration documentation](https://developer.apple.com/documentation/avfoundation/avpartialasyncproperty/minframeduration)
defines it as the reciprocal of the track's maximum frame rate and documents
an invalid value when unknown. The quality detail now says “up to” its fps cap.

A new real encoded-media regression test creates a regular 24 fps source
and exports High with and without a timed vector mark. It inspects compressed
sample presentation timestamps, frame count and duration. Both cases failed
against the original implementation: all 47 inter-frame gaps differed from
1/24 s, producing 94 failures. Both pass with the change. Existing real
30 fps source tests still verify the lower 15/24 fps quality caps, alongside
privacy rendering and cancellation/retention tests.

Validation:

- Targeted real-media tests: 3 tests, including both new cases, passed in 3.150 s.
- Complete `NSUnbufferedIO=YES swift test`: 58 tests in 16 suites passed in 8.958 s.
- `swiftlint --strict --quiet`: passed.

The final native 4K recapture used source commit
`3885ab05d1358839068d9ee9bb05d0c6c688853d` and the identical source movie
(SHA256 `8f3798dfc34dd3fdfcba54f6277b90fbb884eb18eff8767b457f51a5ce0c5f5d`).
[Independent inspection of the actual new MP4s](source-cadence-after.json)
confirms 48 frames over 2.000 s for both High (3840×2160) and Balanced
(1920×1080), with all presentation timestamps matching the source's uniform
24 fps cadence. All 47 gaps are 41.666/41.667 ms; decimal timestamp rounding
is at most 0.667 µs. The earlier High 33/67 ms quantization is gone.

Independent before/during/after export-pixel inspection also confirmed the
saved timed privacy effects and comparable screenshot strength. Its raw
ffprobe output, decoded PNG frames, production-renderer reference helper,
measurements and contact sheet are preserved with the final 4K capture.
This change preserves regular slower source cadence; it does not claim
constant-rate upsampling or exact preservation of every possible
variable-frame-rate source timeline.
