import Foundation
import Synchronization

/// A secret string that never prints. Installation tokens, JIT material and
/// JWTs travel in this type so an accidental interpolation shows nothing.
package struct RedactedSecret: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  package let value: String

  package init(_ value: String) { self.value = value }

  package var description: String { "<redacted>" }
  package var debugDescription: String { "<redacted>" }
  package var bytes: [UInt8] { Array(value.utf8) }
}

package enum GitHubHTTPMethod: String, Sendable {
  case get = "GET"
  case post = "POST"
  case delete = "DELETE"
  case patch = "PATCH"
  case put = "PUT"
}

package struct GitHubHTTPRequest: Sendable {
  package var method: GitHubHTTPMethod
  package var url: URL
  /// Header values may carry credentials; never logged.
  package var headers: [String: String]
  package var body: [UInt8]?
  package var timeoutSeconds: Double

  package init(
    method: GitHubHTTPMethod, url: URL, headers: [String: String] = [:], body: [UInt8]? = nil,
    timeoutSeconds: Double = 30
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeoutSeconds = timeoutSeconds
  }
}

package struct GitHubHTTPResponse: Sendable, Equatable {
  package let status: Int
  /// Lowercased header names.
  package let headers: [String: String]
  package let body: [UInt8]

  package init(status: Int, headers: [String: String] = [:], body: [UInt8] = []) {
    self.status = status
    self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    self.body = body
  }
}

/// One HTTP exchange. A thrown error means no response arrived (the request
/// may or may not have been processed).
package protocol GitHubHTTP: Sendable {
  func send(_ request: GitHubHTTPRequest) throws(CIError) -> GitHubHTTPResponse
}

/// Waits between retries; injectable so tests never sleep.
package protocol GitHubSleeper: Sendable {
  func sleep(seconds: Double)
}

package struct GitHubThreadSleeper: GitHubSleeper {
  package init() {}
  package func sleep(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}

/// URLSession transport with a bounded response body. Redirects are not
/// followed, so an Authorization header never reaches another origin.
package final class URLSessionGitHubHTTP: GitHubHTTP {
  package static let maxBody = 8 << 20
  private let session: URLSession

  private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  package init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
  }

  package func send(_ request: GitHubHTTPRequest) throws(CIError) -> GitHubHTTPResponse {
    var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeoutSeconds)
    urlRequest.httpMethod = request.method.rawValue
    for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
    if let body = request.body { urlRequest.httpBody = Data(body) }
    let outcome = Mutex<Result<GitHubHTTPResponse, CIError>?>(nil)
    let done = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: urlRequest) { data, response, error in
      let result: Result<GitHubHTTPResponse, CIError>
      if let error {
        result = .failure(
          CIError(
            .githubUnavailable, "GitHub request failed: \((error as NSError).localizedDescription)")
        )
      } else if let http = response as? HTTPURLResponse {
        let bytes = data.map(Array.init) ?? []
        if bytes.count > Self.maxBody {
          result = .failure(CIError(.githubUnavailable, "GitHub response exceeded its size limit"))
        } else {
          var headers: [String: String] = [:]
          for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
          }
          result = .success(
            GitHubHTTPResponse(status: http.statusCode, headers: headers, body: bytes))
        }
      } else {
        result = .failure(CIError(.githubUnavailable, "GitHub returned no HTTP response"))
      }
      outcome.withLock { $0 = result }
      done.signal()
    }
    task.resume()
    if done.wait(timeout: .now() + request.timeoutSeconds + 5) == .timedOut {
      task.cancel()
      throw CIError(.githubUnavailable, "GitHub request timed out")
    }
    guard let result = outcome.withLock({ $0 }) else {
      throw CIError(.githubUnavailable, "GitHub request produced no result")
    }
    return try result.get()
  }
}

/// A scripted transport for tests: each handler sees the request and
/// returns a response or throws. Every request is recorded.
package final class ScriptedGitHubHTTP: GitHubHTTP {
  package typealias Handler = @Sendable (GitHubHTTPRequest) throws(CIError) -> GitHubHTTPResponse?

  private let state = Mutex<(handlers: [Handler], requests: [GitHubHTTPRequest])>(([], []))

  package init() {}

  /// Handlers are tried newest first; the first non-nil response wins.
  package func on(_ handler: @escaping Handler) {
    state.withLock { $0.handlers.insert(handler, at: 0) }
  }

  /// Responds to `method path` (path without query) with `status` and `json`.
  package func route(
    _ method: GitHubHTTPMethod, _ path: String, status: Int = 200, json: String = "{}",
    headers: [String: String] = [:]
  ) {
    on { request in
      guard request.method == method, request.url.path == path else { return nil }
      return GitHubHTTPResponse(status: status, headers: headers, body: Array(json.utf8))
    }
  }

  package var requests: [GitHubHTTPRequest] { state.withLock { $0.requests } }

  package func send(_ request: GitHubHTTPRequest) throws(CIError) -> GitHubHTTPResponse {
    let handlers = state.withLock { state -> [Handler] in
      state.requests.append(request)
      return state.handlers
    }
    for handler in handlers {
      if let response = try handler(request) { return response }
    }
    return GitHubHTTPResponse(status: 404, body: Array(#"{"message":"Not Found"}"#.utf8))
  }
}

/// Records requested waits instead of sleeping.
package final class RecordingGitHubSleeper: GitHubSleeper {
  private let waits = Mutex<[Double]>([])
  package init() {}
  package func sleep(seconds: Double) { waits.withLock { $0.append(seconds) } }
  package var recorded: [Double] { waits.withLock { $0 } }
}
