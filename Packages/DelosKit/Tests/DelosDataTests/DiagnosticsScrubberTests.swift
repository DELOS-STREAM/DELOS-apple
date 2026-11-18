import Foundation
import Testing
@testable import DelosData

/// The rules of docs/DIAGNOSTICS.md, with lines as the app really logs them (LogScrubberTest of DELOS for Android).
@Suite struct DiagnosticsScrubberTests {
    private let context = ScrubContext(
        pcNames: ["Meiton-PC", "Living Room"], hostAddresses: ["meiton.example.org"], names: ["Meiton", "Odin Portal"],
        identifiers: ["0123456789abcdef"], secrets: ["sgdbSecretKey99"])

    private func scrub(_ text: String, _ context: ScrubContext? = nil) -> String {
        LogScrubber(context: context ?? self.context).scrub(text)
    }

    @Test func theParallelPollLineLosesTheNameAndTheAddressButKeepsThePort() {
        #expect(scrub("Starting parallel poll for Meiton-PC (192.168.0.200:47989, null, null, null)")
            == "Starting parallel poll for <pc-1> (<ip-1>:47989, null, null, null)")
    }

    @Test func anHTTPSRequestKeepsTheEndpointButNotTheQueryValues() {
        let line = "https://192.168.0.200:47984/applist?devicename=roth&uniqueid=0123456789ABCDEF&uuid=11111111-2222-3333-4444-555555555555"
        #expect(scrub(line) == "https://<ip-1>:47984/applist?devicename=<redacted>&uniqueid=<redacted>&uuid=<redacted>")
    }

    @Test func smallQueryValuesLikeAnAppIDStayReadable() {
        #expect(scrub("http://10.0.0.5:47989/launch?appid=1234&mode=1920x1080x60&rikey=00112233445566778899aabbccddeeff")
            == "http://<ip-1>:47989/launch?appid=1234&mode=1920x1080x60&rikey=<redacted>")
    }

    @Test func aURLWithCredentialsLosesThem() {
        let out = scrub("GET https://user:hunter2@meiton.example.org/api/v1/status?token=abc123 failed")
        #expect(!out.contains("hunter2") && !out.contains("abc123") && !out.contains("meiton"))
        #expect(out.hasPrefix("GET https://<host>/api/v1/status?token=<redacted> failed"))
    }

    @Test func aPublicServiceKeepsItsHostForTheDiagnosis() {
        #expect(scrub("GET https://www.steamgriddb.com/api/v2/grids/game/5254?types=static")
            == "GET https://www.steamgriddb.com/api/v2/grids/game/5254?types=<redacted>")
    }

    @Test func aKnownPCNameAsURLHostBecomesItsAlias() {
        #expect(scrub("https://meiton-pc:47984/serverinfo") == "https://<pc-1>:47984/serverinfo")
    }

    @Test func theUniqueIDIsRemovedByValueAndByShape() {
        #expect(scrub("UID is now: 0123456789abcdef") == "UID is now: <id>")
        #expect(scrub("UID is now: fedcba9876543210", ScrubContext()) == "UID is now: <hex>")
    }

    @Test func ipv4AddressesAreNumberedAndTheSameAddressKeepsItsNumber() {
        #expect(scrub("192.168.0.200 -> 8.8.8.8 -> 192.168.0.200") == "<ip-1> -> <ip-2> -> <ip-1>")
        #expect(scrub("version 999.1.2.3 built") == "version 999.1.2.3 built")
    }

    @Test func ipv6AddressesWithZoneBracketsAndMappedTails() {
        #expect(scrub("addr fe80::1c2d:3eff:fe4f:5a6b%wlan0 used") == "addr <ip-1> used")
        #expect(scrub("connect [2001:db8::1]:47989") == "connect [<ip-1>]:47989")
        #expect(scrub("mapped 2001:db8:0:0:0:0:0:1") == "mapped <ip-1>")
        #expect(scrub("mapped ::ffff:192.168.1.7") == "mapped <ip-1>")
        #expect(scrub("seen fe80::1.") == "seen <ip-1>.")
    }

    @Test func timesAndPortsAreNotMistakenForAddresses() {
        let line = "2026-11-10 12:34:56.789 I/Lime [main] ratio 16:9 at 12:34:56 on port 47989 (Foo::bar)"
        #expect(scrub(line) == line)
    }

    @Test func macAddressesAreNumbered() {
        #expect(scrub("wake 00:1A:2B:3C:4D:5E and aa-bb-cc-dd-ee-ff and 00:1a:2b:3c:4d:5e") == "wake <mac-1> and <mac-2> and <mac-1>")
    }

    @Test func knownNamesAreReplacedAsWholeWordsIgnoringCase() {
        #expect(scrub("living room is online, MEITON-PC's games, homepage") == "<pc-2> is online, <pc-1>'s games, homepage")
        #expect(scrub("hello meiton on Odin Portal") == "hello <name> on <name>")
        #expect(scrub("Meitonic stays") == "Meitonic stays")
        #expect(scrub("PC ended the stream", ScrubContext(pcNames: ["PC"])) == "PC ended the stream")
    }

    @Test func hostAddressesAndKeysAreRemoved() {
        #expect(scrub("resolving meiton.example.org failed") == "resolving <host> failed")
        #expect(scrub("key sgdbSecretKey99 rejected") == "key <secret> rejected")
        #expect(scrub("api_key=abcDEF123", ScrubContext()) == "api_key=<redacted>")
        #expect(scrub("Authorization: Bearer abc.def-ghi", ScrubContext()) == "Authorization: <redacted>")
        #expect(scrub("sent 9fB3kQ7xL2mZ8vC1nR5tY0uW4pH6jD3s done", ScrubContext()) == "sent <token> done")
        #expect(scrub("steamgriddb 0123456789abcdef0123456789abcdef", ScrubContext()) == "steamgriddb <hex>")
    }

    @Test func userNamesInPathsAreRemoved() {
        #expect(scrub("/Users/meiton/Library/Caches/x", ScrubContext()) == "/Users/<user>/Library/Caches/x")
        #expect(scrub("C:\\Users\\Meiton\\AppData\\x", ScrubContext()) == "C:\\Users\\<user>\\AppData\\x")
        #expect(scrub("/home/bob/.config", ScrubContext()) == "/home/<user>/.config")
        #expect(scrub("/storage/1A2B-3C4D/Download/log.txt", ScrubContext()) == "/storage/<volume>/Download/log.txt")
    }

    @Test func wifiNamesSerialsEmailsAndLocalHostNamesAreRemoved() {
        #expect(scrub("connected to SSID: \"Home Wifi 5G\"", ScrubContext()) == "connected to SSID: <redacted>")
        #expect(scrub("BSSID=aa:bb:cc:dd:ee:ff", ScrubContext()) == "BSSID=<redacted>")
        #expect(scrub("serial: R5CT1234ABC", ScrubContext()) == "serial: <redacted>")
        #expect(scrub("from bob@example.com", ScrubContext()) == "from <email>")
        #expect(scrub("cannot reach desktop-4f2k.local", ScrubContext()) == "cannot reach <host>")
        #expect(scrub("Unable to resolve host \"gamingrig\": No address", ScrubContext()) == "Unable to resolve host \"<host>\": No address")
    }

    @Test func anOrdinaryLogLineIsLeftAloneAndScrubbingTwiceChangesNothingMore() {
        let line = "2026-11-10 12:34:56.789 I/Stream [main] Negotiated video: HEVC 4:2:0 10-bit (HDR) 1920x1080 at 120 fps, bitrate 80000 kbps"
        #expect(scrub(line) == line)
        #expect(scrub("Process started: Delos 0.1.0 (debug), build 1, pid 12345") == "Process started: Delos 0.1.0 (debug), build 1, pid 12345")
        let once = scrub("poll Meiton-PC (192.168.0.200:47989) https://192.168.0.200:47984/applist?uniqueid=0123456789abcdef mac 00:1A:2B:3C:4D:5E")
        #expect(scrub(once) == once)
    }

    @Test func nothingOfAMixedLogSurvives() {
        let secrets = ["192.168.0.200", "10.0.0.5", "fe80::1c2d:3eff:fe4f:5a6b", "00:1A:2B:3C:4D:5E", "Meiton-PC", "Living Room",
                       "0123456789abcdef", "sgdbSecretKey99", "meiton.example.org", "hunter2", "Home Wifi", "meiton@example.com"]
        let log = """
            Starting parallel poll for Meiton-PC (192.168.0.200:47989, 10.0.0.5:47989, null, fe80::1c2d:3eff:fe4f:5a6b)
            https://192.168.0.200:47984/applist?devicename=x&uniqueid=0123456789abcdef&uuid=1
            Sending WoL to 00:1A:2B:3C:4D:5E for Living Room via meiton.example.org
            UID is now: 0123456789abcdef
            artwork key sgdbSecretKey99 password=hunter2
            SSID: "Home Wifi" owner meiton@example.com
            """
        let out = scrub(log)
        for secret in secrets { #expect(!out.lowercased().contains(secret.lowercased()), "\(secret) leaked") }
    }
}
