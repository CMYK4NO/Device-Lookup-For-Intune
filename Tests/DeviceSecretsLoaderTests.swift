import XCTest
@testable import DeviceLookupForIntune

final class DeviceSecretsLoaderTests: XCTestCase {
    private let deviceID = "11111111-1111-1111-1111-111111111111"
    private let entraID = "22222222-2222-2222-2222-222222222222"

    private func device(os: String, entraID: String? = nil) -> ManagedDevice {
        ManagedDevice(id: deviceID, deviceName: "D", serialNumber: nil, userPrincipalName: nil,
                      operatingSystem: os, osVersion: nil, azureADDeviceId: entraID ?? self.entraID)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// Answers by URL path suffix; anything else is a 404.
    private func serve(_ routes: [String: String]) {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            let path = request.url!.path
            let hit = routes.first { path.hasSuffix($0.key) }
            return (HTTPURLResponse(url: request.url!, statusCode: hit == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!,
                    Data((hit?.value ?? #"{"error":{"message":"not found"}}"#).utf8))
        }
    }

    func testMacOSReadsFileVaultKeyAndLAPSPassword() async throws {
        serve([
            "/getFileVaultKey": #"{"value":"AAAA-BBBB"}"#,
            "/retrieveMacOSManagedDeviceLocalAdminAccountDetail":
                #"{"value":{"adminAccountPassword":"s3cret","passwordLastRotatedDateTime":"2026-01-01T10:00:00.2371449+01:00"}}"#,
        ])
        let report = try await DeviceSecretsLoader.load(for: device(os: "macOS"), client: .mocked())

        XCTAssertEqual(report.secrets.map(\.value), ["AAAA-BBBB", "s3cret"])
        XCTAssertNotNil(report.secrets[1].date)
        XCTAssertTrue(report.notes.isEmpty)
    }

    func testMacOSLAPSWithoutAPasswordIsANote() async throws {
        serve([
            "/getFileVaultKey": #"{"value":"K"}"#,
            "/retrieveMacOSManagedDeviceLocalAdminAccountDetail": #"{"value":{"passwordLastRotatedDateTime":"2026-01-01T10:00:00Z"}}"#,
        ])
        let report = try await DeviceSecretsLoader.load(for: device(os: "macOS"), client: .mocked())

        XCTAssertEqual(report.secrets.map(\.value), ["K"])
        XCTAssertTrue(report.notes.contains { $0.contains("returned no password") })
    }

    func testMacOSLAPSAcceptsASingleObjectAndBase64() async throws {
        serve([
            "/getFileVaultKey": #"{"value":null}"#,
            "/retrieveMacOSManagedDeviceLocalAdminAccountDetail":
                #"{"value":{"userName":"root2","passwordBase64":"cHc="}}"#,
        ])
        let report = try await DeviceSecretsLoader.load(for: device(os: "macOS"), client: .mocked())

        XCTAssertEqual(report.secrets.map(\.value), ["pw"])
        XCTAssertEqual(report.secrets.first?.detail, "root2")
    }

    func testWindowsReadsLAPSPasswordAndBitLockerKeys() async throws {
        serve([
            "/directory/deviceLocalCredentials/\(entraID)":
                #"{"credentials":[{"accountName":"Administrator","backupDateTime":"2026-02-01T08:00:00Z","passwordBase64":"cGFzcw=="}]}"#,
            "/informationProtection/bitlocker/recoveryKeys":
                #"{"value":[{"id":"33333333-3333-3333-3333-333333333333","createdDateTime":"2026-01-01T00:00:00Z","volumeType":"operatingSystemVolume"}]}"#,
            "/recoveryKeys/33333333-3333-3333-3333-333333333333":
                #"{"id":"33333333-3333-3333-3333-333333333333","createdDateTime":"2026-01-01T00:00:00Z","volumeType":"operatingSystemVolume","key":"111111-222222"}"#,
        ])
        let report = try await DeviceSecretsLoader.load(for: device(os: "Windows"), client: .mocked())

        XCTAssertEqual(report.secrets.map(\.value), ["pass", "111111-222222"])
        XCTAssertEqual(report.secrets[0].detail, "Administrator")
        XCTAssertEqual(report.secrets[1].detail, "Operating system drive")
    }

    func testBitLockerListIsFilteredByEntraDeviceID() async throws {
        serve(["/informationProtection/bitlocker/recoveryKeys": #"{"value":[]}"#])
        _ = try await DeviceSecretsLoader.load(for: device(os: "Windows"), client: .mocked())

        let list = try XCTUnwrap(MockURLProtocol.requests.first { $0.url!.path.hasSuffix("/recoveryKeys") })
        let query = URLComponents(url: list.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "$filter" }?.value, "deviceId eq '\(entraID)'")
    }

    func testMissingSecretsBecomeNotes() async throws {
        serve([:])
        let report = try await DeviceSecretsLoader.load(for: device(os: "Windows"), client: .mocked())

        XCTAssertTrue(report.secrets.isEmpty)
        XCTAssertEqual(report.notes.count, 2)
        XCTAssertTrue(report.notes[0].contains("none is stored"))
    }

    func testForbiddenIsANoteButUnauthorizedAborts() async throws {
        MockURLProtocol.reply(status: 403, json: #"{"error":{"message":"denied"}}"#)
        let report = try await DeviceSecretsLoader.load(for: device(os: "macOS"), client: .mocked())
        XCTAssertEqual(report.notes.count, 2)
        XCTAssertTrue(report.notes[0].contains("403"))

        MockURLProtocol.reply(status: 401, json: "{}")
        do {
            _ = try await DeviceSecretsLoader.load(for: device(os: "macOS"), client: .mocked())
            XCTFail("401 must abort")
        } catch {
            XCTAssertEqual(error as? GraphError, .unauthorized)
        }
    }

    func testOtherPlatformsAreNotQueried() async throws {
        serve([:])
        let report = try await DeviceSecretsLoader.load(for: device(os: "Linux"), client: .mocked())
        XCTAssertEqual(report, SecretsReport())
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testIdsMustBeGUIDs() async throws {
        XCTAssertEqual(try DeviceSecretsLoader.guid("AAAAAAAA-1111-1111-1111-111111111111"), "aaaaaaaa-1111-1111-1111-111111111111")
        XCTAssertThrowsError(try DeviceSecretsLoader.guid("x' or 1 eq 1"))
        XCTAssertThrowsError(try DeviceSecretsLoader.guid(nil))

        // A Windows device without an Entra id never reaches Graph.
        serve([:])
        let noEntra = ManagedDevice(id: deviceID, deviceName: nil, serialNumber: nil, userPrincipalName: nil,
                                    operatingSystem: "Windows", osVersion: nil, azureADDeviceId: nil)
        let report = try await DeviceSecretsLoader.load(for: noEntra, client: .mocked())
        XCTAssertTrue(report.secrets.isEmpty)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
}
