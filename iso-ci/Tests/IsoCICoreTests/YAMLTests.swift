import Testing

@testable import IsoCICore

@Suite struct YAMLTests {
  @Test func parsesBlockMappingsSequencesAndScalars() throws {
    let node = try YAML.parse(
      """
      # comment
      name: CI
      on:
        push:
          branches: [main, "release/*"]
      jobs:
        build:
          runs-on: [self-hosted, linux, ARM64, iso-ci]
          steps:
            - uses: actions/checkout@v4
            - name: Test
              run: |
                swift build
                swift test
            - run: echo 'it''s' # trailing
      """)
    #expect(node["name"]?.scalar?.value == "CI")
    #expect(node["on"]?["push"]?["branches"]?.sequence?.count == 2)
    let steps = node["jobs"]?["build"]?["steps"]?.sequence
    #expect(steps?.count == 3)
    #expect(steps?[1]["run"]?.scalar?.value == "swift build\nswift test\n")
    #expect(steps?[2]["run"]?.scalar?.value == "echo 'it''s'")
  }

  @Test func refusesUnsupportedFeatures() {
    for text in [
      "a: &x 1\nb: *x", "a: !!str 1", "a: 1\na: 2", "<<: {a: 1}", "? a\n: b", "a:\n\tb: 1",
      "---\na: 1\n---\nb: 2",
    ] {
      #expect(throws: CIError.self) { try YAML.parse(text) }
    }
  }

  @Test func sequenceAtKeyIndentation() throws {
    let node = try YAML.parse("labels:\n- a\n- b\nnext: 1\n")
    #expect(node["labels"]?.sequence?.count == 2)
    #expect(node["next"]?.json == .integer(1))
  }

  @Test func foldedAndQuotedScalars() throws {
    let node = try YAML.parse(
      """
      a: >-
        one
        two

        three
      b: "x\\ty \\u00e9"
      c: 'multi
        line'
      d: plain
        continued
      """)
    #expect(node["a"]?.scalar?.value == "one two\nthree")
    #expect(node["b"]?.scalar?.value == "x\ty é")
    #expect(node["c"]?.scalar?.value == "multi line")
    #expect(node["d"]?.scalar?.value == "plain continued")
  }
}
