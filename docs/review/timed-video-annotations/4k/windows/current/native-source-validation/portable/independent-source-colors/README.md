# Independent known-source RGB validation

`inspect_native_source_colors.py ARTIFACT_DIRECTORY RUN_ID PR_HEAD_SHA` decodes the
actual 640 × 360 synthetic source MP4 using its discovered container tags. Known
red/green/blue/neutral patch interiors are compared against original fixture RGB
with the unchanged 8-value mean tolerance. The JSON records source hash, run,
PR head and native capture checkout. The literal decoded contact sheet and three
actual decoded PNGs accompany the raw ffprobe result.

Forced BT.601 PNGs are separately labelled diagnostic alternatives; they do not
override discovered tags or nominal acceptance. Read the explicit
`actualTaggedSourceRetainsKnownNominalRGB` and `nativeNominalColorValidationPassed`
booleans. Runtime source preview, sequential decoding, timing and endpoint checks
are retained in the parent folder. The other portable validation scripts are
shared helpers used by the separate 4K record.
