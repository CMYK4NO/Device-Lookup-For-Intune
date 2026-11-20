import XCTest
@testable import DeviceLookupForIntune

final class StatusRowTests: XCTestCase {
    private let mac = ManagedDevice(id: "d1", deviceName: "TEST-MAC", serialNumber: "SER1", userPrincipalName: nil, operatingSystem: "macOS", osVersion: nil, azureADDeviceId: nil)
    private let pc = ManagedDevice(id: "d2", deviceName: "TEST-PC", serialNumber: "SER2", userPrincipalName: nil, operatingSystem: "Windows", osVersion: nil, azureADDeviceId: nil)

    func testComplianceListsEveryPolicyWithItsState() {
        var status = DeviceStatus(compliancePolicies: [
            CompliancePolicy(id: "p1", name: "Mac policy", state: "nonCompliant"),
            CompliancePolicy(id: "p2", name: "Other policy", state: "compliant"),
        ])
        status.loaded = [.compliance]
        let rows = StatusRows.make(.compliance, devices: [mac], statuses: ["d1": status])
        XCTAssertEqual(rows.map(\.name), ["Mac policy", "Other policy"])
        XCTAssertEqual(rows.map(\.state), ["Not compliant", "Compliant"])
        XCTAssertEqual(rows[0].serial, "SER1")
        XCTAssertEqual(rows[0].os, "macOS")
    }

    func testPartsNotReadYetGiveNoRows() {
        var status = DeviceStatus(configurations: [ConfigurationItem(id: "c", name: "Wi-Fi", state: "Succeeded")])
        status.loaded = [.compliance]
        XCTAssertTrue(StatusRows.make(.configuration, devices: [mac], statuses: ["d1": status]).isEmpty)
    }

    func testAppsShowInstalledAndFailedOnlyFailuresFirstAcrossDevicesInOrder() {
        var first = DeviceStatus(apps: [
            AppItem(id: "a", name: "Zoom", version: "6", installState: "installed"),
            AppItem(id: "b", name: "Teams", version: nil, installState: "failed"),
            AppItem(id: "c", name: "Other", version: nil, installState: "notInstalled"),
        ])
        first.loaded = [.apps]
        var second = DeviceStatus(apps: [AppItem(id: "d", name: "Edge", version: "1", installState: "installed")])
        second.loaded = [.apps]
        let rows = StatusRows.make(.apps, devices: [pc, mac], statuses: ["d1": first, "d2": second])
        XCTAssertEqual(rows.map(\.name), ["Edge", "Teams", "Zoom"])
        XCTAssertEqual(rows.map(\.device), ["TEST-PC", "TEST-MAC", "TEST-MAC"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    }

    func testEachRowCarriesTheDateOfItsOwnItemNotTheDeviceCheckIn() {
        var device = mac
        device.lastSyncDateTime = "2026-11-18T08:30:00Z"
        let checked = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = Date(timeIntervalSince1970: 1_710_000_000)
        let installed = Date(timeIntervalSince1970: 1_720_000_000)
        var status = DeviceStatus(
            compliancePolicies: [CompliancePolicy(id: "p", name: "Mac policy", state: "compliant", lastReported: checked)],
            configurations: [ConfigurationItem(id: "c", name: "Wi-Fi", state: "Succeeded", lastUpdated: updated)],
            apps: [AppItem(id: "a", name: "Zoom", version: "6", installState: "installed", lastModified: installed)]
        )
        status.loaded = [.compliance, .configuration, .apps]
        let statuses = ["d1": status]
        XCTAssertEqual(StatusRows.make(.compliance, devices: [device], statuses: statuses).map(\.date), [checked])
        XCTAssertEqual(StatusRows.make(.configuration, devices: [device], statuses: statuses).map(\.date), [updated])
        XCTAssertEqual(StatusRows.make(.apps, devices: [device], statuses: statuses).map(\.date), [installed])
    }

    func testPoliciesAndProfilesShowTheirUserAndTheDeviceOSVersion() {
        let device = ManagedDevice(id: "d1", deviceName: "TEST-MAC", serialNumber: "SER1", userPrincipalName: "primary@x.com",
                                   operatingSystem: "macOS", osVersion: "26.7.1 (25G241)", azureADDeviceId: nil)
        var status = DeviceStatus(
            compliancePolicies: [CompliancePolicy(id: "p", name: "Mac policy", state: "compliant", user: "a@x.com"),
                                 CompliancePolicy(id: "p", name: "Mac policy", state: "nonCompliant")],
            configurations: [ConfigurationItem(id: "c", name: "Wi-Fi", state: "Succeeded", user: "b@x.com")]
        )
        status.loaded = [.compliance, .configuration]
        let compliance = StatusRows.make(.compliance, devices: [device], statuses: ["d1": status])
        XCTAssertEqual(compliance.map(\.user), ["a@x.com", ""], "a policy reported without a user is not given the primary user")
        XCTAssertEqual(compliance.map(\.osVersion), ["26.7.1 (25G241)", "26.7.1 (25G241)"])
        XCTAssertEqual(Set(compliance.map(\.id)).count, 2)
        XCTAssertEqual(StatusRows.make(.configuration, devices: [device], statuses: ["d1": status]).map(\.user), ["b@x.com"])
    }
}
