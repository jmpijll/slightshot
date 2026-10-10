# Explicit NV12 recording trial

PR head `d2902cb1a83c36a2653a8c84d01e69fae1208388`, native checkout
`75e6eee2179c0e6e8296cdeb2f747d3485b49dbc`,
[run 38083618317](https://github.com/jmpijll/slightshot/actions/runs/38083618317).

Explicit limited-range BT.709 NV12 recording input fixes the actual source pixel
conversion. The sequential decoder's source red is approximately RGB (255, 1, 0),
within the unchanged eight-value tolerance of its known nominal (255, 0, 0).
The actual WinRT MediaComposition thumbnail still displays approximately
(233, 0, 2), failing the native source-preview nominal test. Correct source pixels
and labels alone therefore do not establish correct product preview colors.

The complete 4K run passes throughput and pixel/timing checks at 19.53 fps,
78.5 ms dispatcher gap and 70 ms cancellation, but active-cancellation private
memory peaks at 1587.22 MiB, above the unchanged 1536 MiB whole-fixture limit.
Primary export peaks at 1168.7 MiB and separate Step at 1469.6 MiB. Both original
reports are retained. This is not final acceptance or proof of green CI.
The next preview path uses explicitly converted native NV12 rather than the
ambiguous thumbnail RGB conversion, with owned native lifetime and random seeks.

The [independent original-RGB source report](independent-source-colors/native-source-color-validation.json)
confirms tagged BT.709 source pixels retain the known input within the same
eight-value tolerance. Its literal decoded contact sheet preserves the correct
tagged conversion and separate forced601 diagnosis that reproduces the thumbnail
error. The native preview test remains failed; independent source success does
not override it.
