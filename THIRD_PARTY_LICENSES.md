# Third-party licenses

The root `LICENSE` applies to isolate's Apache 2.0 project material. It does
not replace the licenses or exceptions of third-party components.

- `fuzz/libfuzzer/`: unmodified LLVM libFuzzer at revision `a47b42eb9f9b`
  (LLVM release/22.x), obtained from libfuzzer-sys 0.4.13. Its original
  headers and `LICENSE.TXT` retain Apache-2.0 WITH LLVM-exception.
- SwiftPM dependencies: exact versions and revisions are recorded in each
  package's `Package.resolved`. Release bundles include their license,
  notice and copying files (including nested vendored components) under
  `third-party/<package>/<dependency>/`, with each pin in `SOURCE.json`.
  The root CLI package is named `host` in this directory.

- `www/public/hairline/kernel.js`: unmodified Hairline skill engine at revision
  `37d2e78dcb333ab30c3338e28ed4a690364ea014` of `lucasmarkes/hairline`.
  `style.css` is its unmodified `HL.css()` output. Both are MIT licensed;
  the original notice is retained in `www/public/hairline/LICENSE`.
  The six feature drawings and their page adapter are isolate artwork.

Source distributions retain the libFuzzer license in its original location.
SwiftPM fetches the other dependencies with their own legal files at build
time. Binary distributions include those files from the staged build inputs.
