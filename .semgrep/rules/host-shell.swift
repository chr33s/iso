func shells() throws {
  // ruleid: iso.host-shell
  _ = try runtime.exec(machine, ["/bin/sh", "-c", "echo " + name])
  // ruleid: iso.host-shell
  _ = try runtime.exec(machine, ["bash", "-c", script, "bash"] + values)
  // ruleid: iso.host-shell
  _ = try runner.capture(.init(executable: "/bin/sh", arguments: ["-c", command]))
  // ok: iso.host-shell
  _ = try runner.capture(.init(executable: "/usr/bin/git", arguments: ["-C", path, "status"]))
  // ok: iso.host-shell
  environment["SHELL"] = "/bin/sh"
  // ok: iso.host-shell
  _ = try runtime.exec(machine, ["/bin/sh", path])
}
