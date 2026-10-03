import IsoCore

/// The closed set of secret-store failures callers branch on. No case ever
/// carries a secret value or passphrase.
package enum EnclaveStoreError: Error, Equatable, CustomStringConvertible {
  case notInitialized
  case alreadyInitialized
  /// Device-key files exist but `store.v1.json` does not.
  case incomplete(String)
  /// A state file or directory is not a private regular file/directory of
  /// the current user.
  case unsafePermissions(String)
  /// The on-disk format is invalid or outside its bounds.
  case malformed(String)
  /// Wrong passphrase, cancelled user presence, or tampered ciphertext:
  /// deliberately indistinguishable.
  case unlockFailed
  /// The Secure Enclave key is missing or unusable. Permanent: there is no
  /// recovery path.
  case enclaveKeyUnavailable
  case secureEnclaveUnavailable
  case notFound(SecretName)
  case limitExceeded(String)
  case io(String)

  package var description: String {
    switch self {
    case .notInitialized: "No iso secret store; create one with `iso secrets init`"
    case .alreadyInitialized: "A iso secret store already exists"
    case .incomplete(let path):
      "\(path) exists but store.v1.json does not: an interrupted `iso secrets init`, or a store file lost from this directory. Restore store.v1.json from a backup of this Mac, or, if there is none, remove the leftover device key files and run `iso secrets init` again."
    case .unsafePermissions(let path):
      "Refusing to use \(path): it must be owned by you and not group- or world-writable (files must be regular files)"
    case .malformed(let reason): "Invalid iso secret store: \(reason)"
    case .unlockFailed: "Unable to unlock the iso secrets store"
    case .enclaveKeyUnavailable:
      """
      Iso secrets cannot be unlocked because the Secure Enclave key for this store
      is unavailable.

      This store has no recovery path.
      Restore the original device/key state or recreate the secret store.
      """
    case .secureEnclaveUnavailable: "This Mac has no usable Secure Enclave"
    case .notFound(let name): "No secret named '\(name)'"
    case .limitExceeded(let reason): "Secret store limit exceeded: \(reason)"
    case .io(let reason): reason
    }
  }
}
