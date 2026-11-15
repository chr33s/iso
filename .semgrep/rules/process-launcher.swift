func launch() throws(HostError) {
  // ruleid: iso.process-launcher
  let child = Process()
  // ruleid: iso.process-launcher
  let other = Foundation.Process(executableURL: url)
  // ruleid: iso.process-launcher
  _ = unsafe posix_spawn(&pid, path, nil, nil, argv, envp)
  // ruleid: iso.process-launcher
  _ = system("ls")
  // ruleid: iso.process-launcher
  _ = fork()
  // ruleid: iso.process-launcher
  _ = unsafe execve(path, argv, envp)
  // ok: iso.process-launcher
  let output = try runner.capture(.init(executable: "/usr/bin/git", arguments: ["status"]))
  // ok: iso.process-launcher
  let runner = ProcessRunner()
  // ok: iso.process-launcher
  let font = Font.system(size: 12)
  // ok: iso.process-launcher
  // posix_spawn(...) is only named in a comment here.
}
