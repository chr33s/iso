// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Environmental checks run at lifecycle boundaries (`validate`, `setup`,
/// `up`, `start`). Value invariants live in the model types; only filesystem
/// facts, which can change after loading, are checked here.
package struct ConfigValidationReport: Sendable, Equatable {
  package let warnings: [String]
  package let errors: [String]
}

package protocol ConfigFileSystem {
  func exists(_ path: String) -> Bool
  func isDirectory(_ path: String) -> Bool
}

package struct LocalConfigFileSystem: ConfigFileSystem {
  package init() {}
  package func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
  package func isDirectory(_ path: String) -> Bool {
    var directory: ObjCBool = false
    // Foundation borrows this initialized output value for the duration of the call.
    return unsafe FileManager.default.fileExists(atPath: path, isDirectory: &directory)
      && directory.boolValue
  }
}

extension IsoConfig {
  package func validate(fileSystem: some ConfigFileSystem = LocalConfigFileSystem())
    -> ConfigValidationReport
  {
    var warnings: [String] = []
    var errors: [String] = []
    if let parent = dataDirectory.parent, !parent.path.isEmpty, !fileSystem.exists(parent.path) {
      warnings.append("data_dir parent '\(parent.path)' does not exist (will be created on setup)")
    }
    for (name, agent) in [("claude", claude), ("codex", codex)] {
      if case .custom(let path) = agent.configDirectory, !fileSystem.isDirectory(path.path) {
        errors.append("\(name).config_dir '\(path.path)' does not exist or is not a directory")
      }
    }
    if codexAuth == .chatgpt, proxy.openai != nil {
      errors.append(
        "codex.auth = \"chatgpt\" conflicts with proxy.openai; Codex account auth uses ChatGPT workspace credentials, while the OpenAI proxy uses an API key"
      )
    }
    for (name, agent) in [("claude", claude), ("codex", codex)] {
      for entry in agent.marketplaces where entry.hasPrefix("/") && !fileSystem.exists(entry) {
        errors.append(
          "\(name).marketplaces entry '\(entry)' looks like a local path but does not exist")
      }
    }
    return ConfigValidationReport(warnings: warnings, errors: errors)
  }

  /// Throws the joined errors; returns warnings for the caller to report.
  package func validated(fileSystem: some ConfigFileSystem = LocalConfigFileSystem())
    throws(ConfigError) -> [String]
  {
    let report = validate(fileSystem: fileSystem)
    guard report.errors.isEmpty else { throw .validation(errors: report.errors) }
    return report.warnings
  }
}
