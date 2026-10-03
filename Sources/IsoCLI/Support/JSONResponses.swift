import Foundation
import IsoCore
import IsoHost

extension OutputStreams {
  func writeJSON(_ value: some Encodable) throws {
    write(try JSONOutput.render(value) + "\n")
  }
}

struct InstanceListOutput: Encodable {
  let name: String
  let state: String
}

struct StatusOutput: Encodable {
  let name: String
  let state: String
  let image: String
  let backend = AppleBackend.name
  let usage: Usage?

  init(_ row: Status.Row) {
    name = row.instance.name.rawValue
    state = row.state.rawValue
    image = row.instance.image.rawValue
    usage = row.usage.map(Usage.init)
  }

  enum CodingKeys: String, CodingKey { case name, state, image, backend, usage }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(name, forKey: .name)
    try values.encode(state, forKey: .state)
    try values.encode(image, forKey: .image)
    try values.encode(backend, forKey: .backend)
    try values.encode(usage, forKey: .usage)
  }

  struct Usage: Encodable {
    let load1m: Double?
    let memUsedMiB: UInt64
    let memTotalMiB: UInt64
    let diskUsedMiB: UInt64
    let diskTotalMiB: UInt64

    init(_ usage: ResourceUsage) {
      load1m = usage.load1m.isFinite ? usage.load1m : nil
      memUsedMiB = usage.memUsedMiB
      memTotalMiB = usage.memTotalMiB
      diskUsedMiB = usage.diskUsedMiB
      diskTotalMiB = usage.diskTotalMiB
    }

    enum CodingKeys: String, CodingKey {
      case load1m = "load_1m"
      case memUsedMiB = "mem_used_mib"
      case memTotalMiB = "mem_total_mib"
      case diskUsedMiB = "disk_used_mib"
      case diskTotalMiB = "disk_total_mib"
    }

    func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(load1m, forKey: .load1m)
      try values.encode(memUsedMiB, forKey: .memUsedMiB)
      try values.encode(memTotalMiB, forKey: .memTotalMiB)
      try values.encode(diskUsedMiB, forKey: .diskUsedMiB)
      try values.encode(diskTotalMiB, forKey: .diskTotalMiB)
    }
  }
}

struct ImageListOutput: Encodable {
  let name: String
  let profiles: [String]
  let created: String?

  enum CodingKeys: String, CodingKey {
    case name, profiles, created
    case sizeBytes = "size_bytes"
  }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(name, forKey: .name)
    try values.encode(profiles, forKey: .profiles)
    try values.encode(created, forKey: .created)
    // Runtime-owned image allocation is not measured by this command.
    try values.encodeNil(forKey: .sizeBytes)
  }
}

struct ProfileOutput: Encodable {
  let name: String
  let summary: String
  init(_ entry: Profiles.ListEntry) {
    name = entry.name
    summary = entry.summary
  }
}

struct ProfilesOutput: Encodable {
  let builtin: [ProfileOutput]
  let custom: [ProfileOutput]
}
