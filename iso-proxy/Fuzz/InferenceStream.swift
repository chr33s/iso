import IsoInferenceCore

/// Backend event streams through the production SSE parser and stream
/// translators. The first byte selects the API and a chunk size, so event
/// boundaries land anywhere. Relayed events must be well-formed SSE whose
/// JSON never names the upstream model.
public enum InferenceStreamHarness {
  static let apis: [FrontendAPI] = [.openAIChat, .openAIResponses, .anthropicMessages]

  public static func run(_ bytes: [UInt8]) {
    guard let selector = bytes.first else { return }
    let api = apis[Int(selector) % apis.count]
    let chunk = Int(selector >> 2) + 1
    let body = Array(bytes.dropFirst())
    var parser = SSEParser(maxEventBytes: 1 << 16)
    var translator = StreamTranslator(api: api, alias: "local-coder", maxEventBytes: 1 << 16)
    var offset = 0
    while offset < body.count {
      let end = min(offset + chunk, body.count)
      guard let events = try? parser.feed(body[offset..<end]) else { return }
      for event in events {
        let emitted: [UInt8]?
        do { emitted = try translator.consume(event) } catch { return }
        guard let relayed = emitted else { continue }
        require(relayed.suffix(2) == [0x0A, 0x0A], "relayed events end with a blank line")
        checkModelFields(relayed)
      }
      offset = end
    }
    if translator.outcome == .completed, let body = try? translator.aggregated() {
      checkModelFields(Array("data: ".utf8) + body + [0x0A, 0x0A])
    }
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
