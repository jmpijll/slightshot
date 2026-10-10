# Source-frame selection diagnosis

This independent report inspects the actual source and High/Balanced/Step MP4s
from PR head `2bf1000446330500239a4d28bc74dfb27b5f5a1b`, native merge checkout
`55f891162e7d28dd1cb5307647f60e89095f4c0f` in
[run 38081733795](https://github.com/jmpijll/slightshot/actions/runs/38081733795).
It retains every decoded untouched top-stripe RGB crop, raw timestamps and both
raw-PTS and normalized-source-origin scheduling models. High and Step correlate
best with source index minus one, despite correct encoded counts and zero output
PTS. The source decoder compared positive raw source PTS against zero-based
export positions, retaining the beginning too long and omitting final content.

The affine blue fit isolates fixed decoder color offsets from motion correlation.
The stripe has H.264 plateaus, so it does not prove exact identity of every frame.
The earlier coarse three-time pixel checks likewise did not establish endpoint
identity. The fix subtracts the first decoded source PTS, allowing one 100 ns
quantization tick. Raw source inspection and annotation intervals stay intact.
Final evidence uses fresh native high-contrast first/last frame IDs and a separate
normalized-timestamp motion-correlation report, alongside all unchanged media gates.

`inspect_moving_stripe.py` is the portable read-only diagnostic, with ffmpeg and
ffprobe on PATH. The original performance failure remains recorded separately.
