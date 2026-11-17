import Foundation
import Testing
@testable import DelosData

@Suite struct StoreLocationTests {
    @Test func tvOSKeepsMetadataUnderCaches() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path
        #expect(MetadataStore.defaultDirectory(tvOS: true).path.hasPrefix(caches))
    }

    @Test func otherPlatformsKeepMetadataInApplicationSupport() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        #expect(MetadataStore.defaultDirectory(tvOS: false).path.hasPrefix(support))
    }
}
