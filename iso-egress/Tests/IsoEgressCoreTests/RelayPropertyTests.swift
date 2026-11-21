// Model-based property tests for the relay queue: `RelayRing` against a
// plain FIFO, and `Tunnel.pump` against the byte streams it must carry.

import Darwin
import Foundation
import Testing

@testable import IsoEgressCore

// MARK: - RelayRing against a FIFO

/// What the lent callback does with its region.
private enum Outcome: CustomStringConvertible {
  /// Moves this many bytes, clamped to the lent region.
  case move(Int)
  /// Moves the whole region.
  case all
  /// Moves nothing: a receive reports EOF, a send makes no progress.
  case none
  /// A socket failure (EAGAIN, EINTR or a hard error), as a negative count.
  case failure(Int)

  var description: String {
    switch self {
    case .move(let count): "move(\(count))"
    case .all: "all"
    case .none: "none"
    case .failure(let code): "failure(\(code))"
    }
  }
}

private enum RingStep: CustomStringConvertible {
  /// `receive(upTo:)` with `limit`, or, in a capped case, with the room the
  /// case's `queueCap` leaves, as `Tunnel.take` asks.
  case receive(limit: Int, Outcome)
  case send(Outcome)

  var description: String {
    switch self {
    case .receive(let limit, let outcome): "receive(\(limit), \(outcome))"
    case .send(let outcome): "send(\(outcome))"
    }
  }
}

private struct RingCase: CustomStringConvertible {
  /// Receives ask for the room left under `queueCap` instead of their own
  /// limit, so the ring must never hold more.
  let capped: Bool
  let queueCap: Int
  let steps: [RingStep]
  let seed: UInt64
  var description: String {
    (capped ? "capped " : "uncapped ") + "\(queueCap): "
      + steps.map(\.description).joined(separator: " ")
  }
}

private func outcome(_ rng: inout PropertyRNG, pivot: Int) -> Outcome {
  switch rng.below(8) {
  case 0: .none
  case 1: .failure(rng.element([-1, Int(-EAGAIN), Int.min]))
  case 2, 3: .all
  default: .move(rng.size(upTo: 2 * pivot + 2, pivot: pivot))
  }
}

private func ringCase(_ rng: inout PropertyRNG) -> RingCase {
  // Small caps force wrap-around every few steps; the 4096-byte minimum
  // allocation and its doublings are the growth boundaries.
  let queueCap = rng.element([1, 7, 4095, 4096, 4097, 9000])
  let pivot = rng.element([1, 7, 4096, queueCap])
  // A queue that grows then drains slowly wraps more often.
  let receiveWeight = rng.int(1...4)
  let steps = (0..<rng.int(1...120)).map { _ -> RingStep in
    if rng.below(receiveWeight + 2) < receiveWeight {
      let limit =
        rng.oneIn(10) ? rng.element([0, -1, Int.min]) : rng.size(upTo: 3 * pivot, pivot: pivot)
      return .receive(limit: limit, outcome(&rng, pivot: pivot))
    }
    return .send(outcome(&rng, pivot: pivot))
  }
  return RingCase(capped: rng.oneIn(2), queueCap: queueCap, steps: steps, seed: rng.next())
}

private func moved(_ outcome: Outcome, region: Int) -> Int {
  switch outcome {
  case .move(let count): min(count, region)
  case .all: region
  case .none: 0
  case .failure(let code): code
  }
}

/// Whether `region` holds exactly the model's oldest pending bytes.
private func holdsOldest(_ region: UnsafeRawBufferPointer, _ model: [UInt8], from head: Int) -> Bool
{
  guard region.count <= model.count - head else { return false }
  return model[head..<(head + region.count)].withUnsafeBytes {
    memcmp($0.baseAddress, region.baseAddress, region.count) == 0
  }
}

/// Fresh bytes, eight per draw, so a duplicated or skipped byte shows.
private func fresh(_ rng: inout PropertyRNG, count: Int) -> [UInt8] {
  var out: [UInt8] = []
  out.reserveCapacity(count + 8)
  while out.count < count { withUnsafeBytes(of: rng.next()) { out += $0 } }
  return Array(out.prefix(count))
}

