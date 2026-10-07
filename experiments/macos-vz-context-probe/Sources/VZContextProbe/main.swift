// vz-context-probe — host probe for the macOS VZ process-context / headless
// display / virtual-HID experiment. Experiment code, not production code.
//
//   vz-context-probe report-context [--window-server]
//   vz-context-probe vm-run <bundle> [--run-dir D] [--run-id R] [--context C0..C5]
//                                    [--hold SECONDS|-1] [--stop-file F] [--cycles N]
//                                    [--cpus N] [--memory-gib N]
//   vz-context-probe vm-view <bundle> [--topology V0..V8] [--socket S] [--run-dir D]
//                                     [--run-id R] [--context C] [--cpus N] [--memory-gib N]
//   vz-context-probe analyze-frame <png> --layout <fixture-state.json>
//   vz-context-probe sck-capture --window-id N --out P
//   vz-context-probe ssh-banner <ip>
//
// All output is JSONL on stdout; diagnostics go to stderr.

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
// A control client that disconnects early must not kill the owner (and its VM).
signal(SIGPIPE, SIG_IGN)
let arguments = Arguments(all: CommandLine.arguments)
switch arguments.command {
case "report-context":
  FileHandle.standardOutput.write(
    jsonLine(hostContext(windowServer: arguments.all.contains("--window-server"))))
  exit(0)
case "vm-run": runHeadless(arguments)
case "vm-view": runView(arguments)
case "analyze-frame": analyzeFrame(arguments)
case "sck-capture": sckCapture(arguments)
case "ssh-banner":
  let ip = arguments.positional.first ?? ""
  FileHandle.standardOutput.write(
    jsonLine([
      "ip": ip, "banner": sshBanner(ip: ip).map { $0 as Any } ?? NSNull(),
      "direct_connect_errno": directConnectErrno(ip: ip),
    ]))
  exit(0)
default:
  die("usage: vz-context-probe report-context | vm-run | vm-view | analyze-frame | sck-capture")
}
