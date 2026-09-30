/// A closed request schema (§8.3.1). Every object member has exactly one
/// rule; members absent from the table are rejected. Validation produces a
/// fresh document holding only forwarded members, so nothing unvetted can
/// reach the backend.
public indirect enum Schema: Sendable {
  case string(maxBytes: Int)
  case enumeration(Set<String>)
  case integer(ClosedRange<Int64>)
  case number(ClosedRange<Double>)
  case bool
  case null
  case array(Schema, maxCount: Int)
  case object(ObjectSchema)
  case tagged(TaggedSchema)
  /// Chosen by the value's JSON type, in order.
  case anyOf([Schema])
  /// Any JSON, bounded by its serialized size (tool schemas, tool inputs).
  case opaque(maxBytes: Int)

  fileprivate func accepts(_ value: JSON) -> Bool {
    switch (self, value) {
    case (.string, .string), (.enumeration, .string), (.integer, .number), (.number, .number),
      (.bool, .bool), (.null, .null), (.array, .array), (.object, .object), (.tagged, .object),
      (.opaque, _):
      true
    case (.anyOf(let options), _): options.contains { $0.accepts(value) }
    default: false
    }
  }
}

public enum Rule: Sendable {
  /// Validated, then copied into the upstream document.
  case forward(Schema)
  /// Validated and handed to the adapter, which sets a host-derived value.
  case rewrite(Schema)
  /// Validated and bounded, then removed.
  case drop(Schema)
  /// A security-relevant field: the request fails with 403.
  case deny
}

public struct ObjectSchema: Sendable {
  public let fields: [String: Rule]
  public let required: Set<String>

  public init(_ fields: [String: Rule], required: Set<String> = []) {
    self.fields = fields
    self.required = required
  }

  func adding(_ extra: [String: Rule]) -> ObjectSchema {
    ObjectSchema(fields.merging(extra) { _, new in new }, required: required)
  }
}

/// Objects discriminated by one member (`type`, or `role`).
public struct TaggedSchema: Sendable {
  public let key: String
  public let variants: [String: ObjectSchema]
  /// Variants removed from their array (hosted-tool declarations, opaque
  /// reasoning history). Only valid for array elements.
  public let dropped: [String: Schema]
  /// Variants whose presence fails the request with 403.
  public let denied: Set<String>
  /// The variant assumed when the key is absent.
  public let defaultVariant: String?

  public init(
    key: String = "type", variants: [String: ObjectSchema], dropped: [String: Schema] = [:],
    denied: Set<String> = [], defaultVariant: String? = nil
  ) {
    self.key = key
    self.variants = variants
    self.dropped = dropped
    self.denied = denied
    self.defaultVariant = defaultVariant
  }
}

/// The outcome of validating one request document.
public struct Validated: Sendable {
  /// Forwarded members only.
  public var document: JSONObject
  /// Top-level rewrite members as the guest sent them.
  public var rewrites: [String: JSON]
}

public enum SchemaValidator {
  public static func validate(_ root: JSON, _ schema: ObjectSchema) throws(InferenceError)
    -> Validated
  {
    guard case .object(let object) = root else {
      throw InferenceError(.requestInvalid, "request body must be a JSON object")
    }
    var rewrites: [String: JSON] = [:]
    let document = try validateObject(object, schema, path: "", rewrites: &rewrites)
    return Validated(document: document, rewrites: rewrites)
  }

  static func validateObject(
    _ object: JSONObject, _ schema: ObjectSchema, path: String, rewrites: inout [String: JSON]
  ) throws(InferenceError) -> JSONObject {
    var out = JSONObject()
    for member in object.members {
      let field = join(path, member.key)
      guard let rule = schema.fields[member.key] else {
        throw InferenceError(.unsupported, "field '\(field)' is not supported")
      }
      switch rule {
      case .deny:
        throw InferenceError(.policyDenied, "field '\(field)' is not permitted")
      case .forward(let inner):
        if let value = try validate(member.value, inner, path: field, rewrites: &rewrites) {
          out[member.key] = value
        }
      case .drop(let inner):
        _ = try validate(member.value, inner, path: field, rewrites: &rewrites)
      case .rewrite(let inner):
        if let value = try validate(member.value, inner, path: field, rewrites: &rewrites) {
          rewrites[field] = value
        }
      }
    }
    for key in schema.required.sorted() where object[key] == nil {
      throw InferenceError(.requestInvalid, "field '\(join(path, key))' is required")
    }
    return out
  }

