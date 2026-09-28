# Provenance and Swift history

isolate is a Swift-based derivative of coop, originally developed by
Trail of Bits and contributors: https://github.com/trailofbits/coop.
The project retains the upstream Apache 2.0 `LICENSE` unchanged.

The last upstream revision merged before the full Swift host port was
`6ac6c2c5e739aadae3f6735f4f3348f2f2671d30` (the second parent of
`aefc996ec7ae4c1836d602c1192c054245587ba3`). Its tracked distribution
contains `LICENSE` and no `NOTICE` file. isolate's `NOTICE` consolidates
the derivative attribution; it does not replace upstream file notices.

Git history has been pruned to focus on the Swift implementation.
This history rewrite does not alter the licensing or attribution of
upstream-derived material. The new root is the tree of the first complete
Swift host port, formerly `994614756369f14555f5a495b24c05a1de74354e`,
with legal notices added. Later Swift-era commits retain their ordering,
messages, author identities and timestamps, with rewritten commit identities
and attribution added to applicable files. No historical Rust host commit
is required to build, test or use this branch.

Files translated or adapted from upstream carry modification notices.
JSON files use adjacent `.license` files because JSON has no comment syntax.
New fork-specific implementations do not acquire upstream-derivation notices
merely because they implement new features in this project. LLVM libFuzzer
remains unmodified with its own license and exceptions.

The compatibility inventory's Rust source references are historical citations.
`tests/fixtures/baseline-cli/source-manifest.json` records the source paths and
SHA-256 digests at the old baseline revision. Inventory checks use that record
and retained golden fixtures, without fetching or resolving pruned commits.

Before rewriting, the complete repository was saved as
`iso-pre-swift-prune-20261003.bundle` in the Git common directory, with
backup tag `backup/pre-swift-prune-20261003`. The old-to-new commit map is
saved beside the bundle as `iso-swift-prune-20261003-map.json`. These local
artifacts remain outside the rewritten branch history. Restore the backup
with `git clone /path/to/iso-pre-swift-prune-20261003.bundle restored-iso`.

Only local `main` is rewritten. Existing release tags and other branches keep
their original identities; published archives, checksums and attestations
remain tied to those original identities. Publishing rewritten `main` needs
a reviewed force update with a lease against the remote's current tip.
Do not move release tags or republish signed archives implicitly.
