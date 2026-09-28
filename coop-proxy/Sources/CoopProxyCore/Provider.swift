// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

public enum Provider: String, Sendable, Decodable, CaseIterable {
  case anthropic, openai

  public var hostname: String {
    switch self {
    case .anthropic: "api.anthropic.com"
    case .openai: "api.openai.com"
    }
  }
  public var port: Int { 443 }
  public var scheme: String { "https" }
}
