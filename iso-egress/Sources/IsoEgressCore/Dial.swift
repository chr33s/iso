import Darwin
import Dispatch
import Foundation
import Synchronization

/// Choose one numeric address only when every answer is public and none
/// belongs to this host. A mixed answer is denied entirely.
package enum AddressChoice {
  package static func firstPublic(_ addresses: [String], local: Set<String>) -> String? {
    guard !addresses.isEmpty, addresses.allSatisfy({ AddressPolicy.isPublic($0, local: local) })
    else { return nil }
    return addresses[0]
  }
}

package enum Deadline {
  /// Returns nil when `work` has not finished within `limit`. The work may
  /// still complete; its result is discarded.
  package static func wait<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () -> T)
    -> T?
  {
    let nanoseconds = Int(min(Monotonic.nanoseconds(limit), UInt64(Int.max)))
    let box = Box<T>(deadline: .now() + .nanoseconds(nanoseconds))
    let thread = Thread {
      let value = work()
      box.finish(value)
    }
    thread.start()
    return box.value()
  }
}

final class Box<T: Sendable>: Sendable {
  private enum State: Sendable {
    case waiting
    case finished(T)
    case abandoned
  }

  private let signal = DispatchSemaphore(value: 0)
  private let deadline: DispatchTime
  private let state = Mutex(State.waiting)

  init(deadline: DispatchTime) { self.deadline = deadline }

  func finish(_ value: T) {
    state.withLock { state in
      guard case .waiting = state else { return }
      state = DispatchTime.now() <= deadline ? .finished(value) : .abandoned
    }
    signal.signal()
  }

  func value() -> T? {
    let ready = signal.wait(timeout: deadline) == .success
    return state.withLock { state in
      defer { state = .abandoned }
      guard ready, case .finished(let value) = state else { return nil }
      return value
    }
  }
}

package enum HostAddresses {
  package static func current() -> Set<String> {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let list else { return [] }
    defer { freeifaddrs(list) }
    var names: Set<String> = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = list
    while let node = cursor {
      if let address = node.pointee.ifa_addr {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(
          address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0,
          NI_NUMERICHOST) == 0
        {
          let host = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
          names.insert(host.lowercased())
        }
      }
      cursor = node.pointee.ifa_next
    }
    return names
  }
}

package enum Resolver {
  /// `nil` on admission refusal, timeout, failure, or an empty answer.
  package static func lookup(
    _ host: String, admission: Admission, port: String = "443",
    deadline: Duration = EgressBudgets.dns
  ) -> ResolvedAddresses? {
    lookup(admission: admission, deadline: deadline) {
      var hints = addrinfo()
      hints.ai_family = AF_UNSPEC
      hints.ai_socktype = SOCK_STREAM
      var resolved: UnsafeMutablePointer<addrinfo>?
      let code = getaddrinfo(host, port, &hints, &resolved)
      return ResolvedAddresses.adopting(resolved, status: code)
    }
  }

  static func lookup(
    admission: Admission, deadline: Duration,
    resolve: @escaping @Sendable () -> ResolvedAddresses?
  ) -> ResolvedAddresses? {
    guard admission.tryDNS() else { return nil }
    // libc resolution cannot be cancelled. Its slot outlives the caller's wait.
    return Deadline.wait(deadline) {
      defer { admission.endDNS() }
      return resolve()
    } ?? nil
  }
}

/// Owns an immutable libc address list, including results arriving after timeout.
package final class ResolvedAddresses: @unchecked Sendable {
  private let info: UnsafeMutablePointer<addrinfo>
  private let release: @Sendable (UnsafeMutablePointer<addrinfo>) -> Void

  private init(
    _ info: UnsafeMutablePointer<addrinfo>,
    release: @escaping @Sendable (UnsafeMutablePointer<addrinfo>) -> Void
  ) {
    self.info = info
    self.release = release
  }

  static func adopting(
    _ info: UnsafeMutablePointer<addrinfo>?, status: Int32,
    release: @escaping @Sendable (UnsafeMutablePointer<addrinfo>) -> Void = { freeaddrinfo($0) }
  ) -> ResolvedAddresses? {
    guard status == 0, let info else {
      if let info { release(info) }
      return nil
    }
    return ResolvedAddresses(info, release: release)
  }

  deinit { release(info) }

  /// The list is borrowed for this callback only; do not free or retain pointers.
  package func withAddressInfo<T>(_ body: (UnsafePointer<addrinfo>) throws -> T) rethrows -> T {
    try withExtendedLifetime(self) { try body(UnsafePointer(info)) }
  }
}

package enum Dial {
  /// Non-blocking connect bounded by `timeout`. Restores the previous flags.
  package static func connect(
    _ fd: Int32, address: UnsafePointer<sockaddr>, length: socklen_t,
    timeout: Duration = EgressBudgets.connect
  ) -> Bool {
    connect(
      fd, address: address, length: length, timeout: timeout,
      start: Darwin.connect, wait: Darwin.poll)
  }

  // Internal syscall seam: release callers always use Darwin connect/poll above.
  static func connect(
    _ fd: Int32, address: UnsafePointer<sockaddr>, length: socklen_t,
    timeout: Duration,
    start: (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32,
    wait: (UnsafeMutablePointer<pollfd>?, nfds_t, Int32) -> Int32
  ) -> Bool {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0 else { return false }
    guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
    let started = start(fd, address, length)
    if started == 0 {
      _ = fcntl(fd, F_SETFL, flags)
      return true
    }
    guard errno == EINPROGRESS else {
      _ = fcntl(fd, F_SETFL, flags)
      return false
    }
    var probe = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let milliseconds = Int32(max(1, min(Monotonic.nanoseconds(timeout) / 1_000_000, 60_000)))
    let ready = wait(&probe, 1, milliseconds)
    var error: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    if ready > 0 {
      _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size)
    } else {
      error = ETIMEDOUT
    }
    _ = fcntl(fd, F_SETFL, flags)
    return error == 0
  }

  package static func peerIsPublic(_ fd: Int32, local: Set<String>) -> Bool {
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let ok = withUnsafeMutablePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
    }
    guard ok == 0 else { return false }
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let named = withUnsafePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getnameinfo($0, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
      }
    }
    guard named == 0 else { return false }
    let host = String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return AddressPolicy.isPublic(host, local: local)
  }
}
