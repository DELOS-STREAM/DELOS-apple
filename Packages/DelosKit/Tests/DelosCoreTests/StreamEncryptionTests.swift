import Testing
@testable import DelosCore

struct StreamEncryptionTests {
    @Test func flagsAndControlVersion() {
        let both = StreamEncryption.of(flags: 3, serverAppVersion: "7.1.431.0")
        #expect(both == StreamEncryption(video: true, audio: true, control: true))
        let audioOnly = StreamEncryption.of(flags: 2, serverAppVersion: "7.1.430.0")
        #expect(audioOnly == StreamEncryption(video: false, audio: true, control: false))
        let unknown = StreamEncryption.of(flags: nil, serverAppVersion: nil)
        #expect(unknown == StreamEncryption(video: nil, audio: nil, control: false))
    }

    @Test func controlVersionBoundaries() {
        #expect(StreamEncryption.controlEncrypted(serverAppVersion: "8.0.0"))
        #expect(StreamEncryption.controlEncrypted(serverAppVersion: "7.2.0"))
        #expect(!StreamEncryption.controlEncrypted(serverAppVersion: "7.1"))
        #expect(!StreamEncryption.controlEncrypted(serverAppVersion: "7.x.500"))
        #expect(!StreamEncryption.controlEncrypted(serverAppVersion: "6.9.999"))
    }

    @Test func logLine() {
        #expect(StreamEncryption(video: true, audio: false, control: true).logLine
            == "Stream encryption: video on, audio off, control on")
        #expect(StreamEncryption(video: nil, audio: nil, control: false).logLine
            == "Stream encryption: video unknown, audio unknown, control off")
    }
}
