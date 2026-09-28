public enum Limits {
  public static let connections = 256
  public static let requests = 256
  public static let headerFieldBytes = 16 * 1024
  public static let headerBlockBytes = 64 * 1024
  public static let headerCount = 128
  public static let headerWireBytes = headerBlockBytes + headerFieldBytes + headerCount * 4 + 64
  public static let requestBodyBytes = 64 * 1024 * 1024
  public static let establishmentSeconds = 30
  public static let initialHeaderSeconds = 10
  public static let bodyIdleSeconds = 30
  public static let startupBytes = 64 * 1024
}
