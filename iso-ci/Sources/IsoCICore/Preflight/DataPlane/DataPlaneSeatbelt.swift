/// The Seatbelt profile the preflight data-plane child runs under, applied
/// by `/usr/bin/sandbox-exec -p` before the child's code starts. The child
/// may read the executable and system libraries, read and write only its
/// staging directory, and bind and accept Unix sockets only inside its
/// controller-created sockets directory (one per allocation). It may not
/// create symlinks or hard links anywhere, so neither the unconfined
/// controller nor a guest's forward can be redirected through a link. It has
/// no outbound network (TCP/UDP or other Unix sockets), no process
/// execution beyond the initial exec of itself, and no access to the user's
/// home directory, the controller database, the object store or any
/// credential file. Parameters: `EXE`, `STAGING`, `SOCKETS` (real paths:
/// Seatbelt matches `/private/var`, not `/var`). Reading the root directory
/// listing is allowed because the Swift runtime reads `/` at startup;
/// metadata reads are allowed for dyld and Foundation path resolution.
///
/// This string is the canonical copy; `iso-ci/scripts/dataplane-seatbelt.sb`
/// is generated from it for manual inspection (`sandbox-exec -f`).
package enum DataPlaneSeatbelt {
  package static let profile = """
    (version 1)
    (deny default)
    (allow process-exec (literal (param "EXE")))
    (allow file-read* (literal (param "EXE")))
    (allow file-read-metadata)
    (allow file-read-data (literal "/"))
    (allow file-read*
      (subpath "/System")
      (subpath "/usr/lib")
      (subpath "/usr/share")
      (subpath "/private/var/db/dyld")
      (subpath "/private/var/db/timezone")
      (subpath "/Library/Apple/System/Library")
      (literal "/private/etc/localtime")
      (literal "/dev/urandom")
      (literal "/dev/random")
      (literal "/dev/null"))
    (allow file-write-data (literal "/dev/null"))
    (allow file-read* file-write* (subpath (param "STAGING")))
    (allow file-read* file-write* (subpath (param "SOCKETS")))
    (allow network-bind (local unix-socket (subpath (param "SOCKETS"))))
    (allow network-inbound (local unix-socket (subpath (param "SOCKETS"))))
    (allow sysctl-read)
    (allow process-info* (target self))
    (allow signal (target self))
    (allow mach-lookup
      (global-name "com.apple.system.logger")
      (global-name "com.apple.system.notification_center"))
    (deny file-write-create (vnode-type SYMLINK))
    (deny file-link)
    """
}
