#!/usr/bin/env python3
"""Check filtered-egress CONNECT, readiness, DNS/ownership and relay tripwires.

Runs only local numeric-resolution, stalled-worker and socket fixtures. No public DNS,
provider traffic, VM, or production policy bypass. Compile failures do not count.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FAULTS = [
    ('admission-state-update', 'state = next', '_ = next',
     'concurrentAdmissionEnforcesAndRefillsEachLimit'),
    ('relay-budget-reservation', 'used += take', '_ = take',
     'concurrentRelayReservationsNeverExceedTheAggregateBudget'),
    ('connect-complete-head', 'text.hasSuffix("\\r\\n\\r\\n")', 'true',
     'connectRejectsIncompleteAndAmbiguousFramingBeforeChoosingATarget'),
    ('connect-head-size', 'bytes.count <= EgressBudgets.maxHeadBytes,', 'true,',
     'connectHeadBoundsFramingBytesAndHeaderCount'),
    ('connect-empty-name', '!name.isEmpty, name.utf8.allSatisfy(isToken),',
     'name.utf8.allSatisfy(isToken),',
     'connectRejectsIncompleteAndAmbiguousFramingBeforeChoosingATarget'),
    ('connect-header-names', 'name.utf8.allSatisfy(isToken),', 'true,',
     'connectRejectsIncompleteAndAmbiguousFramingBeforeChoosingATarget'),
    ('connect-header-values', 'value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) })', 'true',
     'connectRejectsIncompleteAndAmbiguousFramingBeforeChoosingATarget'),
    ('connect-host-authority', '!seenHost, hostMatches(String(value), target: host)', '!seenHost',
     'connectRejectsIncompleteAndAmbiguousFramingBeforeChoosingATarget'),
    ('connect-host-duplicate', '!seenHost, hostMatches(String(value), target: host)',
     'hostMatches(String(value), target: host)',
     'connectRejectsIncompleteAndAmbiguousFramingBeforeChoosingATarget'),
    ('connect-framing-fields', 'case "transfer-encoding", "content-length": throw DenialError(.unsupported)',
     'case "transfer-encoding", "content-length": break',
     'connectRejectsIncompleteAndAmbiguousFramingBeforeChoosingATarget'),
    ('connect-poll-interruption', 'if errno == EINTR { continue }', 'if errno == EINTR { return [] }',
     'connectHeadRetriesWaitsAndInterruptionsWithoutConsumingTunnelBytes'),
    ('connect-poll-timeout', 'if polled == 0 { continue }', 'if polled == 0 { return [] }',
     'connectHeadRetriesWaitsAndInterruptionsWithoutConsumingTunnelBytes'),
    ('connect-opaque-payload', 'recv(client, &buffer, take, MSG_DONTWAIT)',
     'recv(client, &buffer, peeked, MSG_DONTWAIT)',
     'connectHeadRetriesWaitsAndInterruptionsWithoutConsumingTunnelBytes'),
    ('connect-read-lease', 'while head.count < EgressBudgets.maxHeadBytes && alive()',
     'while head.count < EgressBudgets.maxHeadBytes',
     'connectHeadNeverReturnsAnIncompleteOrRevokedRequest'),
    ('connect-final-deadline', 'Monotonic.within(start, now: Monotonic.now(), limit: limit), alive()',
     'true, alive()', 'connectHeadRefusesCompletionAfterItsDeadlineOrLease'),
    ('connect-final-lease', 'Monotonic.within(start, now: Monotonic.now(), limit: limit), alive()',
     'Monotonic.within(start, now: Monotonic.now(), limit: limit), true',
     'connectHeadRefusesCompletionAfterItsDeadlineOrLease'),
    ('connect-response-write', 'EgressReadiness.write(responseBytes(denial), to: client, alive: alive)',
     'true', 'connectResponsesAreCompleteSignalSafeAndLeaseBound'),
    ('connect-response-lease', 'EgressReadiness.write(responseBytes(denial), to: client, alive: alive)',
     'EgressReadiness.write(responseBytes(denial), to: client, alive: { true })',
     'connectResponsesAreCompleteSignalSafeAndLeaseBound'),
    ('tunnel-open-handshake', 'guard ConnectGate.writeResponse(client, nil, alive: alive) else { return }',
     '_ = ConnectGate.writeResponse(client, nil, alive: alive)',
     'tunnelRequiresACompleteHandshakeBeforeRelayingAndClosesItsUpstream'),
    ('tunnel-open-lease', 'guard alive() else { return }', '// fault: connect after revocation',
     'tunnelDoesNotConnectOrRespondAfterRevocation'),
    ('readiness-auth', 'ConnectParser.constantTimeEqual(password, capability)', 'true',
     'readinessRefusesUnauthorizedRevokedAndAmbiguousChallenges'),
    ('readiness-lease', 'Self.challenge(head, capability: capability), alive()',
     'Self.challenge(head, capability: capability), true',
     'readinessRefusesUnauthorizedRevokedAndAmbiguousChallenges'),
    ('readiness-nonce', 'return hex(nonce, count: 16) != nil ? nonce : nil', 'return nonce',
     'readinessRefusesUnauthorizedRevokedAndAmbiguousChallenges'),
    ('readiness-framing',
     'guard lines.count == 5, lines[0] == requestLine, lines[3].isEmpty, lines[4].isEmpty,',
     'guard lines.count >= 3, lines[0] == requestLine,',
     'readinessRefusesUnauthorizedRevokedAndAmbiguousChallenges'),
    ('readiness-policy', 'allow.hosts.sorted().joined(separator: ",")', '""',
     'readinessSignsTheComputedPolicyAndIndependentWireVector'),
    ('readiness-no-sigpipe', 'var noSignal: Int32 = 1', 'var noSignal: Int32 = 0',
     'readinessWritesWithoutSigpipeAndRestoresFlags'),
    ('dns-slot-follows-worker',
     'return Deadline.wait(deadline) {\n      defer { admission.endDNS() }',
     'defer { admission.endDNS() }\n    return Deadline.wait(deadline) {',
     'resolverTimeoutKeepsActualWorkAdmittedAndFreesLateResults'),
    ('dns-owned-list-cleanup', 'deinit { release(info) }', 'deinit {}',
     'resolverTimeoutKeepsActualWorkAdmittedAndFreesLateResults'),
    ('dns-success-list-cleanup', 'deinit { release(info) }', 'deinit {}',
     'resolverSuccessOwnsItsListAndReleasesTheWorkSlot'),
    ('dns-failure-list-cleanup', 'if let info { release(info) }', 'if let info { _ = info }',
     'resolverFailureReleasesItsSlotAndAnyReturnedList'),
    ('dns-late-result',
     'state = DispatchTime.now() <= deadline ? .finished(value) : .abandoned',
     'state = .finished(value)',
     'deadlineRejectsAResultFinishedAfterItsMonotonicDeadline'),
    ('relay-hard-write-stops', 'case .end, .failed: return', 'case .end, .failed: break',
     'relayHardWriteErrorTerminatesInsteadOfDroppingAndContinuing'),
    ('relay-eof-drains', 'case .end: directions[index].phase = .draining', 'case .end: return',
     'relayEOFDrainsQueuedBytesThroughBackpressureAndPartialWrites'),
    ('relay-half-close-after-drain',
     'where directions[index].phase == .draining && directions[index].queue.isEmpty',
     'where directions[index].phase == .draining',
     'relayEOFDrainsQueuedBytesThroughBackpressureAndPartialWrites'),
    ('relay-both-directions-finish', 'directions.allSatisfy({ $0.phase == .finished })',
     'directions.contains(where: { $0.phase == .finished })',
     'relayHalfCloseDrainsAndStillAllowsTheOppositeResponse'),
    ('relay-write-interruption',
     'if error == EAGAIN || error == EWOULDBLOCK || error == EINTR { return .blocked }\n'
     '      return .failed\n    }\n    guard count > 0',
     'if error == EAGAIN || error == EWOULDBLOCK { return .blocked }\n'
     '      return .failed\n    }\n    guard count > 0',
     'relayEOFDrainsQueuedBytesThroughBackpressureAndPartialWrites'),
    ('relay-read-interruption',
     'budget.release(reserved)\n'
     '      if error == EAGAIN || error == EWOULDBLOCK || error == EINTR { return .blocked }',
     'budget.release(reserved)\n'
     '      if error == EAGAIN || error == EWOULDBLOCK { return .blocked }',
     'relayInterruptedReadPreservesTheDirectionAndItsReservation'),
    ('relay-budget-on-exit', 'defer { budget.release(held) }', 'defer {}',
     'relayHardWriteErrorTerminatesInsteadOfDroppingAndContinuing'),
    ('relay-no-sigpipe', 'var noSignal: Int32 = 1', 'var noSignal: Int32 = 0',
     'relayHalfCloseDrainsAndStillAllowsTheOppositeResponse'),
    ('relay-paused-hangup',
     'for index in 0..<2 where fds[index].events == 0 { fds[index].fd = -1 }',
     'for index in 0..<2 where fds[index].events == 0 { _ = index }',
     'relayPausedHangupWaitsInsteadOfSpinning'),
]


def run_tests(package, test_filter):
    return subprocess.run(['swift', 'test', '--package-path', str(package),
                           '--force-resolved-versions', '--filter', test_filter],
                          capture_output=True, text=True, timeout=180)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--only', choices=[fault[0] for fault in FAULTS])
    parser.add_argument('--verbose', action='store_true')
    args = parser.parse_args()
    faults = [fault for fault in FAULTS if not args.only or fault[0] == args.only]
    with tempfile.TemporaryDirectory(prefix='iso-egress-fault-') as directory:
        package = Path(directory) / 'iso-egress'
        shutil.copytree(ROOT / 'iso-egress', package,
                        ignore=shutil.ignore_patterns('.build', '.swiftpm'))
        filters = '|'.join(sorted({fault[3] for fault in faults}))
        control = run_tests(package, filters)
        if control.returncode != 0 or any(f'✔ Test {fault[3]}' not in control.stdout
                                          for fault in faults):
            print(control.stdout[-6000:], control.stderr[-6000:], file=sys.stderr)
            print('FAIL: unmodified control did not run and pass every target test', file=sys.stderr)
            return 2
        failures = []
        for ident, original, replacement, test_filter in faults:
            filename = ('Admission.swift' if ident == 'admission-state-update' else
                        'RelayQueue.swift' if ident == 'relay-budget-reservation' else
                        'Readiness.swift' if ident.startswith('readiness-') else
                        'Policy.swift' if ident.startswith('connect-') else
                        'Tunnel.swift' if ident.startswith(('relay-', 'tunnel-open-')) else 'Dial.swift')
            path = package / 'Sources/IsoEgressCore' / filename
            source = path.read_text()
            if source.count(original) != 1:
                failures.append(ident)
                print(f'FAIL {ident}: anchor must match exactly once', flush=True)
                continue
            path.write_text(source.replace(original, replacement, 1))
            try:
                result = run_tests(package, test_filter)
            finally:
                path.write_text(source)
            if args.verbose:
                print(result.stdout[-6000:], result.stderr[-2000:], flush=True)
            if result.returncode != 0 and f'✘ Test {test_filter}' in result.stdout:
                print(f'PASS {ident}: test detected fault', flush=True)
            else:
                failures.append(ident)
                print(result.stdout[-6000:], result.stderr[-2000:], file=sys.stderr)
                print(f'FAIL {ident}: survived or did not compile/run its test', flush=True)
        return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
