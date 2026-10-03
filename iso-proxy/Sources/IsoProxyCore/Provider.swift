// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

package enum Provider: String, Sendable, Decodable, CaseIterable {
  case anthropic, openai

  package var hostname: String {
    switch self {
    case .anthropic: "api.anthropic.com"
    case .openai: "api.openai.com"
    }
  }
  package var port: Int { 443 }
  package var scheme: String { "https" }
}
