import IsoInferenceCore

/// Backend event streams through the production SSE parser and stream
/// translators. The first byte selects the API (its low two bits: chat,
/// responses, messages; 3 is unused) and a chunk size (the rest), so event
/// boundaries land anywhere. Relayed events must be well-formed SSE whose
/// JSON never names the upstream model.
package enum InferenceStreamHarness {
  static let apis: [FrontendAPI] = [.openAIChat, .openAIResponses, .anthropicMessages]

  /// What one input did, for the corpus replay test.
  package struct Outcome: Sendable {
    package let api: FrontendAPI?
    package let relayed: Int
  }

  @discardableResult
  package static func run(_ bytes: [UInt8]) -> Outcome {
    guard let selector = bytes.first, Int(selector & 0x03) < apis.count else {
      return Outcome(api: nil, relayed: 0)
    }
    let api = apis[Int(selector & 0x03)]
    let chunk = Int(selector >> 2) + 1
    let body = Array(bytes.dropFirst())
    var parser = SSEParser(maxEventBytes: 1 << 16)
    var translator = StreamTranslator(api: api, alias: "local-coder", maxEventBytes: 1 << 16)
    var relayedCount = 0
    var offset = 0
    while offset < body.count {
      let end = min(offset + chunk, body.count)
      guard let events = try? parser.feed(body[offset..<end]) else { break }
      for event in events {
        let emitted: [UInt8]?
        do { emitted = try translator.consume(event) } catch {
          return Outcome(api: api, relayed: relayedCount)
        }
        guard let relayed = emitted else { continue }
        relayedCount += 1
        require(relayed.suffix(2) == [0x0A, 0x0A], "relayed events end with a blank line")
        require(
          relayed.split(separator: 0x0A).allSatisfy { line in
            line.starts(with: Array("data: ".utf8)) || line.starts(with: Array("event: ".utf8))
          }, "every relayed line is an event or data field")
        checkModelFields(relayed)
      }
      offset = end
    }
    if translator.outcome == .completed, let body = try? translator.aggregated() {
      checkModelFields(Array("data: ".utf8) + body + [0x0A, 0x0A])
    }
    return Outcome(api: api, relayed: relayedCount)
  }

  /// The model fields a guest sees carry the alias, never the upstream id.
  static func checkModelFields(_ event: [UInt8]) {
    let text = String(decoding: event, as: UTF8.self)
    guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }),
      case .object(let object)? = try? JSONParser.parse(
        Array(line.dropFirst(6).utf8), limits: .init(maxBytes: 1 << 20, maxDepth: 64))
    else { return }
    for model in [object["model"], object["message"]?["model"], object["response"]?["model"]] {
      require(model != .string("upstream/model"), "the upstream model id is never relayed")
    }
  }
}
