import Foundation
import Testing
@testable import DelosData

/// A `UserDefaults` suite of its own for each test, removed afterwards.
private final class TestDefaults {
    let name = "delos.tests.\(UUID().uuidString)"
    deinit { UserDefaults().removePersistentDomain(forName: name) }
}

/// The stored on-screen control layouts (`OscLayoutStore` of DELOS for Android): only the changed controls, against their
/// anchor in layout units, in Android's JSON document.
@Suite struct OnScreenControlsStoreTests {
    private let guide = OscPlacement(anchorX: .center, anchorY: .bottom, x: -14, y: 1, width: 12, height: 7, enabled: true)
    private let a = OscPlacement(anchorX: .right, anchorY: .top, x: 12.5, y: 21, width: 10, height: 10, enabled: false)

    @Test func theDocumentIsAndroidsVersionTwo() throws {
        let json = OscLayoutDocument.encode([10: guide], id: OscLayoutDocument.global)
        let document = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(document["version"] as? Int == 2)
        #expect(document["id"] as? String == "global")
        let element = try #require((document["elements"] as? [String: Any])?["10"] as? [String: Any])
        #expect(element["anchorX"] as? String == "CENTER")
        #expect(element["anchorY"] as? String == "BOTTOM")
        #expect(element["x"] as? Double == -14)
        #expect(element["enabled"] as? Bool == true)
    }

    @Test func aDocumentReadsBackAndAnAndroidOneReadsToo() {
        #expect(OscLayoutDocument.decode(OscLayoutDocument.encode([10: guide, 6: a], id: "global")) == [10: guide, 6: a])
        // As Android's JSONObject writes it
        let android = """
            {"version":2,"id":"global","elements":{"10":{"enabled":true,"anchorX":"CENTER","anchorY":"BOTTOM","x":-14.0,"y":1.0,"width":12.0,"height":7.0}}}
            """
        #expect(OscLayoutDocument.decode(android) == [10: guide])
    }

    @Test func anotherVersionOrABrokenDocumentIsTheDefaultLayout() {
        #expect(OscLayoutDocument.decode(#"{"version":1,"id":"global","elements":{}}"#).isEmpty)
        #expect(OscLayoutDocument.decode("not json").isEmpty)
        #expect(OscLayoutDocument.decode(#"{"version":2,"id":"global","elements":{"10":{"anchorX":"MIDDLE"}}}"#).isEmpty)
    }

    @Test func eachProfileKeepsItsOwnLayoutAndNoneRemovesIt() {
        let suite = TestDefaults()
        let store = OnScreenControlsStore(suiteName: suite.name)
        #expect(store.read(profile: "ann").isEmpty)
        store.write([10: guide], profile: "ann")
        store.write([6: a], profile: "bob")
        #expect(store.read(profile: "ann") == [10: guide])
        #expect(store.read(profile: "bob") == [6: a])
        store.write([:], profile: "ann")
        #expect(store.read(profile: "ann").isEmpty)
        #expect(UserDefaults(suiteName: suite.name)?.object(forKey: "osc.ann") == nil, "no changes: nothing stored")
    }

    @Test func resetCopyAndRemove() {
        let suite = TestDefaults()
        let store = OnScreenControlsStore(suiteName: suite.name)
        store.write([10: guide], profile: "ann")
        store.copy(from: "ann", into: "new")
        #expect(store.read(profile: "new") == [10: guide])
        store.reset(profile: "ann")
        #expect(store.read(profile: "ann").isEmpty)
        #expect(store.read(profile: "new") == [10: guide], "a copy is the new profile's own")
        store.remove(profile: "new")
        #expect(store.read(profile: "new").isEmpty)
    }

    @MainActor
    @Test func aNewProfileStartsWithTheCurrentOnesLayoutAndADeletedOneTakesItsAway() async throws {
        let suite = TestDefaults()
        let profiles = ProfileStore(suiteName: suite.name, deleteGrace: .zero)
        let store = OnScreenControlsStore(suiteName: suite.name)
        let ann = try #require(profiles.create(name: "Ann", avatar: 0))
        store.write([10: guide], profile: ann.id)
        let bob = try #require(profiles.create(name: "Bob", avatar: 1))
        #expect(store.read(profile: bob.id) == [10: guide])
        profiles.delete(ann.id)
        let deadline = ContinuousClock.now + .seconds(10)
        while !store.read(profile: ann.id).isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.read(profile: ann.id).isEmpty)
        // The store purges through its own task: it must live until then
        #expect(profiles.profiles.all.map(\.id) == [bob.id])
    }
}
