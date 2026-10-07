import CoreGraphics
import Darwin
import Foundation
import IOKit
import Security
import SystemConfiguration
import Virtualization

/// Process, session and host metadata recorded at owner startup (spec §8).
/// `windowServer` additionally asks CoreGraphics for the current session, which
/// opens a WindowServer connection; the headless `vm-run` owner leaves it off so
/// the measurement does not perturb what it measures.
func hostContext(windowServer: Bool) -> [String: Any] {
  let uid = getuid()
  let euid = geteuid()
  let manager = runTool(["/bin/launchctl", "managername"])
  let userDomain = runTool(["/bin/launchctl", "print", "user/\(uid)"])
  let guiDomain = runTool(["/bin/launchctl", "print", "gui/\(uid)"])
  var o: [String: Any] = [
    "pid": Int(getpid()), "ppid": Int(getppid()), "uid": Int(uid), "euid": Int(euid),
    "gid": Int(getgid()), "egid": Int(getegid()), "user": userName(euid),
    "home_env": ProcessInfo.processInfo.environment["HOME"] ?? NSNull(),
    "home_dir": NSHomeDirectory(),
    "launchd_manager": manager.output.trimmingCharacters(in: .whitespacesAndNewlines),
    "user_domain_exists": userDomain.status == 0, "user_domain_status": Int(userDomain.status),
    "gui_domain_exists": guiDomain.status == 0, "gui_domain_status": Int(guiDomain.status),
    "virtualization_supported": VZVirtualMachine.isSupported,
    "virtualization_entitlement": hasEntitlement("com.apple.security.virtualization"),
    "console_user": consoleUser() ?? NSNull(), "console_locked": consoleLocked() ?? NSNull(),
    "security_session": securitySession(),
    "host_model": sysctlString("hw.model"),
    "os_product_version": sysctlString("kern.osproductversion"),
    "os_build": sysctlString("kern.osversion"),
    "keychain": keychainMetadata(),
  ]
  if windowServer {
    if let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
      let keep = [
        "kCGSSessionOnConsoleKey", "kCGSSessionLoginDoneKey", "kCGSessionLoginDoneKey",
        "CGSSessionScreenIsLocked",
      ]
      o["window_server_session"] = d.filter { keep.contains($0.key) }.mapValues { "\($0)" }
    } else {
      o["window_server_session"] = NSNull()
    }
  }
  return o
}

func sysctlString(_ name: String) -> String {
  var size = 0
  guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return "" }
  var buf = [UInt8](repeating: 0, count: max(size, 1))
  sysctlbyname(name, &buf, &size, nil, 0)
  return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
}

func userName(_ uid: uid_t) -> String {
  guard let pw = getpwuid(uid) else { return "uid\(uid)" }
  return String(cString: pw.pointee.pw_name)
}

func hasEntitlement(_ name: String) -> Bool {
  guard let task = SecTaskCreateFromSelf(nil) else { return false }
  return (SecTaskCopyValueForEntitlement(task, name as CFString, nil) as? Bool) == true
}

func consoleUser() -> String? {
  var uid: uid_t = 0
  var gid: gid_t = 0
  return SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?
}

func consoleLocked() -> Bool? {
  let root = IORegistryGetRootEntry(kIOMainPortDefault)
  defer { IOObjectRelease(root) }
  guard
    let v = IORegistryEntryCreateCFProperty(
      root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)
  else {
    return nil
  }
  return (v.takeRetainedValue() as? Bool)
}

func securitySession() -> [String: Any] {
  var sid = SecuritySessionId()
  var attrs = SessionAttributeBits()
  let status = SessionGetInfo(SecuritySessionId(bitPattern: -1), &sid, &attrs)
  guard status == errSecSuccess else { return ["status": Int(status)] }
  return [
    "id": Int(sid), "attributes": Int(attrs.rawValue),
    "is_root": attrs.contains(.sessionIsRoot),
    "has_graphic_access": attrs.contains(.sessionHasGraphicAccess),
    "has_tty": attrs.contains(.sessionHasTTY), "is_remote": attrs.contains(.sessionIsRemote),
  ]
}

/// Keychain state is metadata only (spec §8): whether the login keychain file
/// exists and whether `security show-keychain-info` can read its settings. Never
/// unlocks, never reads contents.
func keychainMetadata() -> [String: Any] {
  let path = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
  let exists = FileManager.default.fileExists(atPath: path)
  guard exists else { return ["login_keychain_present": false] }
  let info = runTool(["/usr/bin/security", "show-keychain-info", path], timeout: 5)
  return ["login_keychain_present": true, "show_keychain_info_status": Int(info.status)]
}
