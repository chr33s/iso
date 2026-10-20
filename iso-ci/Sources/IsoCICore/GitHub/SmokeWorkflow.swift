import Foundation

/// The onboarding smoke workflow (spec section 8), generated for operator
/// review only: iso-ci never commits, pushes or edits workflows.
package enum SmokeWorkflow {
  package static let path = ".github/workflows/iso-runner-smoke.yml"

  /// `labels` are the pool's labels; organization pools may also select
  /// their approved runner group.
  package static func generate(labels: [RunnerLabel], runnerGroup: String? = nil) -> String {
    let labelList = labels.map(\.rawValue).joined(separator: ", ")
    let runsOn: String
    if let runnerGroup {
      runsOn = """
            runs-on:
              group: \(yamlQuoted(runnerGroup))
              labels: [\(labelList)]
        """
    } else {
      runsOn = "    runs-on: [\(labelList)]"
    }
    return """
      name: ISO runner smoke
      on:
        workflow_dispatch:
      permissions: {}
      jobs:
        smoke:
      \(runsOn)
          timeout-minutes: 5
          steps:
            - name: Identify the runner
              env:
                CI_RUNNER_NAME: ${{ runner.name }}
              run: |
                uname -a
                printf 'runner=%s\\n' "$CI_RUNNER_NAME"

      """
  }

  static func yamlQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
  }
}

/// Onboarding proof that capacity is fresh and single-use: two consecutive
/// smoke jobs must have used different allocations, VMs and runners.
package enum SmokeVerification {
  package struct Observation: Sendable, Equatable {
    package let allocation: AllocationID
    package let instance: InstanceID?
    package let runnerID: Int64?
    package let runnerName: String?
    package let jobID: Int64?

    package init(_ record: AllocationRecord) {
      allocation = record.id
      instance = record.instance?.instanceID
      runnerID = record.runnerID
      runnerName = record.runnerName
      jobID = record.job?.jobID
    }

    package init(
      allocation: AllocationID, instance: InstanceID?, runnerID: Int64?, runnerName: String?,
      jobID: Int64?
    ) {
      self.allocation = allocation
      self.instance = instance
      self.runnerID = runnerID
      self.runnerName = runnerName
      self.jobID = jobID
    }
  }

  /// Throws unless both jobs ran, on distinct allocations, VMs and runners.
  package static func verify(_ first: Observation, _ second: Observation) throws(CIError) {
    guard let firstJob = first.jobID, let secondJob = second.jobID, firstJob != secondJob else {
      throw CIError(.admissionRefused, "two distinct smoke jobs must be observed")
    }
    guard first.allocation != second.allocation else {
      throw CIError(.admissionRefused, "both smoke jobs used the same allocation")
    }
    guard let a = first.instance, let b = second.instance, a != b else {
      throw CIError(.admissionRefused, "both smoke jobs did not use different clean VMs")
    }
    guard let r1 = first.runnerID, let r2 = second.runnerID, r1 != r2,
      first.runnerName != second.runnerName
    else {
      throw CIError(.admissionRefused, "both smoke jobs did not use different runner registrations")
    }
  }
}
