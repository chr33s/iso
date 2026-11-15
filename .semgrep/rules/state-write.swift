func save(_ bytes: [UInt8], to url: URL, path: String) throws(HostError) {
  // ruleid: iso.state-write
  try Data(bytes).write(to: url, options: .atomic)
  // ruleid: iso.state-write
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  // ruleid: iso.state-write
  FileManager.default.createFile(atPath: path, contents: nil)
  // ruleid: iso.state-write
  try FileManager.default.copyItem(atPath: path, toPath: path + ".bak")
  // ruleid: iso.state-write
  let handle = FileHandle(forWritingAtPath: path)
  // ok: iso.state-write
  try AtomicFile.write(bytes, to: path, mode: 0o600)
  // ok: iso.state-write
  try store.write(record)
  // ok: iso.state-write
  FileHandle.standardError.write(Data("saved\n".utf8))
}
