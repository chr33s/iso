import IsoHost

/// The Codex `config.toml` parser and printer: the host reads the guest's
/// copy to carry its plugin and project tables across a rewrite, and writes the
/// merged document back into the guest.
public enum CodexTOMLHarness {
  static let canary = "CANARYSECRET"

  public static func run(_ bytes: [UInt8]) {
    guard let text = String(validating: bytes, as: UTF8.self) else { return }
    let table: TOMLTable
    do {
      table = try TOMLTable.parse(text)
    } catch {
      let lines = text.utf8.count { $0 == UInt8(ascii: "\n") } + 1
      require((1...lines).contains(error.line), "error line within the document")
      errorsOmitValues(text)
      return
    }
    let document = table.document
    let reread: TOMLTable
    do {
      reread = try TOMLTable.parse(document)
    } catch {
      require(false, "printed document re-parses")
      return
    }
    require(reread == table, "print/parse round trip")
    require(reread.document == document, "printing is canonical")
    // Each top-level entry carried alone (the preserved guest tables) also
    // round-trips.
    for key in table.sortedKeys {
      let single = TOMLTable([(key, table[key]!)])
      require((try? TOMLTable.parse(single.document)) == single, "single-entry round trip")
    }
  }

  /// A rejected document's error names a line and at most a key, never a
  /// guest value.
  static func errorsOmitValues(_ text: String) {
    guard text.utf8.count < 256, !text.contains(canary) else { return }
    for document in [
      "token = \"\(canary)\"\n" + text, "a = \"\(canary)" + text, "a = '\(canary)" + text,
    ] {
      do {
        _ = try TOMLTable.parse(document)
      } catch {
        require(!error.description.contains(canary), "guest value absent from errors")
      }
    }
  }
}
