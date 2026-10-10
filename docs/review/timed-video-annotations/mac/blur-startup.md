# Mac first-blur startup diagnosis

The first observed native 4K Blur gesture on `dfdb26a` took 1153.36 ms.
A fresh-process rerun of the same application and source took 51.95 ms.
The earlier baseline's first gesture took 214.21 ms. These include native
mouse down/drag/up, timing controls and synchronous canvas display; the
toolbar click is excluded. They are not cache-controlled comparisons.
The operating system's shader cache was never cleared during this work.

The application decodes its 3840 × 2160 source into a 960 × 540 preview.
A direct reproduction using the same `AVAssetImageGenerator.image(at:)`
call and `maximumSize` setting verified those actual decoded dimensions
at 0.25 s. The native blur rectangle is about 263 × 32 preview pixels.
Its effective factor is 1.03448 and Gaussian radius 8.27586 preview pixels.
Track dimensions alone do not describe the preview's raster workload.

An isolated optimized probe separated context construction, filter setup
and rendering. Ten fresh processes alternated the old radius 2 and new
radius 8.27586. Context creation took 48–56 ms, first rendering 9–13 ms,
and later rendering about 1 ms. That does not reproduce the original
1.15-second delay as a persistent cost of the stronger blur.

A native [`sample` during the first call](blur-startup-profile.txt) showed `CIContext.initWithOptions`
creating/registering the Metal device and loading kernel libraries.
The initial `createCGImage` traversed Metal DAG, pipeline and compiler
cache paths, with `MPSLibrary.preheat` work on another thread. Sampling
increased the measured times substantially, so profiled timings are not
used in the comparisons. Core Image/Metal startup is demonstrated; attributing
the entire original 1.15 seconds to a cold OS shader cache remains an inference.

The production change prewarms the existing shared context on a worker
when the video preview's actual fit scale is known. It renders a 16 × 16
Gaussian output from a nonconstant 32 × 32 seed with the same effect factor.
Actual preview and export pixels still use the existing rendering path.
Each filter remains local. Apple's [CIContext documentation](https://developer.apple.com/documentation/coreimage/cicontext)
permits one context to render on multiple threads while requiring mutable
filter instances to remain separate.

The [production reproduction](blur-startup-repro.swift) compiles the actual
`RasterEffect.swift` implementation. Ten pairs use a separate process for
each cold or prewarmed mode, with ten real ROI renders per process: 20
processes and 200 renders. Full values are in [blur-startup.json](blur-startup.json).

| Measurement | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: |
| First render without prewarm, including lazy context startup | 63.48 ms | 66.89 ms | 93.56 ms |
| Worker prewarm cost | 66.58 ms | 73.68 ms | 78.47 ms |
| First real ROI render after prewarm | 1.59 ms | 1.88 ms | 2.48 ms |
| Following 90 prewarmed ROI renders | 0.67 ms | 0.92 ms | 4.10 ms |

These numbers use a warm OS cache and fresh application contexts. They
demonstrate moving startup out of the pointer gesture, not a guaranteed
maximum for a machine with an uninitialized shader cache. Prewarm is
best effort and does not block the UI waiting for completion.

```sh
xcrun swiftc -swift-version 6 -parse-as-library -O \
  Sources/Slightshot/Editor/RasterEffect.swift \
  docs/review/timed-video-annotations/mac/blur-startup-repro.swift \
  -o /tmp/slightshot-production-blur-probe
/tmp/slightshot-production-blur-probe cold
/tmp/slightshot-production-blur-probe warm
```

The standalone optimized compilation passed. Native application re-capture
and repository checks are reported separately with the final source commit.
