import XCTest
@testable import DeviceLookupForIntune

@MainActor
final class SecretsViewModelTests: XCTestCase {
    private let device = ManagedDevice(id: "11111111-1111-1111-1111-111111111111", deviceName: "Mac", serialNumber: nil,
                                       userPrincipalName: nil, operatingSystem: "macOS", osVersion: nil, azureADDeviceId: nil)

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testLoadStoresTheReportAndClearDropsIt() async {
        MockURLProtocol.reply(json: #"{"value":"KEY"}"#)
        let model = SecretsViewModel()
        await model.load(device, client: .mocked())

        XCTAssertEqual(model.reports[device.id]?.secrets.first?.value, "KEY")
        XCTAssertTrue(model.loading.isEmpty)

        model.clear()
        XCTAssertTrue(model.reports.isEmpty)
    }

    func testSelectionChangeClearsRevealedSecrets() async {
        MockURLProtocol.reply(json: #"{"value":"KEY"}"#)
        let search = DeviceSearchViewModel()
        await search.secrets.load(device, client: .mocked())
        XCTAssertFalse(search.secrets.reports.isEmpty)

        search.selection = ["a"]
        XCTAssertTrue(search.secrets.reports.isEmpty)
    }
}
