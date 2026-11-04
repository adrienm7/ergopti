// Tests/ErgoptiPlusTests/OwnedRuntimeDownloadedHelperTests.swift
// The administrator install takes its helper from the verified download, never the bundle.
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

/// Pins OwnedRuntimeDownloadedHelper against the layout runtime_artifact_fetch.lua writes.
///
/// ROOT CAUSE ENCODED: the privileged install staged
/// `Contents/Resources/OwnedRuntimeInstaller/ErgoptiPlus-Runtime-Installer.app`, a copy no
/// download verified. The helper must be the payload of the pinned, digest-checked artifact,
/// and an absent download or a receipt of another artifact must be a named refusal.
final class OwnedRuntimeDownloadedHelperTests: XCTestCase {
	private let digest = String(repeating: "ab", count: 32)
	private let version = "16.3.0-ergopti.2"
	private var home: URL!

	override func setUpWithError() throws { home = try OwnedRuntimeFixtureDirectory.create() }
	override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

	private var pin: OwnedRuntimeDownloadedHelper.Pin { .init(version: version, sha256: digest) }
	private var folder: URL {
		home.appendingPathComponent(OwnedRuntimeDownloadedHelper.artifactHomeRelative).appendingPathComponent(version)
	}
	private var helper: URL { folder.appendingPathComponent("payload/ErgoptiPlus-Runtime-Installer.app") }

	private func manifest(version: Any = "16.3.0-ergopti.2", sha256: Any? = nil) throws -> Data {
		let runtime: [String: Any] = [
			"version": version,
			"file_name": "ErgoptiPlus-Remap-Runtime-16.3.0-ergopti.2.tar.gz",
			"source_url": "https://example.invalid/ErgoptiPlus-Remap-Runtime-16.3.0-ergopti.2.tar.gz",
			"sha256": sha256 ?? digest,
			"size": 4096,
		]
		return try JSONSerialization.data(withJSONObject: ["schema": 1, "runtime": runtime])
	}

	/// Writes what a completed Lua fetch leaves: the payload, then the receipt.
	private func keepDownload(receipt: String? = nil) throws {
		try FileManager.default.createDirectory(
			at: helper.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
		try Data((receipt ?? digest + "\n").utf8).write(to: folder.appendingPathComponent("receipt"))
	}

	private func refusal(_ result: Result<URL, OwnedRuntimeDownloadedHelper.Refusal>) -> OwnedRuntimeDownloadedHelper.Refusal? {
		if case .failure(let value) = result { return value }
		return nil
	}

	func testVerifiedDownloadGivesItsPayloadHelper() throws {
		try keepDownload()
		let located = try OwnedRuntimeDownloadedHelper.locate(pin: pin, home: home.path).get()
		XCTAssertEqual(located.standardizedFileURL.path, helper.standardizedFileURL.path)
		XCTAssertTrue(located.path.hasPrefix(home.path + "/Library/Application Support/ErgoptiPlus/RemapRuntime/" + version + "/payload/"))
		XCTAssertFalse(located.path.contains("OwnedRuntimeInstaller"))
	}

	func testAbsentDownloadIsNamedAndNeverFallsBackToTheBundle() {
		XCTAssertEqual(refusal(OwnedRuntimeDownloadedHelper.locate(pin: pin, home: home.path)), .downloadAbsent)
		XCTAssertEqual(OwnedRuntimeDownloadedHelper.Refusal.downloadAbsent.rawValue, "artifact_download_absent")
	}

	func testReceiptOfAnotherDigestIsRefused() throws {
		try keepDownload(receipt: String(repeating: "cd", count: 32) + "\n")
		XCTAssertEqual(refusal(OwnedRuntimeDownloadedHelper.locate(pin: pin, home: home.path)), .receiptMismatch)
	}

	func testReceiptMustBeExactlyTheDigestLine() throws {
		for receipt in [digest, digest + "\n\n", digest.uppercased() + "\n", digest + " extra\n", ""] {
			try keepDownload(receipt: receipt)
			XCTAssertEqual(refusal(OwnedRuntimeDownloadedHelper.locate(pin: pin, home: home.path)), .receiptMismatch, receipt)
		}
	}

	func testLinkedReceiptIsRefused() throws {
		try keepDownload()
		let real = home.appendingPathComponent("elsewhere-receipt")
		try Data((digest + "\n").utf8).write(to: real)
		try FileManager.default.removeItem(at: folder.appendingPathComponent("receipt"))
		try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("receipt"), withDestinationURL: real)
		XCTAssertEqual(refusal(OwnedRuntimeDownloadedHelper.locate(pin: pin, home: home.path)), .receiptMismatch)
	}

