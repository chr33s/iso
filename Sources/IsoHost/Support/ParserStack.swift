import Foundation

/// Runs `body` on a dedicated thread with an 8 MiB stack and waits for it.
///
/// The recursive parsers for untrusted documents (devcontainer JSON, guest JSON,
/// Codex TOML) cap nesting at serde's limits, but a cap bounds stack use only if
/// the frames fit: a small secondary stack (Swift Testing's 512 KiB threads, or
/// larger sanitizer frames) could still overflow. A fixed stack makes the cap
/// hold for every caller.
func withParserStack<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
  var outcome: Result<T, E>?
  withoutActuallyEscaping(body) { escapable in
    let task = ParserStackTask { outcome = Result { () throws(E) -> T in try escapable() } }
    var attributes = pthread_attr_t()
    pthread_attr_init(&attributes)
    defer { pthread_attr_destroy(&attributes) }
    pthread_attr_setstacksize(&attributes, 8 << 20)
    let context = Unmanaged.passRetained(task).toOpaque()
    var thread: pthread_t?
    let created = pthread_create(
      &thread, &attributes,
      { raw in
        Unmanaged<ParserStackTask>.fromOpaque(raw).takeRetainedValue().run()
        return nil
      }, context)
    if created == 0, let thread {
      pthread_join(thread, nil)
    } else {
      // No thread: parse here rather than fail.
      Unmanaged<ParserStackTask>.fromOpaque(context).takeRetainedValue().run()
    }
  }
  return try outcome!.get()
}

private final class ParserStackTask: @unchecked Sendable {
  let run: () -> Void
  init(_ run: @escaping () -> Void) { self.run = run }
}
