import Testing
@testable import DelosInput

struct CustomKeyCombosTests {
    @Test func readsNamesAndHexCodes() {
        let text = #"{"data":[{"id":"1","name":"Copy","keys":["VK_LCONTROL","0x43"]},{"name":"Esc","keys":["VK_ESCAPE"]}]}"#
        let result = CustomKeyCombos.parse(text)
        #expect(!result.failed)
        #expect(result.options.map(\.label) == ["Copy", "Esc"])
        #expect(result.options[0].combo == KeyCombo([0xA2, 0x43]))
        #expect(result.options[1].combo == KeyCombo([0x1B]))
    }

    @Test func keepsWhatWasReadBeforeAnUnknownKey() {
        let text = #"{"data":[{"name":"A","keys":["VK_A"]},{"name":"Bad","keys":["VK_NOPE"]},{"name":"C","keys":["VK_C"]}]}"#
        let result = CustomKeyCombos.parse(text)
        #expect(result.failed)
        #expect(result.options.map(\.label) == ["A"])
    }

    @Test func emptyIsNoFailureAndJunkIs() {
        #expect(CustomKeyCombos.parse("") == CustomKeyCombos.Result(options: [], failed: false))
        #expect(CustomKeyCombos.parse("not json").failed)
        #expect(CustomKeyCombos.code("0x1FF") == nil)
        #expect(CustomKeyCombos.code("43") == nil)
    }
}
