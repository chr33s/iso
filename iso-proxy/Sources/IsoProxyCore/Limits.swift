package enum Limits {
  package static let connections = 256
  package static let requests = 256
  /// Upstream TCP sockets, shared by forwarded requests and TLS probes.
  package static let upstreamSockets = connections
  /// Open descriptors the limits above can hold at once: every guest
  /// connection and upstream socket, plus a reserve for the listener, event
  /// loops, resolver lookups and standard streams.
  package static let descriptors = connections + upstreamSockets + 64
  package static let headerFieldBytes = 16 * 1024
  package static let headerBlockBytes = 64 * 1024
  package static let headerCount = 128
  package static let headerWireBytes = headerBlockBytes + headerFieldBytes + headerCount * 4 + 64
  package static let requestBodyBytes = 64 * 1024 * 1024
  package static let establishmentSeconds = 30
  package static let initialHeaderSeconds = 10
  package static let bodyIdleSeconds = 30
  package static let startupBytes = 64 * 1024
  /// Startup version 3 carries the policy (itself at most 64 KiB).
  package static let startupBytesV3 = 128 * 1024
}
