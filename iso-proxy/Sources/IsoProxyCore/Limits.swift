package enum Limits {
  package static let connections = 256
  package static let requests = 256
  package static let headerFieldBytes = 16 * 1024
  package static let headerBlockBytes = 64 * 1024
  package static let headerCount = 128
  package static let headerWireBytes = headerBlockBytes + headerFieldBytes + headerCount * 4 + 64
  package static let requestBodyBytes = 64 * 1024 * 1024
  package static let establishmentSeconds = 30
  package static let initialHeaderSeconds = 10
  package static let bodyIdleSeconds = 30
  package static let startupBytes = 64 * 1024
}
