# Native color, seek, timing and endpoint regression checks

Actual Windows WPF / Media Foundation fixture from merge checkout `e28601319e3107e8681c2af2bea6b8312c5cd1ff`,
PR source head `0d96e8eece5bcdfc8f24074b61126b230e0dccb0`, [native run 38085300980](https://github.com/jmpijll/slightshot/actions/runs/38085300980).
The synthetic 640 × 360 source has codec padding to 640 × 368 and known RGB/gray
patches outside all annotation regions. Source SHA-256 `601fed93f02cde2d329047b52a26c2b5bcbe25b73465509ce838cbff9516f7b9`. Actual native Media Foundation + CPU preview, sequential NV12
conversion and all three encoded qualities are compared within the unchanged
8-value mean tolerance per RGB channel. The [independent tagged-source RGB report](independent-source-colors/native-source-color-validation.json) also compares actual ffmpeg-decoded pixels against known original RGB, retaining a [literal decoded contact sheet](independent-source-colors/source-color-metadata-versus-pixels.png). Forced601 images are separate diagnostic alternatives, not an acceptance override. Original native JSONs are copied unchanged.

Eight high-contrast gray binary cells identify actual source endpoint frames.
The final source reference is forced at its raw last decoded PTS, independently
of the normalized frame-selection rule. Each quality must retain the first ID;
High must reach and retain the final source ID. Lower cadences require the final
ID when their last scheduled output sample reaches it. Raw PTS remain recorded.
The [native random-seek record](video-editor-random-seek-validation.json) also requires exact source-frame counters and retained positions for 0.5 → 3.5 → 0.5 → 2 → editor end → 0.5 seconds, including the independently forced final source ID and recovery after terminal decoding. The [timing-precision record](video-editor-timing-precision-validation.json) commits the actual start-time field using Enter and requires the untouched end to retain exact TimeSpan ticks, with a deliberately non-roundtrip-safe endpoint. The [timing Undo record](video-editor-timing-undo-validation.json) retains before/after ticks and the original unchanged Undo assertion. The final main report is written only after native export/recovery/shutdown checks.

The [combined native/portable audit](native-fixture-evidence-audit.json) separately preserves both actual recorded inputs. The extracted [portable x64 source and reports](portable/README.md) retain their own source hash, color pixels, exact ticks and frame counters.
