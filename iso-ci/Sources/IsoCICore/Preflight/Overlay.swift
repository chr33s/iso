import Foundation

/// The visible synthetic steps that materialize a snapshot inside the guest
/// (spec section 9, "Source snapshots and checkout"). Both run as POSIX `sh`
/// steps through the official runner, on the guest or inside a job
/// container (busybox included), and fetch the snapshot from the single
/// scoped data-plane endpoint (`$ISO_CI_ENDPOINT/_iso/snapshot/<digest>`,
/// bearer `$ISO_CI_TOKEN`) with curl or wget; neither needs network beyond
/// that endpoint.
///
/// Guarantee: when the overlay step succeeds, the selected snapshot is
/// materialized at that boundary (contents, modes, permitted symlinks and
/// deletions verified). Later user steps may change their own workspace;
/// the recorded snapshot provenance does not change with them. Snapshot
/// paths never contain control characters (capture refuses them), so the
/// NUL-separated lists are read as lines.
package enum OverlayScripts {
  package static let shell = "sh"
  package static let endpointVariable = "ISO_CI_ENDPOINT"
  package static let tokenVariable = "ISO_CI_TOKEN"

  /// The route the data plane serves the snapshot archive on.
  package static func route(_ digest: Digest) -> String { "/_iso/snapshot/\(digest.rawValue)" }

  /// The script for a synthetic step kind; nil for user steps.
  package static func script(for kind: StepKind, snapshot: SnapshotReference) -> String? {
    switch kind {
    case .syntheticCheckout(let path): checkout(snapshot: snapshot, path: path)
    case .snapshotOverlay(let path): overlay(snapshot: snapshot, path: path)
    case .run, .uses: nil
    }
  }

  static func destination(_ path: String) -> String {
    path == "." || path.isEmpty
      ? "\"${GITHUB_WORKSPACE:?}\"" : "\"${GITHUB_WORKSPACE:?}\"/" + shellQuote(path)
  }

  static func prelude(_ snapshot: SnapshotReference, path: String) -> String {
    """
    set -eu
    umask 022
    digest=\(snapshot.digest.rawValue)
    base=\(snapshot.baseCommit)
    dest=\(destination(path))
    cache="${RUNNER_TEMP:-/tmp}/iso-ci-snapshot-${digest}"
    iso_sha256() {
      if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
    }
    iso_fail() { echo "::error::iso-ci: $*" >&2; exit 1; }
    iso_fetch() {
      if [ ! -f "$cache/snapshot.tar" ]; then
        : "${\(endpointVariable):?the iso-ci preflight endpoint is not configured}"
        : "${\(tokenVariable):?the iso-ci preflight token is not configured}"
        rm -rf "$cache"
        mkdir -p "$cache"
        url="${\(endpointVariable)%/}\(route(snapshot.digest))"
        if command -v curl >/dev/null 2>&1; then
          printf 'Authorization: Bearer %s\\n' "$\(tokenVariable)" \\
            | curl -fsS --retry 3 --max-time 900 -H @- -o "$cache/snapshot.part" "$url" \\
            || iso_fail "cannot download snapshot sha256:$digest"
        elif command -v wget >/dev/null 2>&1; then
          wget -q -T 900 --header "Authorization: Bearer $\(tokenVariable)" \\
            -O "$cache/snapshot.part" "$url" \\
            || iso_fail "cannot download snapshot sha256:$digest"
        else
          iso_fail "this environment has neither curl nor wget to fetch the snapshot"
        fi
        mv "$cache/snapshot.part" "$cache/snapshot.tar"
      fi
      actual="$(iso_sha256 "$cache/snapshot.tar" | cut -d' ' -f1)"
      [ "$actual" = "$digest" ] || { rm -rf "$cache"; iso_fail "snapshot digest mismatch (expected sha256:$digest)"; }
      if [ ! -d "$cache/x" ]; then
        mkdir -p "$cache/x.part"
        tar -xf "$cache/snapshot.tar" -C "$cache/x.part"
        mv "$cache/x.part" "$cache/x"
        for list in deletions symlinks regular executables; do
          tr '\\000' '\\n' < "$cache/x/checks/$list" > "$cache/x/checks/$list.lines"
        done
      fi
    }

    """
  }

  /// Materializes the base commit from the snapshot's bundle (no network).
  /// Without git (a minimal job container), the workspace has no `.git`, as
  /// with GitHub's checkout there, and the overlay step materializes the
  /// whole snapshot tree.
  package static func checkout(snapshot: SnapshotReference, path: String) -> String {
    prelude(snapshot, path: path)
      + """
      iso_fetch
      mkdir -p "$dest"
      cd "$dest"
      if ! command -v git >/dev/null 2>&1; then
        echo "iso-ci: git is not available here; the workspace has no .git and the overlay step materializes snapshot sha256:$digest"
        exit 0
      fi
      [ -d .git ] || git init -q .
      git fetch -q --no-tags "$cache/x/base.bundle" '+HEAD:refs/remotes/iso-ci/base' \\
        || iso_fail "cannot read the base-commit bundle"
      [ "$(git rev-parse refs/remotes/iso-ci/base)" = "$base" ] \\
        || iso_fail "the bundle does not contain base commit $base"
      git checkout -q --force --detach "$base"
      git reset -q --hard "$base"
      git clean -q -ffdx
      echo "iso-ci: checked out base commit $base from snapshot sha256:$digest (synthetic, no network)"

      """
  }

  /// Applies the snapshot tree over the workspace and verifies it.
  package static func overlay(snapshot: SnapshotReference, path: String) -> String {
    let state = snapshot.isDirty ? "dirty working tree" : "clean tree"
    return prelude(snapshot, path: path)
      + """
      iso_fetch
      checks="$cache/x/checks"
      mkdir -p "$dest"
      while IFS= read -r p; do rm -rf -- "$dest/$p"; done < "$checks/deletions.lines"
      while IFS= read -r p && IFS= read -r t; do rm -rf -- "$dest/$p"; done < "$checks/symlinks.lines"
      for list in "$checks/regular.lines" "$checks/executables.lines"; do
        while IFS= read -r p; do
          if [ -L "$dest/$p" ] || [ -d "$dest/$p" ]; then rm -rf -- "$dest/$p"; fi
        done < "$list"
      done
      if [ -d "$cache/x/tree" ]; then cp -pPR "$cache/x/tree/." "$dest/"; fi
      cd "$dest"
      problems=0
      iso_problem() {
        problems=$((problems + 1))
        if [ "$problems" -le 50 ]; then echo "::error::iso-ci overlay: $*" >&2; fi
      }
      if [ -s "$checks/sha256sums" ] && ! iso_sha256 -c "$checks/sha256sums" >/dev/null 2>&1; then
        iso_problem "file contents differ from the snapshot"
        iso_sha256 -c "$checks/sha256sums" 2>&1 | grep -v ': OK$' | head -n 50 >&2 || true
      fi
      while IFS= read -r p; do
        { [ -f "$p" ] && [ ! -L "$p" ] && [ -x "$p" ]; } || iso_problem "expected an executable file: $p"
      done < "$checks/executables.lines"
      while IFS= read -r p; do
        { [ -f "$p" ] && [ ! -L "$p" ] && [ ! -x "$p" ]; } || iso_problem "expected a non-executable file: $p"
      done < "$checks/regular.lines"
      while IFS= read -r p && IFS= read -r t; do
        { [ -L "$p" ] && [ "$(readlink -- "$p")" = "$t" ]; } || iso_problem "expected a symlink: $p"
      done < "$checks/symlinks.lines"
      while IFS= read -r p; do
        { [ ! -e "$p" ] && [ ! -L "$p" ]; } || iso_problem "expected a deletion: $p"
      done < "$checks/deletions.lines"
      [ "$problems" -eq 0 ] || iso_fail "snapshot overlay verification failed ($problems problems)"
      echo "iso-ci: snapshot sha256:$digest applied and verified over base $base (\(state))"

      """
  }
}
