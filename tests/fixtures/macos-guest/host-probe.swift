// Host-side oracle for the macOS guest qualification (Gates D and O): the
// host pointer, the frontmost application, and whether a process has any
// window on screen. Prints one JSON object.
//
//     host-probe [PID]
import AppKit
import CoreGraphics

let pid = CommandLine.arguments.count > 1 ? Int32(CommandLine.arguments[1]) : nil
let mouse = NSEvent.mouseLocation
let front = NSWorkspace.shared.frontmostApplication
var onscreen = 0
var owned = 0
if let pid,
  let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
{
  for w in windows where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    owned += 1
    if (w[kCGWindowIsOnscreen as String] as? Bool) == true { onscreen += 1 }
  }
}
let out: [String: Any] = [
  "mouse": [mouse.x, mouse.y], "frontmostPID": front?.processIdentifier ?? -1,
  "frontmost": front?.bundleIdentifier ?? "", "ownedWindows": owned, "onscreenWindows": onscreen,
]
print(String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self))
