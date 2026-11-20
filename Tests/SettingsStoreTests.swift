import XCTest
@testable import DeviceLookupForIntune

final class SettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testNothingIsConfiguredUntilTheAdminEntersIDs() {
        let store = SettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.tenantID, "")
        XCTAssertEqual(store.clientID, "")
        XCTAssertNil(store.authConfiguration)
    }

    func testClearedValuesAreNotConfigured() {
        let store = SettingsStore(defaults: makeDefaults())
        store.tenantID = "tenant"
        store.clientID = "client"
        XCTAssertNotNil(store.authConfiguration)
        store.tenantID = ""
        XCTAssertNil(store.authConfiguration)
    }

    func testValuesPersistAcrossInstances() {
        let defaults = makeDefaults()
        let first = SettingsStore(defaults: defaults)
        first.tenantID = " tenant "
        first.clientID = "client"

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.tenantID, " tenant ")
        XCTAssertEqual(second.authConfiguration, AuthConfiguration(tenantID: "tenant", clientID: "client"))
    }
}
