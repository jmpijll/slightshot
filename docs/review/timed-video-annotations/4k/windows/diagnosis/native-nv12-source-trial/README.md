# Native NV12 source trial

PR head `57084d8e47249eb41d3cdd3a3630150e0874af07`, native merge checkout
`f63936ff6e38fa47664ae2a8eceea4aceb2675df`,
[run 38082754091](https://github.com/jmpijll/slightshot/actions/runs/38082754091).

The unchanged complete 4K fixture passes its performance, memory, UI, effects and
active-cancellation gates: 11.54 fps and 1493.80 MiB sampled private peak. The
separate 640-pixel primary-color regression fails without changing its 8-value
per-channel tolerance. Native source preview red is approximately RGB
(254.95, 1, 3.09), while interpreting the untagged native NV12 source as BT.709
produces (255, 24.92, 0). That exposes actual source conversion/signaling mismatch;
the documented unknown-matrix default does not identify the underlying pixels.
This trial is not final acceptance or proof of green CI. Both original native
reports are retained, along with source endpoint IDs and untouched raw PTS.

Independent decoded motion correlation now favors same-index High/Step alignment
(best shift zero, blue residual about 0.25), rather than the previous minus-one
shift. Both raw and normalized scheduling alternatives remain visible in the
[diagnostic](moving-stripe-identity-diagnostic.json). Quantized stripe plateaus
limit individual-frame identity claims. Actual decoded counts, cadence and final
partial duration pass in the [independent cadence report](media-cadence-validation.json).
These timing successes do not erase the separate source-color failure.
