# Mac encoder readiness diagnosis

Measured on 2026-10-10, Mac16,13 with 16 GiB RAM, macOS 27.0 (26A428),
Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27. The production async
receiver path was present in source commits `b6d8535` through `d3af788`.

CI run [38069423128](https://github.com/jmpijll/slightshot/actions/runs/38069423128)
finished its test build at 16:53:55 UTC, then made no visible progress until
the Mac job's 25-minute limit cancelled it. Local repeated real-media tests
reproduced a suspended `PixelBufferReceiver.append` task that was already
cancelled; native cancellation had not resumed it.

To separate the writer from decoding, annotations, UI, test parallelization
and recording size, the [standalone reproduction](encoder-readiness-repro.swift)
encodes 300 synthetic 320 × 180 BGRA frames per job with one writer at a time.
Both receiver variants use the same frames, timestamps, settings and buffer pool.

| Variant | Observed result |
| --- | --- |
| Async pixel receiver, initial run | Suspended at job 53, frame 277; CPU became idle |
| Async sample receiver | Suspended at job 79, frame 14; CPU became idle |
| Async pixel receiver with native state watcher | Suspended at job 151, frame 142 while the input repeatedly reported ready=true, writer=writing, error=nil |
| Immediate pixel receiver, cooperative backpressure | All 500 jobs completed: 150,000 accepted frames and 500 finished MP4s |

Job and frame indices are zero-based. The async failure is intermittent;
one intermediate 100-job run also passed. Native thread sampling during the
stalls showed the compression and movie-writing threads waiting on semaphores,
with no runnable Swift task. This isolates the async receiver readiness path.
A missed wake-up is the inference from append remaining suspended while the
native input reports ready; the reproduction contains no decoder or renderer.

The watched failure ended with this repeating native state, for more than
20 seconds while no further frame completed:

```text
pixels job 151 append 141 complete
pixels job 151 append 142 begin status 1
WATCH pixels job 151 ready=true status=1 error=nil
WATCH pixels job 151 ready=true status=1 error=nil
```

The cancelled real-export task's concurrency stack contained:

```text
Task 401 - flags=future|cancelled
AVAssetWriterInput.PixelBufferReceiver.append(_:with:)
RecordingExport.savePrepared(source:to:quality:annotations:)
RecordingExport.save(source:to:quality:annotations:)
VideoAnnotationTests.cancelledAnnotatedExportRetainsDestinationAndSource()
THREADS: no threads with active tasks
```

The fix uses the modern receiver's documented `appendImmediately` result:
an accepted frame advances; backpressure keeps the same frame and cooperatively
waits 1 ms; any encoder error is thrown immediately. There is no timeout or
retry after an encoding error. Cancellation interrupts the Swift wait and native
append/cancel calls share the export's lifecycle lock. Both pixel and sample
receivers use this path. See Apple's [pixel receiver documentation](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/pixelbufferreceiver/appendimmediately(_:with:))
and [sample receiver documentation](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/samplebufferreceiver/appendimmediately(_:)).

Run the isolated comparison with:

```sh
xcrun swiftc -swift-version 6 -parse-as-library -O \
  docs/review/timed-video-annotations/mac/encoder-readiness-repro.swift \
  -o /tmp/slightshot-receiver-repro
/tmp/slightshot-receiver-repro pixels 1000
/tmp/slightshot-receiver-repro samples 1000
/tmp/slightshot-receiver-repro pixels-immediate 500
```

The async diagnostic modes intentionally preserve the failing API and may remain
suspended. They are diagnostic programs, separate from the application's fixed
export path and its tests.

The hosted runner also exposed a distinct test assertion issue: its encoded
gray background had red=60, while the timing test expected red<60. Before/after
frames now compare the line location with untouched background in that same
frame, allowing less than 20 levels of compression difference. Active line
frames must still have red>200. This retains a wide margin between a visible
line and the background without depending on one encoder's gray conversion.

Validation after the change:

- Full `NSUnbufferedIO=YES swift test`: 56 tests in 16 suites passed in 7.034 s,
  including 4K prepared-frame effect strength/range comparisons, real encoded
  output at all qualities and source/destination retention.
- The real annotated in-flight cancellation test passed 50 consecutive
  repetitions in 33.065 s. The original async path had remained suspended on
  repetition 11 of this test during the diagnosis above.
- `swiftlint --strict --quiet`: passed without warnings.
