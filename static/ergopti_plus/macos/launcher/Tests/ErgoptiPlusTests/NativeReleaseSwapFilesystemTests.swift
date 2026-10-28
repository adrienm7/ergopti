// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NativeReleaseSwapFilesystemTests.swift
//
// Execute the actual release swap with real Darwin stat/mv and an owned HFS+ volume.
// The Python campaign controls only the GUI opener and explicit fault boundaries.

import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class NativeReleaseSwapFilesystemTests: XCTestCase {
	private static let operationDeadline: DispatchTimeInterval = .seconds(60)
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
			XCTFail("The exact release swap filesystem fixture handle did not retire")
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
				XCTFail("The exact release swap filesystem fixture child did not retire")
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

	private func nativeExecutable() throws -> URL {
		let directory = Bundle(for: NativeReleaseSwapFilesystemTests.self).bundleURL.deletingLastPathComponent()
		for candidate in [directory.appendingPathComponent("ErgoptiPlus"),
			directory.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")] {
			if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
		}
		XCTFail("The exact SwiftPM-built release rename launcher is unavailable")
		throw CocoaError(.executableNotLoadable)
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
			XCTAssertTrue(remaining.isEmpty, "The owned release swap image must be absent after retirement")
			return remaining.isEmpty && fixtureCanRetire
		} catch {
			XCTFail("The exact owned release swap image could not be retired")
			return false
		}
	}


	func testActualReleaseSwapRefusesConcurrentDestinationsAndSerializesBeforeArming() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiConcurrentRelease-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		var observerRetired = false
		defer {
			if fixtureCanRetire && observerRetired {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact concurrent release fixture did not retire") }
			}
		}
		let driver = Self.payloadURL.appendingPathComponent("macos")
		let probe = driver.appendingPathComponent("tests/support/release_swap_concurrent_probe.py")
		let executable = try nativeExecutable()
		let result = try run("/usr/bin/env", arguments: ["python3", "-B", probe.path,
			driver.path, root.appendingPathComponent("controls").path, "--native-launcher", executable.path], root: root)
		XCTAssertEqual(result.status, 0, "Every native concurrent publication contract must pass: \(String(decoding: result.output, as: UTF8.self)); \(result.stderr)")
		guard result.status == 0 else { throw CocoaError(.executableRuntimeMismatch) }
		observerRetired = true
		let report = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
		XCTAssertEqual(report["native_launcher"] as? String, executable.path)
		let cases = try XCTUnwrap(report["cases"] as? [[String: Any]])
		XCTAssertEqual(cases.compactMap { $0["name"] as? String },
			["backup", "publish", "rollback", "two-installers-before-arming"])
		for scenario in cases.prefix(3) {
			XCTAssertEqual(scenario["foreign_identity_preserved"] as? Bool, true)
			XCTAssertEqual(scenario["nested_source"] as? Bool, false)
		}
		let transaction = try XCTUnwrap(cases.last)
		XCTAssertEqual(transaction["original_restored"] as? Bool, true)
		XCTAssertEqual(transaction["second_candidate_preserved"] as? Bool, true)
	}

	func testActualReleaseSwapKeepsSameFilesystemPublicationAndSafeRollback() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiReleaseSwap-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		let mount = root.appendingPathComponent("external")
		let image = root.appendingPathComponent("external.dmg")
		var imageOperationAttempted = false
		var observerOwnershipUnproven = false
		defer {
			if fixtureCanRetire && !observerOwnershipUnproven {
				if imageOperationAttempted && !retireImage(image: image, mount: mount, root: root) {
					fixtureCanRetire = false
				}
				if fixtureCanRetire {
					do { try FileManager.default.removeItem(at: root) }
					catch { XCTFail("The exact release swap filesystem fixture did not retire") }
				}
			}
		}
		try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
		imageOperationAttempted = true
		// Blank images default to writable UDIF; -format belongs to source-backed creation.
		let created = try run("/usr/bin/hdiutil", arguments: ["create", "-size", "64m", "-fs", "HFS+", "-volname", "ErgoptiReleaseSwapFixture", image.path], root: root)
		XCTAssertEqual(created.status, 0, "The exact writable fixture image must be created: \(created.stderr)")
		guard created.status == 0 else { throw CocoaError(.executableRuntimeMismatch) }
		let attached = try run("/usr/bin/hdiutil", arguments: ["attach", "-nobrowse", "-mountpoint", mount.path, "-plist", image.path], root: root)
		XCTAssertEqual(attached.status, 0, "The exact fixture image must attach: \(attached.stderr)")
		guard attached.status == 0 else { throw CocoaError(.executableRuntimeMismatch) }
		let admission = try XCTUnwrap(PropertyListSerialization.propertyList(from: attached.output, format: nil) as? [String: Any])
		let entities = try XCTUnwrap(admission["system-entities"] as? [[String: Any]])
		let admitted = try devices(entities, mount: mount)
		let observed = try attachedDevices(image: image, mount: mount, root: root)
		XCTAssertEqual(observed, admitted, "The native inventory must identify the exact private mount")
		guard observed == admitted else {
			fixtureCanRetire = false
			throw CocoaError(.fileReadCorruptFile)
		}
		let values = try mount.resourceValues(forKeys: [.volumeIsReadOnlyKey])
		XCTAssertEqual(values.volumeIsReadOnly, false, "Cross-volume publication needs a genuinely writable external fixture")
		guard values.volumeIsReadOnly == false else { throw CocoaError(.fileReadCorruptFile) }
		try Data().write(to: mount.appendingPathComponent(".metadata_never_index"))
		let driver = Self.payloadURL.appendingPathComponent("macos")
		let source = driver.appendingPathComponent("modules/updater/release_installer.lua")
		let probe = driver.appendingPathComponent("tests/support/release_swap_physical_probe.py")
		let controls = root.appendingPathComponent("controls")
		// A failed observer may have left a descendant or stage: retain the image and root.
		observerOwnershipUnproven = true
		let result = try run("/usr/bin/env", arguments: ["python3", "-B", probe.path, "native", source.path, controls.path, mount.path, try nativeExecutable().path], root: root)
		XCTAssertEqual(result.status, 0, "Every physical swap contract must pass: \(String(decoding: result.output, as: UTF8.self)); \(result.stderr)")
		guard result.status == 0 else { throw CocoaError(.executableRuntimeMismatch) }
		let report = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
		XCTAssertEqual(report["platform"] as? String, "darwin")
		guard report["platform"] as? String == "darwin", report["native_stat"] as? Bool == true else {
			throw CocoaError(.fileReadCorruptFile)
		}
		XCTAssertEqual(report["native_stat"] as? Bool, true)
		let digest = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
		XCTAssertEqual(report["source_sha256"] as? String, digest, "The worker must qualify the exact shipped Lua source")
		let cases = try XCTUnwrap(report["cases"] as? [[String: Any]])
		let names = cases.compactMap { $0["name"] as? String }
		XCTAssertEqual(names.count, 10)
		XCTAssertEqual(Set(names), Set([
			"old-cross-device-copy-failure", "parent-stage-external-tmp", "foreign-device-before-arming",
			"occupied-publication-target", "publication-refusal-restores-original", "partial-publication-target",
			"device-observation-refused", "device-observation-invalid", "missing-candidate", "symlink-candidate"
		]))
		let healthy = try XCTUnwrap(cases.first { $0["name"] as? String == "parent-stage-external-tmp" })
		let stageDevice = try XCTUnwrap(healthy["stage_device"] as? NSNumber)
		let parentDevice = try XCTUnwrap(healthy["parent_device"] as? NSNumber)
		let temporaryDevice = try XCTUnwrap(healthy["temporary_device"] as? NSNumber)
		XCTAssertEqual(stageDevice, parentDevice)
		XCTAssertNotEqual(temporaryDevice, parentDevice)
		XCTAssertEqual(healthy["exit_code"] as? Int, 0)
		XCTAssertEqual(healthy["large_size"] as? Int, 8192)
		let historical = try XCTUnwrap(cases.first { $0["name"] as? String == "old-cross-device-copy-failure" })
		XCTAssertEqual(historical["exit_code"] as? Int, 6)
		XCTAssertEqual(historical["nested_previous_marker"] as? String, "installed")
		XCTAssertEqual(historical["large_size"] as? Int, 256)
		// The successful fail-closed ten-case probe returned after every exact child settled.
		observerOwnershipUnproven = false
	}
}
