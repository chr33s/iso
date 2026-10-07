import Foundation

func stderrLog(_ s: String) {
  FileHandle.standardError.write(Data(("vz-context-probe: " + s + "\n").utf8))
}

func die(_ s: String) -> Never {
  stderrLog("fatal: " + s)
  exit(2)
}

struct Arguments {
  let all: [String]
  var command: String? { all.count > 1 ? all[1] : nil }
  var positional: [String] {
    var out: [String] = []
    var i = 2
    while i < all.count {
      if all[i].hasPrefix("--") {
        i += 2
      } else {
        out.append(all[i])
        i += 1
      }
    }
    return out
  }
  func value(_ name: String) -> String? {
    guard let i = all.firstIndex(of: name), i + 1 < all.count else { return nil }
    return all[i + 1]
  }
  func double(_ name: String, _ fallback: Double) -> Double {
    value(name).flatMap(Double.init) ?? fallback
  }
  func int(_ name: String, _ fallback: Int) -> Int { value(name).flatMap(Int.init) ?? fallback }
}

/// JSONL event sink: one object per line, to a file (if given) and stdout.
final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private let handle: FileHandle?
  let runID: String
  let context: String

  init(path: String?, runID: String, context: String) {
    self.runID = runID
    self.context = context
    if let path {
      if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
      }
      handle = FileHandle(forWritingAtPath: path)
      handle?.seekToEndOfFile()
    } else {
      handle = nil
    }
  }

  func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var o = fields
    o["event"] = event
    o["run_id"] = runID
    o["context"] = context
    o["t"] = Date().timeIntervalSince1970
    o["uptime"] = ProcessInfo.processInfo.systemUptime
    let d = jsonLine(o)
    lock.lock()
    handle?.write(d)
    FileHandle.standardOutput.write(d)
    lock.unlock()
  }
}

func jsonData(_ o: Any, pretty: Bool = false) -> Data {
  let opts: JSONSerialization.WritingOptions =
    pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
  guard JSONSerialization.isValidJSONObject(o),
    let d = try? JSONSerialization.data(withJSONObject: o, options: opts)
  else { return Data("{\"unserializable\":true}".utf8) }
  return d
}

func jsonLine(_ o: Any) -> Data {
  var d = jsonData(o)
  d.append(0x0A)
  return d
}

func writeJSON(_ o: Any, to path: String) {
  try? jsonData(o, pretty: true).write(to: URL(fileURLWithPath: path), options: .atomic)
}

/// Error metadata that never infers a cause from the message text alone.
func errorInfo(_ error: any Error) -> [String: Any] {
  let ns = error as NSError
  var o: [String: Any] = [
    "domain": ns.domain, "code": ns.code, "description": ns.localizedDescription,
  ]
  if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
    o["underlying"] = ["domain": u.domain, "code": u.code, "description": u.localizedDescription]
  }
  return o
}

/// Run a tool with stdin closed and a timeout; returns status and combined output.
func runTool(_ argv: [String], timeout: TimeInterval = 10) -> (status: Int32, output: String) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: argv[0])
  p.arguments = Array(argv.dropFirst())
  p.standardInput = FileHandle.nullDevice
  let pipe = Pipe()
  p.standardOutput = pipe
  p.standardError = pipe
  do { try p.run() } catch { return (-1, "\(error)") }
  // Drain concurrently: a full pipe would otherwise block the child forever.
  final class Box: @unchecked Sendable { var data = Data() }
  let box = Box()
  let done = DispatchSemaphore(value: 0)
  let reader = pipe.fileHandleForReading
  Thread.detachNewThread {
    box.data = reader.readDataToEndOfFile()
    done.signal()
  }
  let deadline = Date().addingTimeInterval(timeout)
  while p.isRunning && Date() < deadline { usleep(20_000) }
  if p.isRunning {
    p.terminate()
    return (-2, "timeout")
  }
  _ = done.wait(timeout: .now() + 2)
  return (p.terminationStatus, String(decoding: box.data, as: UTF8.self))
}

/// Poll `cond` until true or timeout. Returns whether it became true.
func waitUntil(_ timeout: TimeInterval, interval: TimeInterval = 0.25, _ cond: () -> Bool) async
  -> Bool
{
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if cond() { return true }
    try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
  }
  return cond()
}
