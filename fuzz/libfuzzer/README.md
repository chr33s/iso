# Vendored LLVM libFuzzer

The fuzzing engine `scripts/fuzz.sh` links into the Swift fuzz targets:
the top-level `*.cpp`, `*.h` and `*.def` files of LLVM
`compiler-rt/lib/fuzzer` at commit `a47b42eb9f9b` (release/22.x), unmodified.
They were taken from the `libfuzzer-sys` 0.4.13 crate that previously
supplied them through Cargo; vendoring keeps fuzzing without Cargo and
without a download at build time.

`scripts/fuzz.sh` refuses to build unless the SHA-256 manifest of these files
equals its `LIBFUZZER_MANIFEST_SHA256`. To update, replace the files from an
LLVM checkout, update that constant and the commit above, and rerun
`scripts/fuzz.sh qualify`.

License: Apache License v2.0 with LLVM Exceptions (`LICENSE.TXT`).
