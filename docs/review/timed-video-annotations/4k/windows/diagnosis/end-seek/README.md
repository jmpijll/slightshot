# Exact-end native preview seek regression

Actual Windows WPF / Media Foundation fixture from checkout `66253c3cae32f5db6364e96fc61059f711cf3e88`,
PR source head `4245a0811bb1a82f2b3df9e9411532450a62e202`,
[native run 38084660019](https://github.com/jmpijll/slightshot/actions/runs/38084660019).
The synthetic source SHA-256 is `5B70F2D747934DA701D2CA431E881B4DED07859A5A9C802EEC396A987649036D`.
Original failure and native JSONs are copied unchanged.

The first four random seeks return the independent source-frame counters
14 → 93 → 14 → 53. At the exact editor end (4.3298333 s), the displayed frame
remains counter 53 instead of the independently forced actual final counter 114.
Adding the positive source timestamp origin to that seek request places it beyond
the native track end; the decoder reaches EOF and the old bitmap remains visible.
Known nominal source RGB still passes on this head. This is a preview seek failure,
separate from the passing 4K export/effect gates.

The fix uses a conservative native seek position at or before the desired frame,
then reads forward with the original timestamp origin. The final
[native random-seek record](../../current/native-source-validation/video-editor-random-seek-validation.json)
requires all six requested positions and frame counters, including the actual
final source ID and a backward seek after terminal decoding. No fixture checks,
export timestamps or acceptance thresholds are relaxed.
