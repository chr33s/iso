func report(_ diagnostics: Diagnostics) {
  // ruleid: iso.library-stdout
  print("starting")
  // ruleid: iso.library-stdout
  debugPrint(value)
  // ruleid: iso.library-stdout
  FileHandle.standardOutput.write(Data("done\n".utf8))
  // ruleid: iso.library-stdout
  fputs("done\n", stdout)
  // ok: iso.library-stdout
  FileHandle.standardError.write(Data("starting\n".utf8))
  // ok: iso.library-stdout
  diagnostics.print("starting")
  // ok: iso.library-stdout
  fputs("warning\n", stderr)
}
