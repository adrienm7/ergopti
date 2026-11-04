// Tests/ErgoptiPlusTests/OwnedRuntimeVirtualHIDProvisionOwnerTests.swift
// The VirtualHIDDevice daemon job is pqrs' plist keys under Ergopti's label; the role installs only the pinned package.
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeVirtualHIDProvisionOwnerTests: XCTestCase {
	func testTheJobKeepsPqrsKeysUnderErgoptisLabel() throws {
		let job = try XCTUnwrap(PropertyListSerialization.propertyList(
			from: OwnedRuntimeVirtualHIDProvisionOwner.jobBytes(), format: nil) as? [String: Any])
		XCTAssertEqual(job["Label"] as? String, Identifiers.ServiceLabels.macosVirtualHid)
		XCTAssertEqual(job["ProgramArguments"] as? [String], [OwnedVirtualHIDDaemonReportReference.daemonExecutable])
		XCTAssertEqual(job["KeepAlive"] as? Bool, true)
		XCTAssertEqual(job["ProcessType"] as? String, "Interactive")
		XCTAssertEqual(Set(job.keys), ["Label", "KeepAlive", "ProcessType", "ProgramArguments"])
	}

	func testTheKeptDriverPackageIsReadFromThePinOnly() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent("vhid-pin-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: home) }
		let folder = home.appendingPathComponent("Library/Application Support/ErgoptiPlus/RemapRuntime/VirtualHIDDevice/8.5.0")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let digest = String(repeating: "a", count: 64)
		func manifest(team: String = "G43BCU2T37", name: String = "Karabiner-DriverKit-VirtualHIDDevice-8.5.0.pkg") throws -> Data {
			try JSONSerialization.data(withJSONObject: ["virtual_hid_device": [
				"version": "8.5.0", "file_name": name, "sha256": digest, "team_identifier": team]])
		}
		XCTAssertNil(OwnedRuntimeDownloadedHelper.driverPackage(manifest: try manifest(), home: home.path), "not downloaded yet")
		try Data("pkg".utf8).write(to: folder.appendingPathComponent("Karabiner-DriverKit-VirtualHIDDevice-8.5.0.pkg"))
		let package = try XCTUnwrap(OwnedRuntimeDownloadedHelper.driverPackage(manifest: try manifest(), home: home.path))
		XCTAssertEqual(package.sha256, digest)
		XCTAssertEqual(package.team, "G43BCU2T37")
		XCTAssertTrue(package.path.hasSuffix("/VirtualHIDDevice/8.5.0/Karabiner-DriverKit-VirtualHIDDevice-8.5.0.pkg"))
		XCTAssertNil(OwnedRuntimeDownloadedHelper.driverPackage(manifest: try manifest(team: "G43BCU2T3'"), home: home.path))
		XCTAssertNil(OwnedRuntimeDownloadedHelper.driverPackage(manifest: try manifest(name: "../x.pkg"), home: home.path))
	}

	func testTheDriverStepChecksDigestAndPqrsTeamBeforeTheInstaller() {
		let program = OwnedRuntimeInstallMainOperation.driverProgram(.init(path: "/Users/a/k.pkg", sha256: String(repeating: "b", count: 64), team: "G43BCU2T37"))
		let digest = program.range(of: "shasum -a 256")!, team = program.range(of: "(G43BCU2T37\\)$")!, install = program.range(of: "/usr/sbin/installer -pkg")!
		XCTAssertLessThan(digest.lowerBound, install.lowerBound)
		XCTAssertLessThan(team.lowerBound, install.lowerBound)
		XCTAssertTrue(program.contains("exit 78") && program.contains("exit 79"))
	}
}
