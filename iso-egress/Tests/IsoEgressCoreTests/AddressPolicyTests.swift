import Testing

@testable import IsoEgressCore

@Test func addressPolicyRejectsSpecialPurposeAndTransitionForms() {
  #expect(AddressPolicy.revision == "iana-2025-10-09-v1")
  for address in [
    "::", "::1", "0:0:0:0:0:0:0:1", "::ffff:8.8.8.8", "::ffff:808:808",
    "64:ff9b::808:808", "0064:ff9b:1::1", "100::1", "100:0:0:1::1",
    "2001::1", "2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff", "2001:2::1",
    "2001:10::1", "2001:20::1", "2001:30::1", "2001:db8::1",
    "2001:0db8:ffff:ffff:ffff:ffff:ffff:ffff", "2002::1",
    "2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "3fff::1", "3fff:fff::1",
    "5f00::1", "fc00::1", "fdff::1", "fe80::1", "febf::1", "ff02::1",
    "0.1.2.3", "10.0.0.1", "100.64.0.1", "100.127.255.255", "127.0.0.1",
    "169.254.1.1", "172.16.0.1", "172.31.255.255", "192.0.0.1", "192.0.2.1",
    "192.88.99.1", "192.168.1.1", "198.18.0.1", "198.19.255.255",
    "198.51.100.1", "203.0.113.1", "224.0.0.1", "240.0.0.1", "255.255.255.255",
    "not:an:address", "2001:4860:::1", "2001:4860::1%en0", "2001:4860::1\0suffix",
  ] {
    #expect(!AddressPolicy.isPublic(address), "accepted forbidden address: \(address)")
  }
}

@Test func addressPolicyAllowsPublicBoundariesAndRejectsEquivalentHostAddresses() {
  for address in [
    "1.1.1.1", "8.8.8.8", "100.63.255.255", "100.128.0.0", "172.15.255.255",
    "172.32.0.0", "192.88.98.255", "192.88.100.0", "198.17.255.255", "198.20.0.0",
    "2001:200::1", "2001:db7::1", "2001:db9::1", "2003::1", "3fff:1000::1",
    "2606:4700:4700::1111", "2001:4860:4860::8888",
  ] {
    #expect(AddressPolicy.isPublic(address), "rejected public boundary: \(address)")
  }
  #expect(!AddressPolicy.isPublic("2001:4860::1", local: ["2001:4860:0:0:0:0:0:1"]))
  #expect(!AddressPolicy.isPublic("2001:4860:0:0:0:0:0:1", local: ["2001:4860::1"]))
  #expect(!AddressPolicy.isPublic("8.8.8.8", local: ["8.8.8.8"]))
}
