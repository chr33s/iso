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
  /// The most response-body bytes the transport receives; past it the
  /// transfer is aborted and the request fails.
  package var maxResponseBytes: Int

  /// Every API and Actions service reply fits; only archive downloads ask
  /// for more.
  package static let defaultMaxResponseBytes = 8 << 20

  package init(
    method: GitHubHTTPMethod, url: URL, headers: [String: String] = [:], body: [UInt8]? = nil,
    timeoutSeconds: Double = 30, maxResponseBytes: Int = Self.defaultMaxResponseBytes
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeoutSeconds = timeoutSeconds
    self.maxResponseBytes = maxResponseBytes
  }
}

package struct GitHubHTTPResponse: Sendable, Equatable {
  package let status: Int
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

package protocol GitHubSleeper: Sendable {
  func sleep(seconds: Double)
}

package struct GitHubThreadSleeper: GitHubSleeper {
  package init() {}
  package func sleep(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}

/// URLSession transport that streams the response body and aborts the
/// transfer once it passes the request's `maxResponseBytes` (a declared
/// larger `Content-Length` is refused before any body arrives), so no reply
/// is held in memory beyond that bound. Redirects are not followed, so an
/// Authorization header never reaches another origin.
package final class URLSessionGitHubHTTP: GitHubHTTP {
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

  /// One task's receiver: accumulates at most `limit` body bytes.
  private final class BoundedReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Received {
      var response: HTTPURLResponse?
      var body: [UInt8] = []
      var exceeded = false
      var error: (any Error)?
    }

    let limit: Int
    let received = Mutex(Received())
    let done = DispatchSemaphore(value: 0)

    init(limit: Int) { self.limit = limit }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      let declared = response.expectedContentLength
      let exceeded = declared > Int64(limit)
      received.withLock {
        $0.response = response as? HTTPURLResponse
        $0.exceeded = exceeded
      }
      completionHandler(exceeded ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      let exceeded = received.withLock { state -> Bool in
        guard !state.exceeded else { return true }
        guard state.body.count + data.count <= limit else {
          state.exceeded = true
          state.body = []
          return true
        }
        state.body += data
        return false
      }
      if exceeded { dataTask.cancel() }
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
      received.withLock { $0.error = error }
      done.signal()
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
    let receiver = BoundedReceiver(limit: max(0, request.maxResponseBytes))
    let task = session.dataTask(with: urlRequest)
    task.delegate = receiver
    task.resume()
    if receiver.done.wait(timeout: .now() + request.timeoutSeconds + 5) == .timedOut {
      task.cancel()
      throw CIError(.githubUnavailable, "GitHub request timed out")
    }
    let received = receiver.received.withLock { $0 }
    // Checked first: an aborted transfer also completes with a cancellation.
    guard !received.exceeded else {
      throw CIError(.githubUnavailable, "GitHub response exceeded its size limit")
    }
    if let error = received.error {
      throw CIError(
        .githubUnavailable, "GitHub request failed: \((error as NSError).localizedDescription)")
    }
    guard let http = received.response else {
      throw CIError(.githubUnavailable, "GitHub returned no HTTP response")
    }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      if let key = key as? String, let value = value as? String { headers[key] = value }
    }
    return GitHubHTTPResponse(status: http.statusCode, headers: headers, body: received.body)
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

package final class RecordingGitHubSleeper: GitHubSleeper {
  private let waits = Mutex<[Double]>([])
  package init() {}
  package func sleep(seconds: Double) { waits.withLock { $0.append(seconds) } }
  package var recorded: [Double] { waits.withLock { $0 } }
}
