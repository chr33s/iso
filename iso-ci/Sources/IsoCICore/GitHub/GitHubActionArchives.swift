import Foundation

/// Host-side fetches for `iso-ci actions import`: resolve an approved
/// action's ref to an exact commit, then download that commit's tarball.
/// Unauthenticated public reads only; no App or installation token is used.
extension GitHubAPI {
  package func resolveCommit(repository: RepositoryName, ref: String) throws(CIError) -> String {
    let reply = try send(
      .get, url: try url("/repos/\(repository.owner)/\(repository.name)/commits/\(ref)"),
      auth: .none)
    guard let sha = reply.json?["sha"]?.stringValue, sha.utf8.count == 40,
      Array(sha.utf8).allSatisfy(isLowerHex)
    else {
      throw CIError(.githubRefused, "GitHub did not resolve \(repository)@\(ref) to a commit")
    }
    return sha
  }

  package func downloadArchive(repository: RepositoryName, commit: String, limit: Int)
    throws(CIError)
    -> [UInt8]
  {
    guard commit.utf8.count == 40, Array(commit.utf8).allSatisfy(isLowerHex) else {
      throw CIError.invalid("archive downloads need an exact commit")
    }
    guard
      let target = URL(
        string:
          "https://codeload.github.com/\(repository.owner)/\(repository.name)/tar.gz/\(commit)")
    else { throw CIError.invalid("invalid archive URL") }
    let response = try http.send(
      GitHubHTTPRequest(
        method: .get, url: target, headers: ["User-Agent": IsoCIVersion.clientBuild],
        timeoutSeconds: 120))
    guard response.status == 200 else {
      throw CIError(.githubRefused, "archive download returned HTTP \(response.status)")
    }
    guard response.body.count <= limit, response.body.starts(with: [0x1F, 0x8B]) else {
      throw CIError.invalid("the downloaded archive is not a bounded gzip tarball")
    }
    return response.body
  }
}
