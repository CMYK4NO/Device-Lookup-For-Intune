import XCTest
@testable import DeviceLookupForIntune

final class OSSourceConfigTests: XCTestCase {
    func testMacOSMapping() {
        let config = OSSourceConfig.macOS
        XCTAssertEqual(config.listPath, "/deviceManagement/deviceCustomAttributeShellScripts")
        XCTAssertEqual(config.valueField, "resultMessage")
        XCTAssertEqual(config.runStateField, "runState")
        XCTAssertEqual(config.runStatesPath(scriptID: "abc"), "/deviceManagement/deviceCustomAttributeShellScripts/abc/deviceRunStates")
        XCTAssertEqual(config.listQuery.first?.value, "id,displayName,customAttributeName,lastModifiedDateTime")
        XCTAssertEqual(config.runStatesQuery.first?.name, "$expand")
        XCTAssertTrue(config.runStatesQuery.first?.value?.contains("userPrincipalName") == true)
    }

    func testWindowsMapping() {
        let config = OSSourceConfig.windows
        XCTAssertEqual(config.listPath, "/deviceManagement/deviceHealthScripts")
        XCTAssertEqual(config.runStatesPath(scriptID: "abc"), "/deviceManagement/deviceHealthScripts/abc/deviceRunStates")
        XCTAssertEqual(config.valueField, "preRemediationDetectionScriptOutput")
        XCTAssertEqual(config.runStateField, "detectionState")
        XCTAssertEqual(config.listQuery.first?.value, "id,displayName,lastModifiedDateTime")
    }

    func testLinuxMapping() {
        let config = OSSourceConfig.linux
        XCTAssertEqual(config.listPath, "/deviceManagement/deviceComplianceScripts")
        XCTAssertEqual(config.runStatesPath(scriptID: "abc"), "/deviceManagement/deviceComplianceScripts/abc/deviceRunStates")
        XCTAssertEqual(config.valueField, "scriptOutput")
        XCTAssertEqual(config.runStateField, "detectionState")
    }

    func testAllOSesAreListedOnceWithDistinctIDs() {
        XCTAssertEqual(OSSourceConfig.all.map(\.name), ["macOS", "Windows", "Linux"])
        XCTAssertEqual(Set(OSSourceConfig.all.map(\.id)).count, 3)
        for config in OSSourceConfig.all {
            XCTAssertEqual(config.runStatesQuery.first?.name, "$expand")
            XCTAssertFalse(config.symbol.isEmpty)
        }
    }

    func testStatusSourcesReadDeviceStatusesPerOS() {
        for sources in [OSSourceConfig.complianceSources, OSSourceConfig.configurationSources, OSSourceConfig.appSources] {
            XCTAssertEqual(sources.map(\.name), ["macOS", "Windows", "Linux"])
        }
        XCTAssertEqual(OSSourceConfig.allSources.count, 12)
        XCTAssertEqual(Set(OSSourceConfig.allSources.map(\.id)).count, 12)
        XCTAssertEqual(OSSourceConfig.complianceSources[0].runStatesPath(scriptID: "p1"), "/deviceManagement/deviceCompliancePolicies/p1/deviceStatuses")
        XCTAssertEqual(OSSourceConfig.configurationSources[1].runStatesPath(scriptID: "p1"), "/deviceManagement/deviceConfigurations/p1/deviceStatuses")
        XCTAssertEqual(OSSourceConfig.appSources[2].runStatesPath(scriptID: "a1"), "/deviceAppManagement/mobileApps/a1/deviceStatuses")
    }

