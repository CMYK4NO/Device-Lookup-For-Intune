import XCTest
@testable import DeviceLookupForIntune

@MainActor
final class ResultsCacheTests: XCTestCase {
    private let script = ScriptSummary(id: "s1", displayName: "Battery", customAttributeName: "battery", lastModifiedDateTime: nil)

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func results(_ date: Date = Date()) -> CachedResults {
        CachedResults(items: [], rows: [], inventory: [:], loadedAt: date)
    }

    private let body = #"{"value":[{"id":"1","runState":"success","resultMessage":"88%","managedDevice":{"id":"d1","deviceName":"Mac","userPrincipalName":"a@x.com","serialNumber":"SN1","operatingSystem":"macOS","osVersion":"14"}}]}"#

    func testOldestEntriesAreDroppedBeyondCapacity() {
        let cache = ResultsCache()
        for index in 0...ResultsCache.capacity { cache.store("k\(index)", results()) }
        XCTAssertNil(cache.entry("k0"))
        XCTAssertNotNil(cache.entry("k1"))
        XCTAssertNotNil(cache.entry("k\(ResultsCache.capacity)"))
        cache.clear()
        XCTAssertNil(cache.entry("k1"))
    }

    func testOpeningAgainShowsTheCachedRowsWithoutARequest() async {
        let cache = ResultsCache()
        MockURLProtocol.script([(200, [:], body)])
        let first = AttributeResultsViewModel(config: .macOS, script: script, cache: cache)
        await first.load(client: .mocked())
        XCTAssertEqual(first.rows.count, 1)
        XCTAssertNotNil(first.loadedAt)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)

        let second = AttributeResultsViewModel(config: .macOS, script: script, cache: cache)
        await second.load(client: .mocked())
        XCTAssertEqual(second.rows.count, 1)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testForceReloadsAndStaleResultsAreShownThenRefreshed() async {
        let cache = ResultsCache()
        MockURLProtocol.script([(200, [:], body)])
        let model = AttributeResultsViewModel(config: .macOS, script: script, cache: cache)
        await model.load(client: .mocked())
        await model.load(client: .mocked(), force: true)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)

        let key = ResultsCache.key(config: .macOS, script: script)
        let old = Date().addingTimeInterval(-AttributeResultsViewModel.staleAfter - 60)
        cache.store(key, CachedResults(items: [], rows: model.rows, inventory: [:], loadedAt: old))
        let stale = AttributeResultsViewModel(config: .macOS, script: script, cache: cache)
        await stale.load(client: .mocked())
        XCTAssertEqual(MockURLProtocol.requests.count, 3)
        XCTAssertEqual(stale.rows.count, 1)
    }

    func testRecentItemsKeepTheLatestFewMostRecentFirst() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RecentItemsTests"))
        defaults.removePersistentDomain(forName: "RecentItemsTests")
        let recent = RecentItems(defaults: defaults)
        for index in 1...(RecentItems.limit + 2) { recent.record(sourceID: "macOS", itemID: "s\(index)") }
        recent.record(sourceID: "macOS", itemID: "s4")
        XCTAssertEqual(recent.items.count, RecentItems.limit)
        XCTAssertEqual(recent.items.first?.itemID, "s4")
        XCTAssertEqual(recent.items.map { $0.itemID }, ["s4", "s6", "s5", "s3"])
    }
}