  /// nil only for a dropped array element; callers outside arrays never
  /// see it because `dropped` variants are rejected there.
  static func validate(
    _ value: JSON, _ schema: Schema, path: String, rewrites: inout [String: JSON]
  ) throws(InferenceError) -> JSON? {
    switch schema {
    case .string(let maxBytes):
      guard case .string(let text) = value else { throw typeError(path, "a string", value) }
      guard text.utf8.count <= maxBytes else {
        throw InferenceError(.requestTooLarge, "field '\(path)' exceeds \(maxBytes) bytes")
      }
      return value
    case .enumeration(let allowed):
      guard case .string(let text) = value else { throw typeError(path, "a string", value) }
      guard allowed.contains(text) else {
        throw InferenceError(.unsupported, "field '\(path)' has an unsupported value")
      }
      return value
    case .integer(let range):
      guard case .number(let number) = value, let int = number.int64 else {
        throw typeError(path, "an integer", value)
      }
      guard range.contains(int) else {
        throw InferenceError(
          .requestInvalid, "field '\(path)' must be in \(range.lowerBound)...\(range.upperBound)")
      }
      return value
    case .number(let range):
      guard case .number(let number) = value, let double = number.double, double.isFinite else {
        throw typeError(path, "a number", value)
      }
      guard range.contains(double) else {
        throw InferenceError(
          .requestInvalid, "field '\(path)' must be in \(range.lowerBound)...\(range.upperBound)")
      }
      return value
    case .bool:
      guard case .bool = value else { throw typeError(path, "a boolean", value) }
      return value
    case .null:
      guard case .null = value else { throw typeError(path, "null", value) }
      return value
    case .array(let element, let maxCount):
      guard case .array(let elements) = value else { throw typeError(path, "an array", value) }
      guard elements.count <= maxCount else {
        throw InferenceError(.requestInvalid, "field '\(path)' has more than \(maxCount) entries")
      }
      var out: [JSON] = []
      out.reserveCapacity(elements.count)
      for (index, item) in elements.enumerated() {
        let itemPath = "\(path)[\(index)]"
        if case .tagged(let tagged) = element {
          if let kept = try validateTagged(
            item, tagged, path: itemPath, rewrites: &rewrites, inArray: true)
          {
            out.append(.object(kept))
          }
        } else if let kept = try validate(item, element, path: itemPath, rewrites: &rewrites) {
          out.append(kept)
        }
      }
      return .array(out)
    case .object(let objectSchema):
      guard case .object(let object) = value else { throw typeError(path, "an object", value) }
      return .object(try validateObject(object, objectSchema, path: path, rewrites: &rewrites))
    case .tagged(let tagged):
      return try validateTagged(value, tagged, path: path, rewrites: &rewrites, inArray: false)
        .map(JSON.object)
    case .anyOf(let options):
      guard let chosen = options.first(where: { $0.accepts(value) }) else {
        throw InferenceError(.requestInvalid, "field '\(path)' has an unsupported type")
      }
      return try validate(value, chosen, path: path, rewrites: &rewrites)
    case .opaque(let maxBytes):
      guard value.serialized.count <= maxBytes else {
        throw InferenceError(.requestTooLarge, "field '\(path)' exceeds \(maxBytes) bytes")
      }
      return value
    }
  }

  static func validateTagged(
    _ value: JSON, _ tagged: TaggedSchema, path: String, rewrites: inout [String: JSON],
    inArray: Bool
  ) throws(InferenceError) -> JSONObject? {
    guard case .object(let object) = value else { throw typeError(path, "an object", value) }
    let tag: String
    switch object[tagged.key] {
    case .string(let text)?: tag = text
    case nil:
      guard let fallback = tagged.defaultVariant else {
        throw InferenceError(.requestInvalid, "field '\(join(path, tagged.key))' is required")
      }
      tag = fallback
    case let other?: throw typeError(join(path, tagged.key), "a string", other)
    }
    if tagged.denied.contains(tag) {
      throw InferenceError(
        .policyDenied, "'\(displayName(tag))' at '\(path)' is not permitted")
    }
    if let droppedSchema = tagged.dropped[tag], inArray {
      _ = try validate(value, droppedSchema, path: path, rewrites: &rewrites)
      return nil
    }
    guard let variant = tagged.variants[tag] else {
      throw InferenceError(.unsupported, "'\(displayName(tag))' at '\(path)' is not supported")
    }
    return try validateObject(object, variant, path: path, rewrites: &rewrites)
  }

  static func typeError(_ path: String, _ expected: String, _ value: JSON) -> InferenceError {
    InferenceError(.requestInvalid, "field '\(path)' must be \(expected), found \(value.typeName)")
  }

  static func join(_ path: String, _ key: String) -> String {
    path.isEmpty ? displayName(key) : path + "." + displayName(key)
  }
}
