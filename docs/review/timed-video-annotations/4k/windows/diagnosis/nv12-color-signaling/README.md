# MP4 color signaling diagnosis

These reports inspect actual files from PR head
`f1bab14012af0303e0ded426636fae78f243cbd4`, native checkout
`7500d6cef05d859638fd303c0ad4008bf5162110`, in
[run 38078894384](https://github.com/jmpijll/slightshot/actions/runs/38078894384).

The first diagnostic required H.264 SPS color VUI and therefore reported a
failure: `video_signal_type_present_flag` is zero. That is retained unchanged,
along with its original script. Inspection then distinguished the MP4 container's
color signaling from raw H.264 SPS metadata. The actual High, Balanced and Step
MP4 files signal TV/limited range and BT.709 matrix, primaries and transfer in
the container. Independently decoded solid blue and red annotation pixels pass
the original RGB tolerances, with maximum mean channel errors of 1.60 and 1.04
levels respectively. No bitstream mutation was made.

The accepted report requires the actual MP4 metadata and the unchanged RGB
tolerances. It separately records the absent SPS VUI; it does not claim that
raw H.264 has explicit color signaling. MP4 is the implemented export format.
The full pipeline still failed the separate private-memory acceptance gate in
this run, as the adjacent native memory report records.
