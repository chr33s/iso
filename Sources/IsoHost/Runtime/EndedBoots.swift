import Foundation

/// One ended boot's computer-use counts in `inspect` (`endedBoots`), as its
/// owner last wrote them.
package struct EndedBoot: Sendable, Equatable, Decodable {
  package let bootID: String
  /// Absent when the sandbox was created without guest-driven computer use.
  package let guestComputerUse: MacGuestCUCounts?
  /// Absent when no live-view stream started that boot.
  package let liveView: MacLiveViewCounts?

  enum CodingKeys: String, CodingKey {
    case bootID = "bootId"
    case guestComputerUse, liveView
  }

  package init(bootID: String, guestComputerUse: MacGuestCUCounts?, liveView: MacLiveViewCounts?) {
    self.bootID = bootID
    self.guestComputerUse = guestComputerUse
    self.liveView = liveView
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let id = try c.decode(String.self, forKey: .bootID)
    guard Self.isBootID(id) else {
      throw DecodingError.dataCorruptedError(
        forKey: .bootID, in: c, debugDescription: "not a boot id")
    }
    self.init(
      bootID: id,
      guestComputerUse: (try? c.decodeIfPresent(MacGuestCUCounts.self, forKey: .guestComputerUse))
        ?? nil,
      liveView: (try? c.decodeIfPresent(MacLiveViewCounts.self, forKey: .liveView)) ?? nil)
  }

  /// 32 lowercase hex digits, as the runtime makes boot ids: the host keeps
  /// the ids it has audited.
  static func isBootID(_ s: String) -> Bool {
    s.utf8.count == 32
      && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }
}

/// `endedBoots` in `inspect`, read for the audit only: nothing in it fails
/// the inspection. An entry that does not decode is dropped, as invalid
/// counts are, and only the last ``limit`` are kept.
package struct EndedBoots: Sendable, Equatable, Decodable {
  /// As many as the runtime keeps.
  package static let limit = 8
  package let boots: [EndedBoot]

  private struct Skipped: Decodable {
    init(from decoder: any Decoder) throws {}
  }

  package init(from decoder: any Decoder) throws {
    var boots: [EndedBoot] = []
    if var list = try? decoder.unkeyedContainer() {
      while !list.isAtEnd {
        if (try? list.decodeNil()) == true { continue }
        if let boot = try? list.decode(EndedBoot.self) {
          boots.append(boot)
        } else if (try? list.decode(Skipped.self)) == nil {
          break
        }
      }
    }
    self.boots = Array(boots.suffix(Self.limit))
  }
}
