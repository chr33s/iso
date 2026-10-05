// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

package struct ProfileDefinition: Sendable, Equatable {
  package let name: String
  package let aptPackages: [String]
  package let preInstall: String?
  package let postInstall: String?
  package let marketplaces: [String]
  package let plugins: [String]
}

package enum Profiles {
  static let claudePluginsOfficial = "https://github.com/anthropics/claude-plugins-official"

  package static let builtin: [ProfileDefinition] = [
    .init(
      name: "python", aptPackages: ["python3", "python3-pip", "python3-venv"], preInstall: nil,
      postInstall: nil,
      marketplaces: [], plugins: []),
    .init(
      name: "node", aptPackages: ["nodejs"],
      preInstall: EmbeddedResources.guestScript("profiles/node-pre.sh"),
      postInstall: nil, marketplaces: [], plugins: []),
    .init(
      name: "c", aptPackages: ["clang", "llvm", "gdb", "valgrind", "cmake"], preInstall: nil,
      postInstall: nil,
      marketplaces: [claudePluginsOfficial], plugins: ["clangd-lsp@claude-plugins-official"]),
    .init(
      name: "fuzz", aptPackages: ["clang", "llvm", "afl++", "lcov"], preInstall: nil,
      postInstall: nil,
      marketplaces: [], plugins: []),
    .init(
      name: "rust", aptPackages: [], preInstall: nil,
      postInstall: EmbeddedResources.guestScript("profiles/rust-post.sh"),
      marketplaces: [claudePluginsOfficial],
      plugins: ["rust-analyzer-lsp@claude-plugins-official"]),
    .init(
      name: "go", aptPackages: ["golang"], preInstall: nil, postInstall: nil, marketplaces: [],
      plugins: []),
  ]

  static func custom(_ name: String, _ profile: CustomProfile) -> ProfileDefinition {
    .init(
      name: name, aptPackages: profile.aptPackages, preInstall: profile.preInstall,
      postInstall: profile.postInstall,
      marketplaces: profile.marketplaces, plugins: profile.plugins)
  }

  static func sortedCustomNames(_ config: IsoConfig) -> [String] {
    config.profiles.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }

  /// A configured profile shadows the built-in of the same name.
  package static func lookup(_ name: String, config: IsoConfig) throws(HostError)
    -> ProfileDefinition
  {
    if let profile = config.profiles[name] { return custom(name, profile) }
    if let profile = builtin.first(where: { $0.name == name }) { return profile }
    let available = builtin.map(\.name) + sortedCustomNames(config)
    throw HostError(
      "Unknown profile: \(name)\nAvailable profiles: \(available.joined(separator: ", "))")
  }

  package static func builtinSummary(_ profile: ProfileDefinition) -> String {
    var parts: [String] = []
    if !profile.aptPackages.isEmpty { parts.append(profile.aptPackages.joined(separator: ", ")) }
    if profile.preInstall != nil { parts.append("pre-install script") }
    if profile.postInstall != nil { parts.append("post-install script") }
    if !profile.plugins.isEmpty {
      parts.append("plugins: " + profile.plugins.joined(separator: ", "))
    }
    return parts.isEmpty ? "(empty)" : parts.joined(separator: "; ")
  }

  package static func customSummary(_ profile: CustomProfile) -> String {
    var parts: [String] = []
    if !profile.aptPackages.isEmpty { parts.append("\(profile.aptPackages.count) apt packages") }
    if profile.preInstall != nil { parts.append("pre-install script") }
    if profile.postInstall != nil { parts.append("post-install script") }
    if !profile.marketplaces.isEmpty { parts.append("\(profile.marketplaces.count) marketplaces") }
    if !profile.plugins.isEmpty { parts.append("\(profile.plugins.count) plugins") }
    return parts.isEmpty ? "(empty)" : "(" + parts.joined(separator: ", ") + ")"
  }

  /// `(none)`, the only line, or `first ... (N lines)`.
  package static func scriptSummary(_ script: String?) -> String {
    guard let script, !script.isEmpty else { return "(none)" }
    let lines = rustLines(script)
    guard lines.count > 1 else { return lines.first ?? "" }
    return "\(lines[0]) ... (\(lines.count) lines)"
  }

  package struct ListEntry: Sendable, Equatable {
    package let name: String
    package let summary: String
  }

  package static func listing(_ config: IsoConfig) -> (builtin: [ListEntry], custom: [ListEntry]) {
    (
      builtin.map { ListEntry(name: $0.name, summary: builtinSummary($0)) },
      sortedCustomNames(config).map {
        ListEntry(name: $0, summary: customSummary(config.profiles[$0]!))
      }
    )
  }
}

package func resolveProfiles(_ names: [String], _ config: IsoConfig) throws -> [ProfileDefinition] {
  var resolved: [ProfileDefinition] = []
  var unknown: [String] = []
  for name in names {
    if let definition = try? Profiles.lookup(name, config: config) {
      resolved.append(definition)
    } else {
      unknown.append(name)
    }
  }
  guard unknown.isEmpty else {
    let available =
      Profiles.builtin.map(\.name)
      + config.profiles.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    throw HostError(
      "Unknown profile(s): \(unknown.joined(separator: ", "))\nAvailable profiles: \(available.joined(separator: ", "))"
    )
  }
  return resolved
}
