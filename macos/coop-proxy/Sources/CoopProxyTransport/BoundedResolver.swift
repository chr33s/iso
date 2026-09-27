import NIOCore
import NIOPosix

/// One system lookup, admitted from a client-wide budget. Cancelling delivery
/// never releases its lease before both underlying DNS results have completed.
final class BoundedResolver: Resolver, Sendable {
  enum Failure: Error { case capacityExceeded, cancelled }
  typealias Factory = @Sendable (EventLoop) -> any Resolver & Sendable
  private let state: NIOLoopBound<State>

  /// Construct on the connection event loop, as with the owning HTTP request.
  init(
    eventLoop: EventLoop, capacity: Capacity,
    factory: @escaping Factory = { NIORandomizedDNSResolver(loop: $0) }
  ) {
    state = NIOLoopBound(
      State(eventLoop: eventLoop, capacity: capacity, factory: factory), eventLoop: eventLoop)
  }

  func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
    state.value.start(host: host, port: port).ipv4.futureResult
  }

  func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
    state.value.start(host: host, port: port).ipv6.futureResult
  }

  func cancelQueries() {
    let state = state
    state.eventLoop.execute { state.value.cancel() }
  }

  private final class State {
    enum Family: CaseIterable { case ipv4, ipv6 }
    struct Results {
      let ipv4: EventLoopPromise<[SocketAddress]>
      let ipv6: EventLoopPromise<[SocketAddress]>
      func promise(_ family: Family) -> EventLoopPromise<[SocketAddress]> {
        family == .ipv4 ? ipv4 : ipv6
      }
    }
    let eventLoop: EventLoop
    let capacity: Capacity
    let factory: Factory
    var results: Results?
    var delivering = Set(Family.allCases)
    var unfinished = Set(Family.allCases)
    var work: (resolver: any Resolver & Sendable, lease: Capacity.Lease)?
    var cancelled = false

    init(eventLoop: EventLoop, capacity: Capacity, factory: @escaping Factory) {
      self.eventLoop = eventLoop
      self.capacity = capacity
      self.factory = factory
    }

    func start(host: String, port: Int) -> Results {
      if let results { return results }
      let results = Results(ipv4: eventLoop.makePromise(), ipv6: eventLoop.makePromise())
      self.results = results
      guard !cancelled else {
        failDelivery(Failure.cancelled)
        return results
      }
      guard let lease = capacity.acquire() else {
        failDelivery(Failure.capacityExceeded)
        return results
      }
      let resolver = factory(eventLoop)
      work = (resolver, lease)
      let bound = NIOLoopBound(self, eventLoop: eventLoop)
      // Start both before observing either: an immediate result must not make
      // the lease appear complete while the other family has not been started.
      let ipv6 = resolver.initiateAAAAQuery(host: host, port: port)
      let ipv4 = resolver.initiateAQuery(host: host, port: port)
      ipv6.hop(to: eventLoop).whenComplete { bound.value.completed(.ipv6, result: $0) }
      ipv4.hop(to: eventLoop).whenComplete { bound.value.completed(.ipv4, result: $0) }
      return results
    }

    func completed(_ family: Family, result: Result<[SocketAddress], Error>) {
      unfinished.remove(family)
      if unfinished.isEmpty { work = nil }
      if delivering.remove(family) != nil { results?.promise(family).completeWith(result) }
    }

    func failDelivery(_ error: Error) {
      let remaining = delivering
      delivering.removeAll()
      for family in remaining { results?.promise(family).fail(error) }
    }

    func cancel() {
      cancelled = true
      // No promises exist when cancellation precedes the first lookup (or the
      // bootstrap used a literal address). A late lookup fails locally.
      if results != nil { failDelivery(Failure.cancelled) }
      work?.resolver.cancelQueries()
    }
  }
}
