import Darwin
import Dispatch
import IsoInferenceCore
import NIOCore
import Synchronization

/// A one-shot exit watch on another process (kqueue `EVFILT_PROC`,
/// `NOTE_EXIT`). It needs no right to read the process's information, which
/// the gateway's profile does not grant (§10). Creation fails when the
/// process no longer exists.
final class ExitWatch: Sendable {
  private let source: DispatchSourceRead

  init?(pid: pid_t, onExit: @escaping @Sendable () -> Void) {
    let queue = kqueue()
    guard queue >= 0 else { return nil }
    // `kevent` carries a raw `udata` pointer, unused (nil) here.
    var change = unsafe kevent(
      ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
      fflags: NOTE_EXIT, data: 0, udata: nil)
    // kevent reads the one change borrowed here and writes no events.
    guard unsafe kevent(queue, &change, 1, nil, 0, nil) == 0 else {
      close(queue)
      return nil
    }
    let source = DispatchSource.makeReadSource(fileDescriptor: queue, queue: .global())
    let fired = Atomic(false)
    source.setEventHandler {
      guard !fired.exchange(true, ordering: .relaxed) else { return }
      source.cancel()
      onExit()
    }
    source.setCancelHandler { close(queue) }
    source.resume()
    self.source = source
  }

  func cancel() { source.cancel() }
}

extension PeerIdentity {
  /// The peer of an accepted Unix-socket channel, from its audit token
  /// (`LOCAL_PEERTOKEN`): `val[1]` is the effective UID, `val[5]` the PID and
  /// `val[7]` the PID version. nil when the channel has no such peer.
  static func of(_ channel: Channel) -> EventLoopFuture<PeerIdentity?> {
    guard let provider = channel as? SocketOptionProvider else {
      return channel.eventLoop.makeSucceededFuture(nil)
    }
    let token: EventLoopFuture<audit_token_t> = provider.unsafeGetSocketOption(
      level: SocketOptionLevel(SOL_LOCAL), name: SocketOptionName(LOCAL_PEERTOKEN))
    return token.map { token -> PeerIdentity? in
      PeerIdentity(
        pid: Int32(bitPattern: token.val.5), version: token.val.7, uid: token.val.1)
    }.recover { _ in nil }
  }
}
