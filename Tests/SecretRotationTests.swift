import XCTest
@testable import DeviceLookupForIntune

@MainActor
final class SecretRotationTests: XCTestCase {
    private let device = ManagedDevice(id: "11111111-1111-1111-1111-111111111111", deviceName: "Mac", serialNumber: nil,
                                       userPrincipalName: nil, operatingSystem: "macOS", osVersion: nil, azureADDeviceId: nil)

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testPerformPostsTheRemoteAction() async throws {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        for (rotation, action) in [(SecretRotation.fileVault, "rotateFileVaultKey"),
                                   (.laps, "rotateLocalAdminPassword"),
                                   (.bitLocker, "rotateBitLockerKeys")] {
            try await rotation.perform(on: device, client: .mocked())
            let request = try XCTUnwrap(MockURLProtocol.requests.last)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/beta/deviceManagement/managedDevices/\(device.id)/\(action)")
        }
    }

    func testPerformRejectsANonGUIDDevice() async {
        let bad = ManagedDevice(id: "../x", deviceName: nil, serialNumber: nil, userPrincipalName: nil,
                                operatingSystem: "macOS", osVersion: nil, azureADDeviceId: nil)
        do {
            try await SecretRotation.laps.perform(on: bad, client: .mocked())
            XCTFail("must not send")
        } catch {
            XCTAssertEqual(error as? GraphError, .invalidRequest)
        }
    }

    func testSuccessDropsRevealedValuesAndSetsANotice() async {
        MockURLProtocol.reply(json: #"{"value":"KEY"}"#)
        let model = SecretsViewModel()
        await model.load(device, client: .mocked())
        XCTAssertNotNil(model.reports[device.id])

        MockURLProtocol.reply(status: 204, json: "")
        await model.rotate(.fileVault, device: device, client: .mocked())

        XCTAssertNil(model.reports[device.id])
        XCTAssertTrue(model.notices[device.id]?.contains("requested") == true)
        XCTAssertNil(model.errorMessage)

        MockURLProtocol.reply(json: #"{"value":"NEW"}"#)
        await model.load(device, client: .mocked())
        XCTAssertNil(model.notices[device.id])
    }

    func testFailureShowsTheErrorAndKeepsValues() async {
        MockURLProtocol.reply(json: #"{"value":"KEY"}"#)
        let model = SecretsViewModel()
        await model.load(device, client: .mocked())

        MockURLProtocol.reply(status: 403, json: #"{"error":{"message":"no role"}}"#)
        await model.rotate(.laps, device: device, client: .mocked())

        XCTAssertNotNil(model.reports[device.id])
        XCTAssertTrue(model.errorMessage?.contains("403") == true)
    }
}
