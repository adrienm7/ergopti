// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NativeAppClonerReadOnlyBundleTests.swift
//
// Executes the shipped post-wizard admission against an actual read-only volume.
// The helper is fixture-owned and prints a marker; no application is cloned.

import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class NativeAppClonerReadOnlyBundleTests: XCTestCase {
	private static let operationDeadline: DispatchTimeInterval = .seconds(15)
	private static let retirementDeadline: DispatchTimeInterval = .seconds(5)
	private var fixtureCanRetire = true

	private static var payloadURL: URL {
		var root = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { root.deleteLastPathComponent() }
		return root.appendingPathComponent("static/ergopti_plus")
	}

	private struct NativeResult {
		let status: Int32
		let output: Data
		let stderr: String
	}

	private func retire(_ handle: FileHandle) {
		do { try handle.close() }
		catch {
			fixtureCanRetire = false
			XCTFail("The exact read-only bundle fixture handle did not retire")
		}
	}

	private func run(_ executable: String, arguments: [String], root: URL) throws -> NativeResult {
		let outputURL = root.appendingPathComponent(UUID().uuidString + ".stdout")
		let errorURL = root.appendingPathComponent(UUID().uuidString + ".stderr")
		XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]))
		XCTAssertTrue(FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]))
		let output = try FileHandle(forWritingTo: outputURL)
		defer { retire(output) }
		let errors = try FileHandle(forWritingTo: errorURL)
		defer { retire(errors) }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments
		var environment = NativeFixtureChildEnvironment.make()
		environment["LC_ALL"] = "C"
		process.environment = environment
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = errors
		let completed = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in completed.signal() }
		try process.run()
		guard completed.wait(timeout: .now() + Self.operationDeadline) == .success else {
			// A timed-out image operation can leave service-side ownership unknown
			// even after its CLI exits. Preserve the fixture instead of deleting it.
			fixtureCanRetire = false
			if process.isRunning { process.terminate() }
			if completed.wait(timeout: .now() + Self.retirementDeadline) != .success {
				XCTFail("The exact read-only bundle fixture child did not retire")
			}
			throw CocoaError(.executableRuntimeMismatch)
		}
		XCTAssertEqual(process.terminationReason, .exit)
		guard process.terminationReason == .exit else {
			fixtureCanRetire = false
			throw CocoaError(.executableRuntimeMismatch)
		}
		return NativeResult(status: process.terminationStatus, output: try Data(contentsOf: outputURL),
			stderr: try String(contentsOf: errorURL, encoding: .utf8))
	}

	private func canonical(_ path: String) -> String {
		URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
	}

	private func devices(_ entities: [[String: Any]], mount: URL) throws -> [String] {
		var mountpoints: [String] = []
		var devicePaths: [String] = []
		for entity in entities {
			guard let device = entity["dev-entry"] as? String, !device.isEmpty else {
				XCTFail("Every owned image entity must identify its native device")
				throw CocoaError(.fileReadCorruptFile)
			}
			devicePaths.append(device)
			if let value = entity["mount-point"] {
				guard let point = value as? String, !point.isEmpty else {
					XCTFail("A returned mount identity must be a nonempty native path")
					throw CocoaError(.fileReadCorruptFile)
				}
				mountpoints.append(point)
			}
		}
		let ownsMountpoints = mountpoints.allSatisfy({ canonical($0) == canonical(mount.path) })
		XCTAssertTrue(ownsMountpoints, "Every returned mount must be the exact private fixture mount")
		guard ownsMountpoints else {
			throw CocoaError(.fileReadCorruptFile)
		}
		let devices = devicePaths.filter {
			$0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
		}
		XCTAssertEqual(devices.count, 1, "The exact owned image must identify one root device")
		guard devices.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
		return devices
	}

	private func attachedDevices(image: URL, mount: URL, root: URL) throws -> [String] {
		let result = try run("/usr/bin/hdiutil", arguments: ["info", "-plist"], root: root)
		XCTAssertEqual(result.status, 0, "The owned image retirement query must execute: \(result.stderr)")
		guard result.status == 0 else { throw CocoaError(.executableRuntimeMismatch) }
		let information = try XCTUnwrap(PropertyListSerialization.propertyList(from: result.output, format: nil) as? [String: Any])
		let images = try XCTUnwrap(information["images"] as? [[String: Any]])
		var resultDevices: [String] = []
		for entry in images {
			guard let path = entry["image-path"] as? String, !path.isEmpty else {
				XCTFail("Every image information entry must identify its source path")
				throw CocoaError(.fileReadCorruptFile)
			}
			guard canonical(path) == canonical(image.path) else { continue }
			let entities = try XCTUnwrap(entry["system-entities"] as? [[String: Any]])
			resultDevices.append(contentsOf: try devices(entities, mount: mount))
		}
		return resultDevices
	}

	private func retireImage(image: URL, mount: URL, root: URL) -> Bool {
		do {
			// The image path is private and created by this test. Querying it also
			// recovers an attachment if the attach command's plist was incomplete.
			for device in try attachedDevices(image: image, mount: mount, root: root) {
				let detached = try run("/usr/bin/hdiutil", arguments: ["detach", device], root: root)
				XCTAssertEqual(detached.status, 0, "Only the exact owned image may retire: \(detached.stderr)")
				guard detached.status == 0 else { return false }
			}
			let remaining = try attachedDevices(image: image, mount: mount, root: root)
			XCTAssertTrue(remaining.isEmpty, "The owned read-only image must be absent after retirement")
			return remaining.isEmpty && fixtureCanRetire
		} catch {
			XCTFail("The exact owned read-only image could not be retired")
			return false
		}
	}

	private func withReadOnlyHelpers(_ body: (URL, URL, URL) throws -> Void) throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiClonerReadOnly-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		let source = root.appendingPathComponent("source")
		let mount = root.appendingPathComponent("mount")
		let image = root.appendingPathComponent("helpers.dmg")
		var imageOperationAttempted = false
		defer {
			if fixtureCanRetire {
				if imageOperationAttempted && !retireImage(image: image, mount: mount, root: root) {
					fixtureCanRetire = false
				}
				if fixtureCanRetire {
					do { try FileManager.default.removeItem(at: root) }
					catch { XCTFail("The exact read-only bundle fixture directory did not retire") }
				}
			}
		}
		try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
		try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
		// Do not invite an unrelated indexer to retain a descriptor on this volume.
		try Data().write(to: source.appendingPathComponent(".metadata_never_index"))
		let helperName = "clone 'helper'.sh"
		let deniedName = "not executable.sh"
		let program = "#!/bin/sh\nprintf 'readonly-cloner-helper\\n'\n"
		for (name, permissions) in [(helperName, 0o755), (deniedName, 0o644)] {
			let helper = source.appendingPathComponent(name)
			try program.write(to: helper, atomically: true, encoding: .utf8)
			try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: helper.path)
		}
		imageOperationAttempted = true
		let created = try run("/usr/bin/hdiutil", arguments: ["create", "-srcfolder", source.path, "-format", "UDRO", "-fs", "HFS+", "-volname", "ErgoptiClonerFixture", image.path], root: root)
		XCTAssertEqual(created.status, 0, "The owned read-only image must be created: \(created.stderr)")
		guard created.status == 0 else { throw CocoaError(.executableRuntimeMismatch) }
		let attached = try run("/usr/bin/hdiutil", arguments: ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, "-plist", image.path], root: root)
		XCTAssertEqual(attached.status, 0, "The owned image must attach read-only: \(attached.stderr)")
		guard attached.status == 0 else { throw CocoaError(.executableRuntimeMismatch) }
		let admission = try XCTUnwrap(PropertyListSerialization.propertyList(from: attached.output, format: nil) as? [String: Any])
		let entities = try XCTUnwrap(admission["system-entities"] as? [[String: Any]])
		let admitted = try devices(entities, mount: mount)
		let observed = try attachedDevices(image: image, mount: mount, root: root)
		XCTAssertEqual(observed, admitted, "The complete native inventory must see the exact admitted image")
		guard observed == admitted else {
			fixtureCanRetire = false
			throw CocoaError(.fileReadCorruptFile)
		}
		let values = try mount.resourceValues(forKeys: [.volumeIsReadOnlyKey])
		XCTAssertEqual(values.volumeIsReadOnly, true, "The admission must execute on an actual read-only filesystem")
		guard values.volumeIsReadOnly == true else { throw CocoaError(.fileReadCorruptFile) }
		let helper = mount.appendingPathComponent(helperName)
		XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
		try body(helper, mount.appendingPathComponent(deniedName), root)
	}

	private func actualAdmission() throws -> String {
		let script = Self.payloadURL.appendingPathComponent("macos/apps/App Cloner.app/Contents/Resources/ShortcutBuilder.applescript")
		let actual = try String(contentsOf: script, encoding: .utf8)
		let start = try XCTUnwrap(actual.range(of: "\tlogmsg(\"openArg: "))
		let end = try XCTUnwrap(actual.range(of: "\tset pwaArg to \"0\""))
		guard start.upperBound < end.lowerBound else { throw CocoaError(.fileReadCorruptFile) }
		let expression = try NSRegularExpression(pattern: #"(?m)^\t(do shell script [^\n]+quoted form of cloneScript)$"#)
		let matches = expression.matches(in: actual, range: NSRange(start.upperBound..<end.lowerBound, in: actual))
		XCTAssertEqual(matches.count, 1, "Execute the one actual post-wizard helper admission")
		guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: actual) else { throw CocoaError(.fileReadCorruptFile) }
		return String(actual[range])
	}

	private func executeAdmission(_ statement: String, helper: URL, root: URL) throws -> NativeResult {
		let program = """
		use scripting additions
		on run argv
			set cloneScript to item 1 of argv
			try
				\(statement)
			on error refusal_message number refusal_number
				error ("CLONER_ADMISSION_REFUSED:" & (refusal_number as text) & ":" & refusal_message) number refusal_number
			end try
			return do shell script quoted form of cloneScript
		end run
		"""
		return try run("/usr/bin/osascript", arguments: ["-e", program, "--", helper.path], root: root)
	}

	func testActualAdmissionExecutesReadOnlyHelperAndRejectsOldMutation() throws {
		let admission = try actualAdmission()
		try withReadOnlyHelpers { helper, _, root in
			let original = try Data(contentsOf: helper)
			let allowed = try executeAdmission(admission, helper: helper, root: root)
			XCTAssertEqual(allowed.status, 0, "The actual admission must accept an executable signed resource: \(allowed.stderr)")
			XCTAssertTrue(allowed.stderr.isEmpty)
			XCTAssertEqual(String(decoding: allowed.output, as: UTF8.self), "readonly-cloner-helper\n")
			XCTAssertEqual(try Data(contentsOf: helper), original)
			let (mutation, mutationError) = helper.path.withCString { path in
				let result = Darwin.chmod(path, mode_t(0o755))
				return (result, errno)
			}
			XCTAssertEqual(mutation, -1)
			XCTAssertTrue(mutationError == EROFS || mutationError == EPERM, "The real kernel must refuse metadata mutation on this fixture")
			let old = try executeAdmission("do shell script \"chmod +x \" & quoted form of cloneScript", helper: helper, root: root)
			XCTAssertNotEqual(old.status, 0)
			XCTAssertTrue(old.stderr.contains("CLONER_ADMISSION_REFUSED:1:"), "The old command must fail at runtime, not parsing: \(old.stderr)")
			XCTAssertTrue(old.stderr.contains("Read-only file system") || old.stderr.contains("Operation not permitted"), "Require the native metadata refusal rather than an unrelated command failure")
			XCTAssertTrue(old.output.isEmpty)
			XCTAssertEqual(try Data(contentsOf: helper), original)
		}
	}

	func testActualAdmissionRefusesMissingAndNonExecutableHelpers() throws {
		let admission = try actualAdmission()
		try withReadOnlyHelpers { helper, denied, root in
			let missing = helper.deletingLastPathComponent().appendingPathComponent("missing helper.sh")
			XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
			XCTAssertTrue(FileManager.default.fileExists(atPath: denied.path))
			XCTAssertEqual(try Data(contentsOf: denied), try Data(contentsOf: helper))
			XCTAssertFalse(FileManager.default.isExecutableFile(atPath: denied.path))
			for candidate in [missing, denied] {
				let refused = try executeAdmission(admission, helper: candidate, root: root)
				XCTAssertNotEqual(refused.status, 0)
				XCTAssertTrue(refused.stderr.contains("CLONER_ADMISSION_REFUSED:1:"), "Reject the actual helper before dispatch: \(refused.stderr)")
				XCTAssertTrue(refused.output.isEmpty)
			}
		}
	}
}
