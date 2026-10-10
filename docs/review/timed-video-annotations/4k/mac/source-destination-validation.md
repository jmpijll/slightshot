# Source-preserving destination validation

Product/test source: `94d3c5797bfdfe60c9b2ab6d0768f0620c0c3b83`.
macOS 27 / Apple M4, real synthetic 320 × 180 H.264 media.

The regression test first reproduced an export replacing its own input: no error
was thrown and the original source bytes changed. The fix rejects an export
whose destination resolves to the source URL or has the same existing file
resource identity, before preparing annotations or creating a staging directory.

The same real-media test runs with and without annotations. Exact paths,
`nested/../source.mp4`, symbolic links, hard links and an existing case alias are
rejected. After every attempt, the source bytes, unrelated existing destination
bytes and directory entries remain unchanged. Case aliases are only tested when
the filesystem actually resolves that spelling to an existing file; the product
does not lowercase paths on case-sensitive volumes.

Recorded validation result:

```text
Test exportRejectsSourceDestinationsWithoutChangingOriginal(annotated:)
  both plain and annotated test cases passed
Test run with 59 tests in 16 suites passed after 9.344 seconds.
Strict SwiftLint: no warnings or errors.
Release bundle: completed in 17.64 seconds, no compiler warnings.
```

The full suite includes actual successful quality exports, replacement,
in-flight cancellation, interval pixels and source cadence, so the guard also
preserves ordinary saving. The existing native 4K captures use the unchanged
normal destination path; this guard does not alter their annotation rendering.

Reproduce with `swift test` and `swiftlint lint --strict`, then
`SIGN_IDENTITY=- ./Scripts/bundle.sh` from the repository root.
