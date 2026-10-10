# Extracted portable x64 native regression record

The extracted portable application runs the same real native fixture separately
in run 38085300980, source head `0d96e8eece5bcdfc8f24074b61126b230e0dccb0`,
checkout `e28601319e3107e8681c2af2bea6b8312c5cd1ff`.
It records a separate synthetic source, so its input hash/duration/counters differ
from the first native instance. Original reports and its actual source MP4 are
retained here; independently decoded source-color pixels are in
`independent-source-colors/`.

The [combined read-only audit](../native-fixture-evidence-audit.json) records both
instances separately. Each passes known nominal source RGB, exact untouched
endpoint ticks, timing Undo and all six native source-frame seek counters,
including exact end and subsequent backward recovery. Source/output endpoints
are required according to each quality's scheduled output positions.
