import Foundation
import Testing
@testable import DelosData

/// A `UserDefaults` suite of its own for each test, removed afterwards.
private final class TestDefaults {
    let name = "delos.tests.\(UUID().uuidString)"
    deinit { UserDefaults().removePersistentDomain(forName: name) }
}

@MainActor
@Suite struct ProfileStoreTests {
    @Test func theFirstRunLastsUntilAProfileExists() {
        let suite = TestDefaults()
        let store = ProfileStore(suiteName: suite.name)
        #expect(store.isFirstRun)
        #expect(store.current == nil)
        store.create(name: "Ann", avatar: 3)
        #expect(!store.isFirstRun)
        // A new launch reads the same state
        #expect(!ProfileStore(suiteName: suite.name).isFirstRun)
    }

    @Test func aCreatedProfileBecomesTheCurrentOneAndIsStored() throws {
        let suite = TestDefaults()
        let store = ProfileStore(suiteName: suite.name)
        let ann = try #require(store.create(name: "  Ann  ", avatar: 3))
        let bob = try #require(store.create(name: "Bob", avatar: 7))
        #expect(ann.name == "Ann")
        #expect(ann.id != bob.id)
        #expect(store.current == bob)
        let reloaded = ProfileStore(suiteName: suite.name)
        #expect(reloaded.profiles.all == [ann, bob])
        #expect(reloaded.current == bob)
    }

    @Test func aBlankNameCreatesNothing() {
        let suite = TestDefaults()
        let store = ProfileStore(suiteName: suite.name)
        #expect(store.create(name: " \n ", avatar: 0) == nil)
        #expect(store.isFirstRun)
    }

    @Test func aNewProfileStartsWithACopyOfTheCurrentAppearance() throws {
        let suite = TestDefaults()
        let store = ProfileStore(suiteName: suite.name)
        let appearance = AppearanceStore(suiteName: suite.name)
        let ann = try #require(store.create(name: "Ann", avatar: 0))
        var mint = Appearance()
        mint.palette = .mint
        appearance.save(mint, profile: ann.id)
        let bob = try #require(store.create(name: "Bob", avatar: 1))
        #expect(appearance.load(profile: bob.id).palette == .mint)
    }

    @Test func renameAndAvatarChangeOnlyTheirProfile() throws {
        let suite = TestDefaults()
        let store = ProfileStore(suiteName: suite.name)
        let ann = try #require(store.create(name: "Ann", avatar: 1))
        let bob = try #require(store.create(name: "Bob", avatar: 2))
        #expect(store.rename(ann.id, to: " Annie "))
        store.setAvatar(ann.id, avatar: 9)
        #expect(!store.rename(ann.id, to: "   "))
        #expect(!store.rename("missing", to: "X"))
        let reloaded = ProfileStore(suiteName: suite.name)
        #expect(reloaded.profiles.all == [Profile(id: ann.id, name: "Annie", avatar: 9), bob])
    }

    @Test func switchingChangesTheCurrentProfileOnlyToAKnownOne() throws {
        let suite = TestDefaults()
        let store = ProfileStore(suiteName: suite.name)
        let ann = try #require(store.create(name: "Ann", avatar: 0))
        store.create(name: "Bob", avatar: 0)
        store.switchTo(ann.id)
        #expect(store.current == ann)
        store.switchTo("missing")
        #expect(store.current == ann)
        #expect(ProfileStore(suiteName: suite.name).current == ann)
    }

    @Test func removingTheCurrentProfileHandsOverToTheFirstRemainingOne() throws {
        let suite = TestDefaults()
        let store = ProfileStore(suiteName: suite.name)
        let ann = try #require(store.create(name: "Ann", avatar: 0))
        let bob = try #require(store.create(name: "Bob", avatar: 0))
        let cid = try #require(store.create(name: "Cid", avatar: 0))
        store.switchTo(bob.id)
        #expect(store.remove(bob.id))
        #expect(store.current == ann)
        // Removing another profile keeps the current one
        #expect(store.remove(cid.id))
        #expect(store.current == ann)
        #expect(store.profiles.all == [ann])
    }

    @Test func removingTheLastProfileStartsTheFirstRunAgainAndForgetsItsSettings() throws {
        let suite = TestDefaults()
        let store = ProfileStore(suiteName: suite.name)
        let appearance = AppearanceStore(suiteName: suite.name)
        let ann = try #require(store.create(name: "Ann", avatar: 0))
        var light = Appearance()
        light.dark = false
        appearance.save(light, profile: ann.id)
        #expect(!store.remove(ann.id))
        #expect(store.isFirstRun)
        #expect(appearance.load(profile: ann.id) == Appearance())
        #expect(ProfileStore(suiteName: suite.name).isFirstRun)
    }
}

@Suite struct ProfileDecodingTests {
    @Test func unreadableProfilesAreSkippedAndTheOthersKept() throws {
        // No name, an empty id, a duplicate id, an avatar of the wrong type, an unknown field
        let json = #"""
        {"all":[{"id":"a","name":"Ann","avatar":4},{"id":"b"},{"id":"","name":"Nobody"},{"id":"a","name":"Again"},
        {"id":"c","name":"Cid","avatar":"fox","color":"red"}],"currentID":"c"}
        """#
        let profiles = try JSONDecoder().decode(Profiles.self, from: Data(json.utf8))
        #expect(profiles.all == [Profile(id: "a", name: "Ann", avatar: 4), Profile(id: "c", name: "Cid", avatar: 0)])
        #expect(profiles.current?.id == "c")
    }

    @Test func anUnknownCurrentIdFallsBackToTheFirstProfile() throws {
        let json = #"{"all":[{"id":"a","name":"Ann"},{"id":"b","name":"Bob"}],"currentID":"gone"}"#
        let profiles = try JSONDecoder().decode(Profiles.self, from: Data(json.utf8))
        #expect(profiles.current?.id == "a")
    }

    @Test func aBrokenListIsTheFirstRun() async {
        let suite = TestDefaults()
        UserDefaults(suiteName: suite.name)?.set(Data(#"{"all":"nonsense"}"#.utf8), forKey: "profiles")
        let store = await ProfileStore(suiteName: suite.name)
        #expect(await store.isFirstRun)
    }

    @Test func namesAreTrimmedAndCutToTwentyCharacters() {
        #expect(Profile.cleanName("  Ann ") == "Ann")
        #expect(Profile.cleanName("") == nil)
        #expect(Profile.cleanName(" \t") == nil)
        #expect(Profile.cleanName(String(repeating: "x", count: 30)) == String(repeating: "x", count: 20))
        // A cut that ends in a space does not keep it
        #expect(Profile.cleanName("Nineteen characters x") == "Nineteen characters")
    }
}
