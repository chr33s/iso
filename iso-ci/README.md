# iso-ci

The separately installed GitHub Actions companion to iso: GitHub-connected
runner pools and local workflow preflight, each job in a clean NIC-less iso VM.

- Operator guide: [`docs/ci.md`](../docs/ci.md)
- Specification and implementation status:
  [`docs/design/iso-ci-specification.md`](../docs/design/iso-ci-specification.md)
- Qualification evidence and defects found:
  [`docs/design/iso-ci-qualification.md`](../docs/design/iso-ci-qualification.md)
- Runner image profile: [`images/ci-runner.profile.jsonc`](images/ci-runner.profile.jsonc)
- Protocol provenance: [`PROVENANCE.md`](PROVENANCE.md)

```sh
swift build -c release --package-path iso-ci
swift test --package-path iso-ci --force-resolved-versions   # fixtures only
iso-ci/scripts/test-dataplane-jail.sh                        # data-plane confinement
```

Layout: `Sources/IsoCICore/{Execution,GitHub,Preflight,Storage}` (one library)
and `Sources/IsoCI` (CLI, controller, confined `_dataplane` child). Base iso
never links or requires this package.
