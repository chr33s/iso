import IsoCore

/// `execution`: enrolled remote hosts for `iso host` commands, which each name
/// their host (spec 5.1). Only the global configuration file may set it;
/// `local` is the implicit host and cannot be redirected. Enrollment identity
/// lives in host state, never here.
package struct ExecutionConfig: Sendable, Equatable {
  package let defaultHost: HostAlias
  package let hosts: [HostAlias: RemoteHostConfig]
  package let remote: RemoteExecutionConfig

  package static let defaults = ExecutionConfig(
    defaultHost: .local, hosts: [:], remote: .defaults)

  package init(
    defaultHost: HostAlias, hosts: [HostAlias: RemoteHostConfig], remote: RemoteExecutionConfig
  ) {
    self.defaultHost = defaultHost
    self.hosts = hosts
    self.remote = remote
  }
}

/// One named remote execution host.
package struct RemoteHostConfig: Sendable, Equatable {
  package enum Transport: String, Sendable, CaseIterable {
    case ssh
  }

  package let transport: Transport
  /// An ssh_config host alias the user trusts; its host-key pin is ssh's.
  package let sshAlias: HostAlias
  /// The installed `iso` on that host, chosen by the user.
  package let agentPath: AgentPath

  package init(transport: Transport, sshAlias: HostAlias, agentPath: AgentPath) {
    self.transport = transport
    self.sshAlias = sshAlias
    self.agentPath = agentPath
  }
}

/// Defaults for remote boots.
package struct RemoteExecutionConfig: Sendable, Equatable {
  package enum Broker: String, Sendable, CaseIterable {
    /// Provider credentials resolve and stay on the client.
    case client
  }

  package static let maxSessionTTL: UInt64 = 24 * 3_600
  package let broker: Broker
  package let defaultSessionTTL: UInt64

  package static let defaults = RemoteExecutionConfig(broker: .client, defaultSessionTTL: 8 * 3_600)

  package init(broker: Broker, defaultSessionTTL: UInt64) {
    self.broker = broker
    self.defaultSessionTTL = defaultSessionTTL
  }
}

extension ConfigDecoder {
  static func execution(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> ExecutionConfig
  {
    let r = try ObjectReader(value, at: path)
    try r.rejectUnknown(allowing: ["default_host", "hosts", "remote"])
    let hosts: [HostAlias: RemoteHostConfig] = try r.defaulted("hosts", [:]) {
      v, p throws(FieldError) in
      let raw = try Parse.map(v, p, remoteHost)
      var out: [HostAlias: RemoteHostConfig] = [:]
      for (key, host) in raw {
        let alias = try Parse.domain(p + [.key(key)]) { () throws(ValidationError) in
          try HostAlias(key)
        }
        guard !alias.isLocal else {
          throw FieldError(
            p + [.key(key)], "\"local\" is the implicit local host and cannot be redefined")
        }
        out[alias] = host
      }
      return out
    }
    let defaultHost = try r.defaulted("default_host", HostAlias.local) { v, p throws(FieldError) in
      let text = try Parse.string(v, p)
      let alias = try Parse.domain(p) { () throws(ValidationError) in try HostAlias(text) }
      guard alias.isLocal || hosts[alias] != nil else {
        throw FieldError(p, "names no host in execution.hosts")
      }
      return alias
    }
    let remote = try r.defaulted("remote", RemoteExecutionConfig.defaults) {
      v, p throws(FieldError) in
      let o = try ObjectReader(v, at: p)
      try o.rejectUnknown(allowing: ["broker", "default_session_ttl"])
      let broker = try o.defaulted("broker", RemoteExecutionConfig.Broker.client) {
        v, p throws(FieldError) in try Parse.stringEnum(v, p, RemoteExecutionConfig.Broker.allCases)
      }
      let ttl = try o.defaulted(
        "default_session_ttl", RemoteExecutionConfig.defaults.defaultSessionTTL
      ) {
        v, p throws(FieldError) in
        let seconds: UInt64
        if case .string(let text) = v {
          guard case .seconds(let parsed) = DurationText(parsing: text) else {
            throw FieldError(p, "expected a duration such as \"8h\" or \"30m\"")
          }
          seconds = parsed
        } else {
          seconds = try Parse.unsigned(v, p, as: UInt64.self)
        }
        guard (60...RemoteExecutionConfig.maxSessionTTL).contains(seconds) else {
          throw FieldError(p, "must be between 1m and 24h")
        }
        return seconds
      }
      return RemoteExecutionConfig(broker: broker, defaultSessionTTL: ttl)
    }
    return ExecutionConfig(defaultHost: defaultHost, hosts: hosts, remote: remote)
  }

  static func remoteHost(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> RemoteHostConfig
  {
    let r = try ObjectReader(value, at: path)
    try r.rejectUnknown(allowing: ["transport", "ssh_alias", "agent_path"])
    let transport = try r.defaulted("transport", RemoteHostConfig.Transport.ssh) {
      v, p throws(FieldError) in try Parse.stringEnum(v, p, RemoteHostConfig.Transport.allCases)
    }
    let alias = try r.required("ssh_alias") { v, p throws(FieldError) in
      let text = try Parse.string(v, p)
      return try Parse.domain(p) { () throws(ValidationError) in try HostAlias(text) }
    }
    let agent = try r.required("agent_path") { v, p throws(FieldError) in
      let text = try Parse.string(v, p)
      return try Parse.domain(p) { () throws(ValidationError) in try AgentPath(text) }
    }
    return RemoteHostConfig(transport: transport, sshAlias: alias, agentPath: agent)
  }
}
