# Recorder color signaling trial

PR head `f9ac4ea860607316a9bf961cd71bd383a4ae5498`, native checkout
`ed6c20b1826dfb1ef64b0874d0ccd12138c036b4`,
[run 38083248389](https://github.com/jmpijll/slightshot/actions/runs/38083248389).

The unchanged complete 4K fixture passes: 11.78 fps, 1498.40 MiB sampled private
peak, 89.4 ms dispatcher gap and 106 ms active cancellation. The separate native
640-pixel primary-color test still fails at the original 8-value per-channel limit.
This is not final acceptance or green CI.

The source MP4 now exposes actual limited-range BT.709 container metadata, as
retained in `actual-source-probe.json`. Yet its known red patch decoded through
BT.709 NV12-to-BGRA still has a green mean of about 24.9 rather than zero; the
native thumbnail retains approximately RGB (255, 1, 3). Explicit output metadata
alone did not establish a matching RGB-to-YUV pixel conversion. Independent
comparisons to the original nominal synthetic RGB reject this mismatch, even if
two decoders were to agree on the same incorrectly labeled colors. The next
route supplies explicitly converted NV12 pixels at the recording input.

Original native reports and endpoint references are copied unchanged. Derived
probe paths identify the local downloaded native artifact, not another source.
