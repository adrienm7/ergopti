// Tests/ErgoptiPlusTests/FieldRunRootTests.swift
// The installed app hands its Lua a field-run clone only when the collector named a real clone of this user.
import Foundation
import XCTest
@testable import ErgoptiPlus

final class FieldRunRootTests: XCTestCase {
	func testOnlyAnOwnCloneWithTheDeclarationReachesTheChild() throws {
		let clone = FileManager.default.temporaryDirectory.appendingPathComponent("field-run-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: clone) }
		let data = clone.appendingPathComponent("static/ergopti_plus/macos/onboarding")
		try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: clone.path)
		let key = Identifiers.FieldReport.environment
		let base = ["PATH": "/usr/bin", key: clone.path]
		XCTAssertNil(launcherChildEnvironment(base: base, launcherPid: 7, launcherBundleId: nil)[key], "no declaration yet")
		try Data("{}".utf8).write(to: data.appendingPathComponent("field_run.json"))
		XCTAssertEqual(launcherChildEnvironment(base: base, launcherPid: 7, launcherBundleId: nil)[key], clone.path)
		for bad in ["relative/path", clone.path + "/", clone.path + "/../" + clone.lastPathComponent, "/nonexistent-clone"] {
			XCTAssertNil(launcherChildEnvironment(base: ["PATH": "/usr/bin", key: bad], launcherPid: 7, launcherBundleId: nil)[key], bad)
		}
		try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: clone.path)
		XCTAssertNil(launcherChildEnvironment(base: base, launcherPid: 7, launcherBundleId: nil)[key], "a world-writable folder is refused")
		XCTAssertNil(launcherChildEnvironment(base: ["PATH": "/usr/bin"], launcherPid: 7, launcherBundleId: nil)[key])
	}
}
