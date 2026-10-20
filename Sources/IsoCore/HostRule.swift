/// One entry of a filtered-egress allowlist: an exact hostname, or
/// `*.<suffix>` for names one or more whole labels below `suffix` (never
/// `suffix` itself). The suffix needs at least `minimumSuffixLabels` labels,
/// so a rule cannot cover a public suffix or a shared hosting domain
/// (`*.com`, `*.github.io`, `*.githubusercontent.com`). It exists for
/// services that assign per-job hosts under a reviewed operator domain, such
/// as GitHub Actions' `*.actions.githubusercontent.com`.
package enum HostRule: Hashable, Sendable, CustomStringConvertible, Codable {
  case exact(ExactHostname)
  case subdomains(of: ExactHostname)

  package static let minimumSuffixLabels = 3

  package init(_ raw: String) throws(ValidationError) {
    guard raw.hasPrefix("*.") else {
      self = .exact(try ExactHostname(raw))
      return
    }
    let suffix = try ExactHostname(String(raw.dropFirst(2)))
    guard suffix.rawValue.split(separator: ".").count >= Self.minimumSuffixLabels else {
      throw ValidationError(
        "a wildcard host needs at least \(Self.minimumSuffixLabels) labels after '*.' (got '\(raw)')"
      )
    }
    self = .subdomains(of: suffix)
  }

  package var rawValue: String {
    switch self {
    case .exact(let host): host.rawValue
    case .subdomains(let suffix): "*." + suffix.rawValue
    }
  }

  package var description: String { rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
