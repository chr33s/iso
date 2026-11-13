import Foundation

/// A host executable iso has verified no principal but this user or root
/// can replace, identified by its canonical path. Spawn `path`, never the
/// path that was asked about: a symlink there was resolved and checked
/// through its target.
///
/// Rule: an executable regular file owned by root or this user, with no
/// group/other write bit and no extended ACL granting write, under ancestors
/// owned by root or this user that, unless sticky, are neither world-writable
/// nor group-writable by a group other than `wheel`/`admin`, and carry no ACL
/// granting write.
package struct TrustedExecutable: Sendable, Equatable {
  package let path: String

  private init(path: String) { self.path = path }

  /// Group ids whose members can already act as root on macOS (`wheel`,
  /// `admin`); Homebrew's prefix is `admin`-group-writable.
  package static let rootEquivalentGroups: Set<gid_t> = [0, 80]

  package static func verify(_ requested: String, uid: uid_t = getuid()) throws(HostError)
    -> TrustedExecutable
  {
    guard requested.hasPrefix("/") else { throw HostError("\(requested) is not an absolute path") }
    guard let pointer = unsafe realpath(requested, nil) else {
      throw HostError("\(requested) does not exist")
    }
    let path = unsafe String(cString: pointer)
    unsafe free(pointer)
    var status = stat()
    guard unsafe lstat(path, &status) == 0 else { throw HostError("\(path) does not exist") }
    guard status.st_mode & S_IFMT == S_IFREG, status.st_mode & 0o111 != 0 else {
      throw HostError("\(path) is not an executable regular file")
    }
    guard status.st_uid == 0 || status.st_uid == uid else {
      throw HostError("\(path) is owned by another user")
    }
    guard status.st_mode & 0o022 == 0 else {
      throw HostError("\(path) is group- or world-writable")
    }
    guard !ACLWrite.grants(path: path) else {
      throw HostError("\(path) has an ACL that lets others write it")
    }
    // Whoever can rename entries in a directory on the path can swap the
    // file, so every ancestor must be as trustworthy as the file.
    var directory = (path as NSString).deletingLastPathComponent
    while true {
      guard unsafe lstat(directory, &status) == 0 else {
        throw HostError("Failed to inspect \(directory)")
      }
      if let why = untrustedDirectory(
        mode: status.st_mode, owner: status.st_uid, group: status.st_gid, me: uid)
      {
        throw HostError("\(path) is inside \(directory), which \(why)")
      }
      if status.st_mode & S_ISVTX == 0, ACLWrite.grants(path: directory) {
        throw HostError(
          "\(path) is inside \(directory), which has an ACL that lets others write it")
      }
      if directory == "/" || directory.isEmpty { break }
      directory = (directory as NSString).deletingLastPathComponent
    }
    return TrustedExecutable(path: path)
  }

  /// `path` taken as is, for builds that skip verification (debug builds of
  /// the companions). Never for a release path.
  package static func unverified(_ path: String) -> TrustedExecutable {
    TrustedExecutable(path: path)
  }

  /// Why a directory lets someone other than root or `me` replace entries
  /// in it, or nil. A sticky directory only lets users rename their own.
  package static func untrustedDirectory(mode: mode_t, owner: uid_t, group: gid_t, me: uid_t)
    -> String?
  {
    if owner != 0 && owner != me { return "is owned by another user" }
    if mode & 0o1000 != 0 { return nil }
    if mode & 0o002 != 0 { return "is world-writable" }
    if mode & 0o020 != 0 && !rootEquivalentGroups.contains(group) { return "is group-writable" }
    return nil
  }
}

/// Whether an extended ACL allows anyone to write, append, add or delete
/// entries, or change ownership or permissions. Deny entries are fine.
package enum ACLWrite {
  package static func grants(descriptor: Int32) -> Bool {
    guard let acl = unsafe acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return false }
    defer { unsafe acl_free(UnsafeMutableRawPointer(acl)) }
    return unsafe grants(acl)
  }

  /// Reads the ACL of `path` itself, not of a symlink's target.
  package static func grants(path: String) -> Bool {
    guard let acl = unsafe acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
    defer { unsafe acl_free(UnsafeMutableRawPointer(acl)) }
    return unsafe grants(acl)
  }

  @unsafe private static func grants(_ acl: acl_t) -> Bool {
    var entry: acl_entry_t? = nil
    var which = ACL_FIRST_ENTRY.rawValue
    let writes: [acl_perm_t] = [
      ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES,
      ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER,
    ]
    while unsafe acl_get_entry(acl, Int32(which), &entry) == 0, let current = unsafe entry {
      which = ACL_NEXT_ENTRY.rawValue
      var tag = ACL_UNDEFINED_TAG
      guard unsafe acl_get_tag_type(current, &tag) == 0, tag == ACL_EXTENDED_ALLOW else { continue }
      var permissions: acl_permset_t? = nil
      guard unsafe acl_get_permset(current, &permissions) == 0, let permissions = unsafe permissions
      else { continue }
      if writes.contains(where: { unsafe acl_get_perm_np(permissions, $0) == 1 }) { return true }
    }
    return false
  }
}
