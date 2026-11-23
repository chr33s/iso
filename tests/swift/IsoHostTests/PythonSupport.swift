import Foundation
import IsoCore
import IsoHost

/// The interpreter behind `/usr/bin/python3`, resolved without running that
/// shim. The shim looks up the selected developer directory on every run;
/// where it cannot (a Seatbelt profile, a scrubbed environment, another
/// user) it opens the Command Line Tools install dialog instead of failing.
/// Tests run this interpreter directly. Nil when no developer directory
/// carries one.
let systemPython: String? = {
  var directories: [String] = []
  if let selected = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
    directories.append(selected)
  }
  if let selected = selectedDeveloperDirectory() { directories.append(selected) }
  directories.append("/Library/Developer/CommandLineTools")
  for directory in directories {
    if let resolved = canonicalPath(directory + "/usr/bin/python3"),
      resolved != "/usr/bin/python3",
      FileManager.default.isExecutableFile(atPath: resolved)
    {
      return resolved
    }
  }
  return nil
}()

/// `systemPython`, or a failure naming why the test cannot run.
func requireSystemPython() throws -> String {
  guard let systemPython else {
    throw HostError("no python3 in the selected developer directory")
  }
  return systemPython
}

/// `xcode-select -p`, which only reports the selection (it never prompts).
private func selectedDeveloperDirectory() -> String? {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
  process.arguments = ["-p"]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  guard (try? process.run()) != nil else { return nil }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { return nil }
  let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  return path.hasPrefix("/") ? path : nil
}