/// Replays `input` on a `RelayRing` and on a FIFO model (every accepted
/// byte, and how many have left). After every step the count and emptiness
/// agree, every lent send region is exactly the model's oldest bytes, and
/// every lent receive region is free space no larger than the limit; at the
/// end the ring drains to exactly the accepted bytes, in order, once each.
private func ringAgreesWithModel(_ input: RingCase) -> String? {
  var ring = RelayRing()
  var model: [UInt8] = []
  var head = 0
  var bytes = PropertyRNG(seed: input.seed)
  for (index, step) in input.steps.enumerated() {
    var called = false
    var problem: String?
    switch step {
    case .receive(let asked, let outcome):
      let limit =
        input.capped
        ? RelayRoom(
          pending: model.count - head, perDirection: input.queueCap, aggregateAvailable: .max
        ).allowed : asked
      var wrote: [UInt8] = []
      var reported = 0
      let result = ring.receive(upTo: limit) { region in
        called = true
        if region.isEmpty || region.count > limit {
          problem = "lent \(region.count) free bytes for limit \(limit)"
        }
        reported = moved(outcome, region: region.count)
        if reported > 0 {
          wrote = fresh(&bytes, count: reported)
          region.copyBytes(from: wrote)
        }
        return reported
      }
      if limit <= 0, called { return "step \(index): receive lent a region for limit \(limit)" }
      if let problem { return "step \(index): \(problem)" }
      if result != reported {
        return "step \(index): receive returned \(result), fill reported \(reported)"
      }
      model += wrote
      if input.capped, model.count - head > input.queueCap {
        return "step \(index): \(model.count - head) bytes held over cap \(input.queueCap)"
      }
    case .send(let outcome):
      var took = 0
      let result = ring.send { region in
        called = true
        if region.isEmpty || !holdsOldest(region, model, from: head) {
          problem = "lent \(region.count) bytes that are not the oldest \(model.count - head)"
        }
        took = moved(outcome, region: region.count)
        return took
      }
      if let problem { return "step \(index): \(problem)" }
      if called == (model.count == head) {
        return
          "step \(index): send lent \(called ? "a region" : "nothing") for \(model.count - head) bytes"
      }
      if result != took { return "step \(index): send returned \(result), drain reported \(took)" }
      if result > 0 { head += result }
    }
    if ring.count != model.count - head || ring.isEmpty != (model.count == head) {
      return "step \(index): ring holds \(ring.count), model \(model.count - head)"
    }
  }
  // Drain whatever is left; a ring with bytes must always lend some.
  while !ring.isEmpty {
    var oldest = true
    let sent = ring.send { region in
      oldest = holdsOldest(region, model, from: head)
      return region.count
    }
    if sent <= 0 || !oldest { return "draining a ring of \(ring.count) bytes lent \(sent)" }
    head += sent
  }
  return head == model.count ? nil : "drained \(head) of \(model.count) accepted bytes"
}

@Test func relayRingAgreesWithAFIFOModel() {
  expectHolds(
    checkProperty(
      "RelayRing matches a FIFO over receive/send sequences", iterations: 200,
      generate: ringCase, property: ringAgreesWithModel))
}

// MARK: - Tunnel.pump against its byte streams

/// One scripted `recv` result for a direction's source socket.
private enum ReadEvent: CustomStringConvertible {
  case data([UInt8])
  case again, interrupted

  var description: String {
    switch self {
    case .data(let bytes): "data(\(bytes.count))"
    case .again: "EAGAIN"
    case .interrupted: "EINTR"
    }
  }
}

private struct PumpCase: CustomStringConvertible {
  let queueCap: Int
  let budgetCap: Int
  /// Out of ten, how often a sink refuses a write, so queues stay full and
  /// wrap around.
  let stall: Int
  /// Per source direction; each ends in EOF after its events.
  let reads: [[ReadEvent]]
  let seed: UInt64
  var description: String {
    "cap \(queueCap) budget \(budgetCap) stall \(stall) left \(reads[0]) right \(reads[1])"
  }
}

private func pumpCase(_ rng: inout PropertyRNG) -> PumpCase {
  // 4096 is the ring's first allocation: a full queue of it wraps in place.
  let queueCap = rng.element([1, 2, 3, 16, 255, 1024, 4096])
  let budgetCap = rng.element([1, 2, queueCap, 2 * queueCap, 1 << 20])
  // A one- or two-byte budget moves a byte or two per loop; keep it short.
  let chunk = budgetCap <= 2 ? min(queueCap, 64) : queueCap
  let reads = (0..<2).map { _ in
    (0..<rng.int(0...8)).map { _ -> ReadEvent in
      switch rng.below(6) {
      case 0: .again
      case 1: .interrupted
      default: .data(rng.bytes(count: rng.size(upTo: 2 * chunk + 1, pivot: chunk)))
      }
    }
  }
  return PumpCase(
    queueCap: queueCap, budgetCap: budgetCap, stall: rng.element([0, 2, 5, 8]), reads: reads,
    seed: rng.next())
}

private func socketPair() -> [Int32]? {
  var pair: [Int32] = [-1, -1]
  return socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 ? pair : nil
}

