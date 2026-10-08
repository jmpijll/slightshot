# Raster performance validation

The changes preserve the existing blur and pixelate algorithms. Mac pixelate
uses four scalar sums instead of allocating two small arrays for every block.
Windows blur rents one temporary byte array and returns it in `finally`; every
pass writes all active bytes, including when the pool returns a larger array.

Measured on an Apple M4 running macOS 27 (26A428), using an optimized Swift 6.4
build. Baseline and current implementations run in the same process, alternating
their order, with one warm-up and forty samples per size. The source is an opaque
synthetic 4K sRGB gradient, never a desktop capture.

| Pixelate ROI | Baseline median | Current median | Baseline p95 | Current p95 |
| --- | ---: | ---: | ---: | ---: |
| 400 × 200 | 0.624 ms | 0.531 ms | 0.816 ms | 0.649 ms |
| 1920 × 1080 | 13.343 ms | 10.266 ms | 15.357 ms | 11.372 ms |
| 3840 × 2160 | 53.232 ms | 40.410 ms | 62.161 ms | 45.468 ms |

The 4K median improved by approximately 24%. Each pair produced identical RGBA
SHA-256 hashes. These are local operation measurements, not a promise about
whole-editor latency. Full results and environment details are in
[`raster-validation.json`](raster-validation.json).

For Windows core blur, twenty 400 × 200 updates after ten warm-up updates
allocated 6,404,800 bytes before and 4,320 bytes after. This measures managed
allocation on the current thread in the raster operation, excluding WPF and the
editor. The core tests bound warm allocation and check a smaller image after a
larger pooled buffer. Native Windows CI separately checks preview/export pixels
at 1×, 1.25×, 1.5× and 2×.

## Reproduce

Current Mac timings:

```sh
swiftc -O -swift-version 6 -parse-as-library \
  Sources/Slightshot/Editor/RasterEffect.swift Scripts/profile_raster.swift \
  -o /tmp/slightshot-raster-profile
/tmp/slightshot-raster-profile
```

For a paired comparison, extract the unchanged v1.2.0 implementation and rename
its types so that both implementations can run in the same binary:

```sh
git show v1.2.0:Sources/Slightshot/Editor/RasterEffect.swift > /tmp/slightshot-raster-reference.swift
python3 - <<'PY'
from pathlib import Path
p = Path('/tmp/slightshot-raster-reference.swift')
p.write_text(p.read_text().replace('RasterEffect', 'BaselineRasterEffect'))
PY
swiftc -O -swift-version 6 -parse-as-library -D COMPARE_BASELINE \
  Sources/Slightshot/Editor/RasterEffect.swift \
  /tmp/slightshot-raster-reference.swift Scripts/profile_raster.swift \
  -o /tmp/slightshot-raster-comparison
/tmp/slightshot-raster-comparison
```

The comparison checks output hashes before reporting timings. It times crop and
render, excludes hashing and autorelease-pool disposal, uses the upper middle
sample for the median and nearest-rank p95.

Windows allocation regression:

```sh
dotnet run --project Windows/Slightshot.Core.Tests -c Release
```
