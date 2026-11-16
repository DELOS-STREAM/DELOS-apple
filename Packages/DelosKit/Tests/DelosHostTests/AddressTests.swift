import Testing
@testable import DelosHost

/// The address typed in "Add a PC manually". The table is the contract of DELOS for Android
/// (`PcSetupTest.everyFormOfAddressGivesItsHostAndPort`), plus the inputs this port rejects.
@Suite struct AddressParsingTests {
    // typed, host as stored, port (nil: none typed, the default port is used)
    static let table: [(String, String, Int?)] = [
        ("192.168.1.20", "192.168.1.20", nil),
        ("192.168.1.20:48989", "192.168.1.20", 48989),
        ("desk.local", "desk.local", nil),
        ("desk", "desk", nil),
        ("pc.example.org:47989", "pc.example.org", 47989),
        ("[2001:db8::1]", "2001:db8::1", nil),
        ("[2001:db8::1]:48989", "2001:db8::1", 48989),
        ("[::1]", "::1", nil),
        ("[::1]:47989", "::1", 47989),
        // Regression on Android: without brackets the last group was read as the port (2001:db8::1 gave port 1).
        ("2001:db8::1", "2001:db8::1", nil),
        ("2001:db8::1:2", "2001:db8::1:2", nil),
        ("2001:db8:0:0:0:0:0:47989", "2001:db8:0:0:0:0:0:47989", nil),
        ("fe80::1234:5678", "fe80::1234:5678", nil),
        ("::1", "::1", nil),
        ("::", "::", nil),
        // White space around the address is ignored.
        ("  desk.local:48989 \n", "desk.local", 48989),
    ]

    @Test(arguments: table)
    func everyFormOfAddressGivesItsHostAndPort(typed: String, host: String, port: Int?) {
        #expect(HostAddress.parse(typed) == HostAddress.Typed(host: host, port: port))
    }

    @Test(arguments: ["", "   ", ":47989", "desk:", "desk:0", "desk:65536", "desk:4x", "desk:-1", "[2001:db8::1", "[desk]",
                      "[2001:db8::1]48989", "2001:db8::zz", "de sk", "desk..local", "desk/x", "http://desk", "dësk"])
    func whatIsNotAnAddress(typed: String) {
        #expect(HostAddress.parse(typed) == nil)
    }

    @Test func withoutAPortTheDefaultIsUsed() {
        #expect(HostAddress.parse("desk")?.address() == HostAddress(host: "desk", port: 47989))
        #expect(HostAddress.parse("[::1]:1")?.address() == HostAddress(host: "::1", port: 1))
    }

    @Test func ipv6IsStoredWithoutBracketsAndPrintedWithThem() {
        let address = HostAddress(host: "[2001:db8::1]", port: 47989)

        #expect(address.host == "2001:db8::1")
        #expect(address.description == "[2001:db8::1]:47989")
        #expect(HostAddress(host: "192.168.1.20", port: 47989).description == "192.168.1.20:47989")
    }
}

/// The host id rule (S-02), cases of `HostIdsTest.java` of DELOS for Android.
@Suite struct HostIDTests {
    @Test(arguments: ["7B0A3A5E-1C2D-4E5F-8A9B-0C1D2E3F4A5B", "0123456789abcdef", "a", String(repeating: "a", count: 64)])
    func acceptsTheIdsHostsSend(id: String) {
        #expect(HostID.isValid(id))
    }

    @Test(arguments: ["", "..", ".", "../x", "a/b", "a\\b", "a\u{0}b", "a b", "a.b", "é", "%2e%2e", String(repeating: "a", count: 65)])
    func rejectsAnythingThatCouldLeaveADirectory(id: String) {
        #expect(!HostID.isValid(id))
    }
}
