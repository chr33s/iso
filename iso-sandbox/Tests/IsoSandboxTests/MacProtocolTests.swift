import Foundation
import IsoMacProtocol
import Testing

private let hostKey = "ssh-ed25519 " + Data(repeating: 7, count: 51).base64EncodedString()
private let nonce = String(repeating: "a", count: 32)

private func line(_ json: String) -> [UInt8] { Array(json.utf8) }

private func hello(boot: String = "B1", enrolled: Bool, mac: String? = nil) -> HelperMessage {
  var m = HelperMessage(type: .hello)
  m.boot = boot
  m.enrolled = enrolled
  m.mac = mac
  return m
}

@Test func helperKeysAre64LowercaseHexOnly() {
  #expect(HelperKey(hex: String(repeating: "0f", count: 32)) != nil)
  #expect(HelperKey(hex: String(repeating: "0F", count: 32)) == nil)
  #expect(HelperKey(hex: String(repeating: "0f", count: 31)) == nil)
  #expect(HelperKey(hex: String(repeating: "zz", count: 32)) == nil)
  #expect(HelperKey.random() != HelperKey.random())
}

@Test func macMatchesOnlyTheSameKeyNonceAndBoot() {
  let k = HelperKey.random()
  let m = HelperProtocol.mac(key: k, nonce: nonce, boot: "B1")
  #expect(HelperProtocol.macMatches(m, HelperProtocol.mac(key: k, nonce: nonce, boot: "B1")))
  #expect(!HelperProtocol.macMatches(m, HelperProtocol.mac(key: k, nonce: nonce, boot: "B2")))
  #expect(
    !HelperProtocol.macMatches(
      m, HelperProtocol.mac(key: HelperKey.random(), nonce: nonce, boot: "B1")))
  #expect(!HelperProtocol.macMatches(m, String(m.dropLast())))
}

@Test func parseRefusesOversizedOtherVersionsAndOutOfBoundsValues() {
  #expect(
    HelperMessage.parse(line(#"{"v":1,"type":"hello","boot":"x","enrolled":false}"#)).isSuccess)
  #expect(HelperMessage.parse(line(#"{"v":2,"type":"hello"}"#)) == .failure(.version(2)))
  #expect(HelperMessage.parse(line(#"{"v":1,"type":"exec"}"#)) == .failure(.malformed))
  #expect(HelperMessage.parse(line("not json")) == .failure(.malformed))
  let big = #"{"v":1,"type":"hello","boot":""# + String(repeating: "x", count: 70_000) + #""}"#
  #expect(HelperMessage.parse(line(big)) == .failure(.tooLong))
  let longBoot = #"{"v":1,"type":"hello","boot":""# + String(repeating: "x", count: 65) + #""}"#
  #expect(HelperMessage.parse(line(longBoot)) == .failure(.malformed))
  #expect(
    HelperMessage.parse(line(#"{"v":1,"type":"enrolled","ssh_host_key":"ssh-rsa AAAA"}"#))
      == .failure(.malformed))
  #expect(HelperMessage.parse(line(#"{"v":1,"type":"enroll","key":"00"}"#)) == .failure(.malformed))
  let badNet =
    #"{"v":1,"type":"network","network":{"address":"10.0.0.2; rm -rf /","prefix":24,"gateway":"10.0.0.1","dns":[]}}"#
  #expect(HelperMessage.parse(line(badNet)) == .failure(.malformed))
  // Request numbers: absent (older helpers) or 0...Int32.max.
  #expect(HelperMessage.parse(line(#"{"v":1,"type":"ack"}"#)).isSuccess)
  #expect(HelperMessage.parse(line(#"{"v":1,"type":"ack","id":2147483647}"#)).isSuccess)
  #expect(HelperMessage.parse(line(#"{"v":1,"type":"ack","id":-1}"#)) == .failure(.malformed))
  #expect(
    HelperMessage.parse(line(#"{"v":1,"type":"ack","id":2147483648}"#)) == .failure(.malformed))
}

@Test func networkConfigurationIsDottedQuadsAndASanePrefix() {
  let ok = HelperNetwork(
    address: "10.231.4.2", prefix: 24, gateway: "10.231.4.1", dns: ["10.231.4.1"])
  #expect(ok.isWellFormed)
  #expect(ok.netmask == "255.255.255.0")
  #expect(
    !HelperNetwork(address: "10.231.4.256", prefix: 24, gateway: "10.231.4.1", dns: []).isWellFormed
  )
  #expect(
    !HelperNetwork(address: "10.231.4.2", prefix: 0, gateway: "10.231.4.1", dns: []).isWellFormed)
  #expect(!HelperNetwork(address: "-o", prefix: 24, gateway: "10.231.4.1", dns: []).isWellFormed)
  #expect(
    !HelperNetwork(
      address: "10.231.4.2", prefix: 24, gateway: "10.231.4.1",
      dns: Array(repeating: "1.1.1.1", count: 5)
    ).isWellFormed)
}

@Test func sshPublicKeysMustBeOneEd25519Line() {
  #expect(SSHPublicKey.isEd25519(hostKey))
  #expect(SSHPublicKey.isEd25519(hostKey + " comment"))
  #expect(!SSHPublicKey.isEd25519(hostKey + "\nssh-ed25519 AAAA"))
  // A newline in the comment is caught only by the one-line check.
  #expect(!SSHPublicKey.isEd25519(hostKey + " a\nb"))
  #expect(
    !SSHPublicKey.isEd25519("ssh-ed25519 " + Data(repeating: 1, count: 10).base64EncodedString()))
  #expect(SSHPublicKey.canonical(hostKey + " c") == hostKey)
}

@Test func handshakeEnrollsOnlyAFreshCloneOnBothSides() {
  #expect(
    Handshake.decide(hostEnrolled: false, hostKey: nil, hello: hello(enrolled: false), nonce: nonce)
      == .enroll)
}