/// Drives `Tunnel.pump` with scripted short reads, EAGAIN/EINTR and EOF on
/// each source and random short writes and EAGAIN/EINTR on each sink. Each
/// sink receives exactly its source's bytes in order, no read asks for more
/// than the direction's remaining queue room, both half-closes are forwarded,
/// and every budget reservation is released.
private func pumpCarriesBothStreams(_ input: PumpCase) -> String? {
  guard let leftPair = socketPair(), let rightPair = socketPair() else {
    return "socketpair failed"
  }
  defer { for fd in leftPair + rightPair { close(fd) } }
  let sockets = [leftPair[1], rightPair[1]]
  let peers = [leftPair[0], rightPair[0]]
  let sources = input.reads.map { events in
    events.flatMap { event -> [UInt8] in
      if case .data(let bytes) = event { return bytes }
      return []
    }
  }
  var events = input.reads.map { $0[...] }
  var chunk: [ArraySlice<UInt8>] = [[], []]
  var readTotal = [0, 0]
  var written = [0, 0]
  var eof = [false, false]
  var rng = PropertyRNG(seed: input.seed)
  var problem: String?
  let budget = RelayBudget(cap: input.budgetCap)
  var probes = 0
  // Generous: each loop without progress is one of a bounded number of
  // scripted or random refusals.
  let probeLimit = 50 * (sources.joined().count + input.reads.joined().count + 10)
  Tunnel.pump(
    sockets[0], sockets[1],
    alive: {
      probes += 1
      return probes <= probeLimit && problem == nil
    },
    maxReads: nil, idle: .seconds(60), queueCap: input.queueCap, budget: budget,
    read: { fd, pointer, count in
      let index = sockets.firstIndex(of: fd)!
      if eof[index] { problem = "direction \(index) read again after EOF" }
      let room = input.queueCap - (readTotal[index] - written[index])
      if count <= 0 || count > room || count > Tunnel.readChunk {
        problem = "direction \(index) read \(count) with \(room) bytes of room"
      }
      while chunk[index].isEmpty {
        guard let event = events[index].popFirst() else {
          eof[index] = true
          return 0
        }
        switch event {
        case .again:
          errno = EAGAIN
          return -1
        case .interrupted:
          errno = EINTR
          return -1
        case .data(let bytes): chunk[index] = bytes[...]
        }
      }
      let take = min(count, chunk[index].count, rng.oneIn(2) ? count : rng.int(1...count))
      chunk[index].withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: take) }
      chunk[index] = chunk[index].dropFirst(take)
      readTotal[index] += take
      return take
    },
    write: { fd, pointer, count in
      // A sink socket carries the other socket's direction.
      let sink = sockets.firstIndex(of: fd)!
      let index = 1 - sink
      let pending = readTotal[index] - written[index]
      if count <= 0 || count > pending {
        problem = "direction \(index) wrote \(count) with \(pending) pending"
      }
      // Nothing is really sent, so a peer that reads EOF saw a half-close.
      var byte: UInt8 = 0
      if recv(peers[sink], &byte, 1, MSG_DONTWAIT | MSG_PEEK) == 0 {
        problem = "direction \(index) wrote after its sink was half-closed"
      }
      switch rng.below(10) < input.stall {
      case true:
        errno = rng.oneIn(2) ? EAGAIN : EINTR
        return -1
      case false:
        let take = rng.oneIn(2) ? count : rng.int(1...max(1, count))
        let bytes = Array(UnsafeRawBufferPointer(start: pointer, count: take))
        let expected = sources[index][
          written[index]..<min(written[index] + take, sources[index].count)]
        if !bytes.elementsEqual(expected) {
          problem = "direction \(index) wrote bytes out of order at offset \(written[index])"
        }
        written[index] += take
        return take
      }
    },
    pollEvents: { fds, _ in
      for index in fds.indices { fds[index].revents = fds[index].fd < 0 ? 0 : fds[index].events }
      return Int32(fds.filter { $0.revents != 0 }.count)
    })
  if let problem { return problem }
  if probes > probeLimit { return "the relay made no progress for \(probeLimit) loops" }
  for index in 0..<2 where written[index] != sources[index].count {
    return "direction \(index) delivered \(written[index]) of \(sources[index].count) bytes"
  }
  if !eof.allSatisfy({ $0 }) { return "a source was not read through EOF" }
  // Each direction's EOF reaches the peer behind the other socket.
  for (index, peer) in peers.enumerated() {
    var byte: UInt8 = 0
    let got = recv(peer, &byte, 1, MSG_DONTWAIT)
    if got != 0 { return "socket \(index) was not half-closed after its queue drained (\(got))" }
  }
  if budget.available != budget.cap {
    return "budget holds \(budget.cap - budget.available) bytes after the relay ended"
  }
  return nil
}

@Test func relayPumpDeliversBothStreamsThroughShortIOAndBackpressure() {
  expectHolds(
    checkProperty(
      "Tunnel.pump carries both directions exactly", iterations: 200,
      generate: pumpCase, property: pumpCarriesBothStreams))
}
