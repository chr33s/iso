import Foundation
import Testing

@testable import IsoCICore

@Suite struct PreflightExpressionTests {
  let contexts = ExpressionContexts(
    github: ["event_name": "push", "ref": "refs/heads/main", "event": ["number": 7]],
    env: ["MODE": "Release"],
    steps: ["build": ["outputs": ["artifact": "a.tgz"], "conclusion": "success"]],
    secrets: ["TOKEN": "s3cr3t-value"],
    matrix: ["os": "linux", "node": 20],
    needs: [
      "a": ["result": "success", "outputs": ["x": "1"]],
      "b": ["result": "failure", "outputs": ["x": "2"]],
    ])

  func eval(_ text: String) throws -> JSONValue { try ExpressionEvaluator.evaluate(text, contexts) }

  @Test func literalsAndAccess() throws {
    #expect(try eval("0xff") == .integer(255))
    #expect(try eval("-1.5e1") == .integer(-15))
    #expect(try eval("2.5") == .double(2.5))
    #expect(try eval("'it''s'") == .string("it's"))
    #expect(try eval("null") == .null)
    #expect(try eval("github.event.number") == .integer(7))
    #expect(try eval("github['event_name']") == .string("push"))
    #expect(try eval("GitHub.Event_Name") == .string("push"))
    #expect(try eval("steps.build.outputs.artifact") == .string("a.tgz"))
    #expect(try eval("github.missing.deeper") == .null)
    #expect(try eval("needs.*.result") == .array(["success", "failure"]))
    #expect(try eval("needs.*.outputs.x") == .array(["1", "2"]))
  }

  @Test func operatorsAndCoercion() throws {
    #expect(try eval("'ABC' == 'abc'") == .bool(true))
    #expect(try eval("1 == '1'") == .bool(true))
    #expect(try eval("'' == 0") == .bool(true))
    #expect(try eval("null == false") == .bool(true))
    #expect(try eval("'abc' == 0") == .bool(false))
    #expect(try eval("'x' < 'Y'") == .bool(true))
    #expect(try eval("2 >= 10") == .bool(false))
    #expect(try eval("'NaN' != 'NaN'") == .bool(false))
    #expect(try eval("'a' < 1") == .bool(false))
    #expect(try eval("!0") == .bool(true))
    #expect(try eval("matrix.node > 18 && matrix.os") == .string("linux"))
    #expect(try eval("'' || 'fallback'") == .string("fallback"))
    #expect(try eval("(1 == 1) && !(2 == 3)") == .bool(true))
  }

  @Test func functions() throws {
    #expect(try eval("contains('Hello', 'ELL')") == .bool(true))
    #expect(try eval("contains(fromJSON('[1, \"two\"]'), 'TWO')") == .bool(true))
    #expect(try eval("startsWith(github.ref, 'refs/heads/')") == .bool(true))
    #expect(try eval("endsWith('file.TXT', '.txt')") == .bool(true))
    #expect(try eval("format('{0}-{{x}}-{1}', 'a', 2)") == .string("a-{x}-2"))
    #expect(try eval("join(fromJSON('[\"a\",\"b\"]'), '+')") == .string("a+b"))
    #expect(try eval("join('solo')") == .string("solo"))
    #expect(try eval("toJSON(matrix)") == .string("{\n  \"node\": 20,\n  \"os\": \"linux\"\n}"))
    #expect(try eval("fromJSON('{\"a\": [1]}').a[0]") == .integer(1))
    #expect(throws: CIError.self) { try eval("format('{1}', 'a')") }
    #expect(throws: CIError.self) { try eval("hashFiles('x')") }
  }

  @Test func statusFunctions() throws {
    var status = contexts
    status.status = ExpressionStatus(success: false, failure: true, cancelled: false)
    #expect(try ExpressionEvaluator.condition("failure()", status))
    #expect(!(try ExpressionEvaluator.condition("success()", status)))
    #expect(try ExpressionEvaluator.condition("always()", status))
    status.status = ExpressionStatus(success: true, failure: false, cancelled: true)
    #expect(try ExpressionEvaluator.condition("cancelled()", status))
    #expect(!(try ExpressionEvaluator.condition("success()", status)))
    #expect(throws: CIError.self) { try ExpressionEvaluator.condition("success()", contexts) }
  }

  @Test func parseErrorsAndBounds() {
    for bad in [
      "", "1 +", "a.", "unknown.thing", "nosuch()", "contains('a')", "'unterminated", "a = b",
      "github.[0]", String(repeating: "(", count: 200) + "1" + String(repeating: ")", count: 200),
      String(repeating: "a", count: Expression.maxLength + 1),
    ] {
      #expect(throws: CIError.self) { try Expression.parse(bad) }
    }
  }

  @Test func errorsNeverEchoSecretValues() {
    let calls = [
      "fromJSON(secrets.TOKEN)", "fromJSON(format('{0}', secrets.TOKEN))",
      "format('{9}', secrets.TOKEN)",
    ]
    for call in calls {
      do {
        _ = try eval(call)
        Issue.record("expected an error for \(call)")
      } catch let error as CIError {
        #expect(!error.message.contains("s3cr3t"))
        #expect(!error.details.values.contains { $0.contains("s3cr3t") })
      } catch {
        Issue.record("unexpected error type")
      }
    }
  }

  @Test func templateSegmentsAndFormatComposition() throws {
    #expect(try TemplateConverter.segments("plain") == [.literal("plain")])
    #expect(try TemplateConverter.segments("${{ a.b }}") == [.expression("a.b")])
    #expect(
      try TemplateConverter.segments("x ${{ format('}}', 1) }} y")
        == [.literal("x "), .expression("format('}}', 1)"), .literal(" y")])
    #expect(throws: CIError.self) { try TemplateConverter.segments("${{ open") }
    let composed = TemplateConverter.composed(
      try TemplateConverter.segments("it's {a} ${{ matrix.os }}/${{ matrix.node }}"))
    #expect(composed == "format('it''s {{a}} {0}/{1}', matrix.os, matrix.node)")
    #expect(try ExpressionEvaluator.evaluate(composed!, contexts) == .string("it's {a} linux/20"))
  }

  @Test func fieldContextAvailability() {
    var converter = TemplateConverter()
    _ = converter.condition(
      .scalar(YAMLScalar(value: "steps.x.outcome == 'success'", style: .plain, line: 3)),
      field: .jobIf, path: "jobs.a.if")
    #expect(converter.diagnostics.count == 1)
    var allowed = TemplateConverter()
    let condition = allowed.condition(
      .scalar(YAMLScalar(value: "steps.x.outcome == 'success'", style: .plain, line: 3)),
      field: .stepIf, path: "jobs.a.steps[0].if")
    #expect(allowed.diagnostics.isEmpty)
    #expect(condition == "success() && (steps.x.outcome == 'success')")
    var status = TemplateConverter()
    _ = status.string("${{ success() }}", field: .stepField, line: 1, path: "run")
    #expect(status.diagnostics.count == 1)
  }
}
