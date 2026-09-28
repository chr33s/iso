// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CoopCore

extension CoopConfig {
  /// One command's devcontainer translation folded over the loaded values
  /// (Rust `devcontainer::apply_to_config`); the file is never rewritten.
  /// Guest variables replace same-named entries and keep byte order.
  public func applyingDevcontainer(
    vcpus: UInt8?, memory: VmMemory?, postStart: String?,
    guestEnvironment additions: [(name: EnvVarName, value: String)]
  ) -> CoopConfig {
    var variables = guestEnvironment
    for (name, value) in additions {
      variables.removeAll { $0.name == name }
      variables.append(GuestVariable(name: name, value: value))
    }
    variables.sort {
      Array($0.name.rawValue.utf8).lexicographicallyPrecedes(Array($1.name.rawValue.utf8))
    }
    return CoopConfig(
      dataDirectory: dataDirectory,
      vm: VMConfig(
        vcpuCount: vcpus ?? vm.vcpuCount, memory: memory ?? vm.memory,
        templateSize: vm.templateSize),
      sshPort: sshPort,
      github: github, setup: setup, claude: claude, codex: codex, codexAuth: codexAuth,
      proxy: proxy,
      guestEnvironment: variables, profiles: profiles, postStart: postStart ?? self.postStart,
      forwardPorts: forwardPorts,
      updates: updates, appleContainer: appleContainer, workspacePull: workspacePull,
      egress: egress, limits: limits
    )
  }
}