	func testReceiptWithoutHelperIsRefused() throws {
		try FileManager.default.createDirectory(at: folder.appendingPathComponent("payload"), withIntermediateDirectories: true)
		try Data((digest + "\n").utf8).write(to: folder.appendingPathComponent("receipt"))
		XCTAssertEqual(refusal(OwnedRuntimeDownloadedHelper.locate(pin: pin, home: home.path)), .helperAbsent)
	}

	func testLinkedHelperIsRefused() throws {
		let foreign = home.appendingPathComponent("Foreign.app/Contents/MacOS")
		try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: folder.appendingPathComponent("payload"), withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: home.appendingPathComponent("Foreign.app"))
		try Data((digest + "\n").utf8).write(to: folder.appendingPathComponent("receipt"))
		XCTAssertEqual(refusal(OwnedRuntimeDownloadedHelper.locate(pin: pin, home: home.path)), .helperAbsent)
	}

	func testPinIsReadFromTheManifest() throws {
		XCTAssertEqual(try OwnedRuntimeDownloadedHelper.pin(manifest: manifest()).get(), pin)
	}

	func testUnpinnedOrMalformedPinIsRefused() throws {
		let refusals: [(Data, OwnedRuntimeDownloadedHelper.Refusal)] = [
			(try manifest(version: NSNull()), .unpinned),
			(try manifest(sha256: NSNull()), .unpinned),
			(try manifest(version: ".."), .unpinned),
			(try manifest(version: "16.3.0/../x"), .unpinned),
			(try manifest(sha256: String(repeating: "AB", count: 32)), .unpinned),
			(try manifest(sha256: "ab"), .unpinned),
			(Data("{".utf8), .manifestUnreadable),
			(try JSONSerialization.data(withJSONObject: ["schema": 1]), .manifestUnreadable),
		]
		for (bytes, expected) in refusals {
			guard case .failure(let actual) = OwnedRuntimeDownloadedHelper.pin(manifest: bytes) else {
				return XCTFail("accepted " + String(decoding: bytes, as: UTF8.self))
			}
			XCTAssertEqual(actual, expected)
		}
	}

	func testCommittedManifestIsUnpinnedUntilTheHostedBuildPinsIt() throws {
		let driver = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent()
		let bytes = try Data(contentsOf: driver.appendingPathComponent(OwnedRuntimeDownloadedHelper.manifestRelative))
		switch OwnedRuntimeDownloadedHelper.pin(manifest: bytes) {
		case .failure(let refusal): XCTAssertEqual(refusal, .unpinned)
		case .success(let value):
			// Once pinned, the shape must be the one the Lua fetch keeps the download under.
			XCTAssertFalse(value.version.isEmpty); XCTAssertEqual(value.sha256.count, 64)
		}
	}

	func testDriverFolderManifestLeadsToTheKeptDownload() throws {
		let driver = home.appendingPathComponent("driver")
		let manifestURL = driver.appendingPathComponent(OwnedRuntimeDownloadedHelper.manifestRelative)
		try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		XCTAssertEqual(refusal(OwnedRuntimeDownloadedHelper.locate(configDir: driver.path, home: home.path)), .manifestUnreadable)
		try manifest().write(to: manifestURL)
		XCTAssertEqual(refusal(OwnedRuntimeDownloadedHelper.locate(configDir: driver.path, home: home.path)), .downloadAbsent)
		try keepDownload()
		XCTAssertEqual(try OwnedRuntimeDownloadedHelper.locate(configDir: driver.path, home: home.path).get().path, helper.path)
	}

	func testRelativeHomeIsRefused() {
		XCTAssertEqual(refusal(OwnedRuntimeDownloadedHelper.locate(pin: pin, home: "Users/test")), .accountUnavailable)
	}

	func testAdministratorInstallNoLongerStagesTheBundleCopy() throws {
		let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().appendingPathComponent("Sources/ErgoptiPlus/OwnedVirtualHIDDaemonReportMainOperation.swift")
		let text = try String(contentsOf: source, encoding: .utf8)
		XCTAssertFalse(text.contains("OwnedRuntimeInstaller/ErgoptiPlus-Runtime-Installer.app"))
		XCTAssertFalse(text.contains("Bundle.main.resourceURL"))
		XCTAssertTrue(text.contains("OwnedRuntimeDownloadedHelper.current()"))
	}
}