@Test func handshakeAuthenticatesOnlyAValidMAC() {
  let k = HelperKey.random()
  let good = HelperProtocol.mac(key: k, nonce: nonce, boot: "B1")
  #expect(
    Handshake.decide(
      hostEnrolled: true, hostKey: k, hello: hello(enrolled: true, mac: good), nonce: nonce)
      == .authenticated)
  // A replayed MAC from another boot or nonce, a forged key, or none at all.
  #expect(
    Handshake.decide(
      hostEnrolled: true, hostKey: k, hello: hello(boot: "B2", enrolled: true, mac: good),
      nonce: nonce) == .reject("bad mac"))
  #expect(
    Handshake.decide(
      hostEnrolled: true, hostKey: k, hello: hello(enrolled: true, mac: good),
      nonce: String(repeating: "b", count: 32)) == .reject("bad mac"))
  let forged = HelperProtocol.mac(key: HelperKey.random(), nonce: nonce, boot: "B1")
  #expect(
    Handshake.decide(
      hostEnrolled: true, hostKey: k, hello: hello(enrolled: true, mac: forged), nonce: nonce)
      == .reject("bad mac"))
  #expect(
    Handshake.decide(hostEnrolled: true, hostKey: k, hello: hello(enrolled: true), nonce: nonce)
      == .reject("missing mac"))
}

@Test func anEnrollmentClaimThatDisagreesOnlyRejectsTheConnection() {
  // Any guest process can make these claims, so neither may change host state.
  let k = HelperKey.random()
  #expect(
    Handshake.decide(hostEnrolled: true, hostKey: k, hello: hello(enrolled: false), nonce: nonce)
      == .reject("unauthenticated: guest reports no enrollment for an enrolled sandbox"))
}

@Test func aGuestKeyLeftByAnInterruptedEnrollmentIsReplaced() {
  // The guest saved its key, but the host never recorded the enrollment
  // (interrupted or failed save): the pending host enrolls it again.
  #expect(
    Handshake.decide(
      hostEnrolled: false, hostKey: nil, hello: hello(enrolled: true, mac: "00"), nonce: nonce)
      == .enroll)
}

@Test func enrolledReplyMustProveTheNewKeyAndCarryAHostKey() {
  let k = HelperKey.random()
  var r = HelperMessage(type: .enrolled)
  r.sshHostKey = hostKey + " root@guest"
  r.mac = HelperProtocol.mac(key: k, nonce: nonce, boot: "B1")
  #expect(Handshake.verifyEnrolled(r, key: k, nonce: nonce, boot: "B1") == .success(hostKey))
  #expect(
    Handshake.verifyEnrolled(r, key: HelperKey.random(), nonce: nonce, boot: "B1")
      == .failure(.badMAC))
  r.sshHostKey = nil
  #expect(Handshake.verifyEnrolled(r, key: k, nonce: nonce, boot: "B1") == .failure(.malformed))
}

@Test func encodedLinesRoundTripAndEndInANewline() {
  var m = HelperMessage(type: .challenge)
  m.nonce = nonce
  let data = m.encodedLine()
  #expect(data.last == 0x0A)
  #expect(HelperMessage.parse(data.dropLast()) == .success(m))
}

extension Result {
  fileprivate var isSuccess: Bool { if case .success = self { true } else { false } }
}