    func testSourcesPickTheItemsOfTheirOS() {
        func item(_ type: String?) -> ScriptSummary { ScriptSummary(id: "1", displayName: nil, customAttributeName: nil, lastModifiedDateTime: nil, odataType: type) }
        let apps = OSSourceConfig.appSources
        XCTAssertTrue(apps[0].accepts(item("#microsoft.graph.macOSPkgApp")))
        XCTAssertFalse(apps[1].accepts(item("#microsoft.graph.macOSPkgApp")))
        XCTAssertTrue(apps[1].accepts(item("#microsoft.graph.win32LobApp")))
        XCTAssertTrue(apps[1].accepts(item("#microsoft.graph.officeSuiteApp")))
        XCTAssertTrue(apps[0].accepts(item("#microsoft.graph.macOSOfficeSuiteApp")))
        XCTAssertFalse(apps[1].accepts(item("#microsoft.graph.macOSOfficeSuiteApp")))
        XCTAssertFalse(apps[2].accepts(item("#microsoft.graph.iosStoreApp")))
        XCTAssertTrue(apps[2].accepts(item(nil)))
        XCTAssertTrue(OSSourceConfig.complianceSources[1].accepts(item("#microsoft.graph.windows10CompliancePolicy")))
        XCTAssertFalse(OSSourceConfig.complianceSources[0].accepts(item("#microsoft.graph.iosCompliancePolicy")))
        XCTAssertTrue(OSSourceConfig.macOS.accepts(item("#microsoft.graph.anything")))
    }

    func testOnlyAssignedPoliciesAndAppsAreListed() throws {
        func item(_ json: String) throws -> ScriptSummary { try JSONDecoder().decode(ScriptSummary.self, from: Data(json.utf8)) }
        let compliance = OSSourceConfig.complianceSources[0]
        XCTAssertTrue(compliance.accepts(try item(##"{"id":"1","@odata.type":"#microsoft.graph.macOSCompliancePolicy","assignments":[{"id":"a"}]}"##)))
        XCTAssertFalse(compliance.accepts(try item(##"{"id":"1","@odata.type":"#microsoft.graph.macOSCompliancePolicy","assignments":[]}"##)))
        XCTAssertFalse(OSSourceConfig.appSources[0].accepts(try item(##"{"id":"1","@odata.type":"#microsoft.graph.macOSPkgApp","isAssigned":false}"##)))
        XCTAssertTrue(OSSourceConfig.appSources[0].accepts(try item(##"{"id":"1","@odata.type":"#microsoft.graph.macOSPkgApp","isAssigned":true}"##)))
        XCTAssertTrue(compliance.accepts(try item(##"{"id":"1","@odata.type":"#microsoft.graph.macOSCompliancePolicy"}"##)), "unknown counts as assigned")
        XCTAssertTrue(OSSourceConfig.macOS.accepts(try item(#"{"id":"1","assignments":[]}"#)), "attributes are not filtered")
        XCTAssertEqual(OSSourceConfig.compliance.listQuery.last?.value, "assignments")
    }

    func testOnlyAppsAskForTheAppsPermission() {
        let base = AuthConfiguration(tenantID: "t", clientID: "c")
        for config in OSSourceConfig.allSources {
            XCTAssertEqual(config.authConfiguration(base).scope.contains("DeviceManagementApps.Read.All"), config.id.hasPrefix("apps"), config.id)
        }
    }

    func testRunStatesURL() throws {
        let config = OSSourceConfig.macOS
        let url = try GraphClient.mocked().url(path: config.runStatesPath(scriptID: "abc"), query: config.runStatesQuery)
        XCTAssertEqual(url.path, "/beta/deviceManagement/deviceCustomAttributeShellScripts/abc/deviceRunStates")
        let expand = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$expand" }
        XCTAssertEqual(expand?.value, config.runStatesQuery.first?.value)
    }

    func testNoODataRouteBecomesAReadableMessage() {
        let noRoute = GraphError.http(status: 400, message: "No OData route exists that match template ~/singleton")
        XCTAssertEqual(
            OSSourceConfig.linux.message(for: noRoute),
            "Linux results are not available: Intune has no per-device run-state endpoint for these scripts in this tenant."
        )
        let other = GraphError.http(status: 400, message: "Bad filter")
        XCTAssertEqual(OSSourceConfig.linux.message(for: other), other.localizedDescription)
    }
}

extension OSSourceConfigTests {
    func testEveryResultsRequestAsksForTheLargestPage() {
        for config in OSSourceConfig.allSources where config.report == nil {
            XCTAssertEqual(config.runStatesQuery.first { $0.name == "$top" }?.value, "1000", config.id)
        }
    }
}
