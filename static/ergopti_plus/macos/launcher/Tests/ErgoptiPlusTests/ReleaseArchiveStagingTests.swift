// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ReleaseArchiveStagingTests.swift
//
// Executes the Versions installer's extraction owner with real macOS archive,
// digest, plist and signature tools. Only the download is replaced by a private
// copy of the independently built fixture; no installed app is changed or run.

import Foundation
import XCTest

final class ReleaseArchiveStagingTests: XCTestCase {
	private struct Receipt {
		let status: Int32
		let stdout: String
		let stderr: String
	}

	private enum FixtureError: Error {
		case timedOut(String)
		case toolFailure(String, Int32, String)
	}

	private var fixtureCanRetire = true
	private let manager = FileManager.default
	private let version = "1.2.3"
	private let bundleName = "ErgoptiPlus.app"
	private let ownedURL = "https://example.invalid/owned-release"

	private static var repositoryURL: URL {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { url.deleteLastPathComponent() }
		return url
	}

	private func quote(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}

	/// A file-backed capture cannot deadlock on native signature diagnostics.
	/// On a deadline failure, retain the fixture instead of deleting live inputs.
	private func child(_ executable: String, _ arguments: [String], root: URL) throws -> Receipt {
		let identity = UUID().uuidString
		let outputURL = root.appendingPathComponent(identity + ".stdout")
		let errorURL = root.appendingPathComponent(identity + ".stderr")
		XCTAssertTrue(manager.createFile(atPath: outputURL.path, contents: nil))
		XCTAssertTrue(manager.createFile(atPath: errorURL.path, contents: nil))
		let output = try FileHandle(forWritingTo: outputURL)
		let errors = try FileHandle(forWritingTo: errorURL)
		defer { try? output.close(); try? errors.close() }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments
		process.environment = NativeFixtureChildEnvironment.make()
		process.standardOutput = output
		process.standardError = errors
		let completed = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in completed.signal() }
		try process.run()
		guard completed.wait(timeout: .now() + 30) == .success else {
			fixtureCanRetire = false
			if process.isRunning { process.terminate() }
			XCTAssertEqual(completed.wait(timeout: .now() + 5), .success,
				"The exact archive child must physically retire")
			throw FixtureError.timedOut(executable)
		}
		XCTAssertFalse(process.isRunning)
		XCTAssertEqual(process.terminationReason, .exit)
		return Receipt(status: process.terminationStatus,
			stdout: try String(contentsOf: outputURL, encoding: .utf8),
			stderr: try String(contentsOf: errorURL, encoding: .utf8))
	}

	/// Only this owned fixture's display packet is eligible for diagnostics.
	/// Escape control characters and cap each stream independently; never read
	/// another process, an environment value or a signing-key payload.
	private func requirementDisplayEvidence(_ receipt: Receipt) -> String {
		func stream(_ label: String, _ value: String) -> String {
			let bytes = Array(value.utf8)
			let retained = String(decoding: bytes.prefix(2048), as: UTF8.self)
			return "\(label)_bytes=\(bytes.count) \(label)_truncated=\(bytes.count > 2048) \(label)=\(String(reflecting: retained))"
		}
		return "native_requirement_display status=\(receipt.status) "
			+ stream("stdout", receipt.stdout) + " " + stream("stderr", receipt.stderr)
	}

	private func successful(_ executable: String, _ arguments: [String], root: URL) throws -> Receipt {
		let result = try child(executable, arguments, root: root)
		guard result.status == 0 else {
			throw FixtureError.toolFailure(executable, result.status, result.stdout + result.stderr)
		}
		return result
	}

	private func scratch() throws -> URL {
		let root = manager.temporaryDirectory.appendingPathComponent("ErgoptiReleaseArchives-" + UUID().uuidString)
		try manager.createDirectory(at: root, withIntermediateDirectories: false)
		return root
	}

	private func retire(_ root: URL) {
		guard fixtureCanRetire else { return }
		do { try manager.removeItem(at: root) }
		catch { XCTFail("The owned archive fixture could not retire: \(error)") }
	}

	/// A real signed bundle is essential: faking codesign would miss loss of
	/// executability, resource bytes or symlink layout during native extraction.
	private func signedBundle(root: URL, identifier: String = "com.ergopti.release-staging-fixture") throws -> URL {
		let app = root.appendingPathComponent(bundleName)
		let executable = app.appendingPathComponent("Contents/MacOS/OwnedFixture")
		let resources = app.appendingPathComponent("Contents/Resources")
		try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
		try manager.createDirectory(at: resources, withIntermediateDirectories: true)
		try manager.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
		try manager.setAttributes([.posixPermissions: 0o751], ofItemAtPath: executable.path)
		try Data("Independent Unicode bytes: café 😀\n".utf8).write(to: resources.appendingPathComponent("données.txt"))
		try manager.createSymbolicLink(atPath: resources.appendingPathComponent("owned-link").path,
			withDestinationPath: "données.txt")
		let plist: [String: Any] = [
			"CFBundleIdentifier": identifier,
			"CFBundleName": "Owned archive fixture",
			"CFBundleExecutable": "OwnedFixture",
			"CFBundlePackageType": "APPL",
			"CFBundleShortVersionString": version,
			"CFBundleVersion": "123",
		]
		try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
			.write(to: app.appendingPathComponent("Contents/Info.plist"))
		_ = try successful("/usr/bin/xattr", ["-w", "com.ergopti.owned-fixture", "owned-metadata", resources.appendingPathComponent("données.txt").path], root: root)
		_ = try successful("/usr/bin/codesign", ["--force", "--sign", "-", app.path], root: root)
		let verified = try successful("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], root: root)
		XCTAssertTrue(verified.stderr.isEmpty)
		return app
	}

	private func archive(_ format: String, app: URL, root: URL) throws -> URL {
		let output = root.appendingPathComponent("produced-" + UUID().uuidString)
		try manager.createDirectory(at: output, withIntermediateDirectories: false)
		let owner = Self.repositoryURL.appendingPathComponent("tools/build/macos-release-archives.cjs")
		let produced = try successful("/usr/bin/env", ["node", owner.path, app.path, output.path], root: root)
		XCTAssertEqual(produced.stdout,
			"Created ErgoptiPlus.app.tar.xz\nCreated ErgoptiPlus.app.zip\n",
			"The actual producer emits both canonical names after native readback verification")
		XCTAssertTrue(produced.stderr.isEmpty, produced.stderr)
		XCTAssertTrue(manager.fileExists(atPath: output.appendingPathComponent("ErgoptiPlus.app.zip").path))
		XCTAssertTrue(manager.fileExists(atPath: output.appendingPathComponent("ErgoptiPlus.app.tar.xz").path))
		return output.appendingPathComponent(format == "zip" ? "ErgoptiPlus.app.zip" : "ErgoptiPlus.app.tar.xz")
	}

	private func digest(_ payload: URL, root: URL) throws -> String {
		let result = try successful("/usr/bin/shasum", ["-a", "256", payload.path], root: root)
		let value = String(result.stdout.prefix(64))
		XCTAssertEqual(value.count, 64)
		XCTAssertTrue(value.allSatisfy { "0123456789abcdef".contains($0) })
		XCTAssertTrue(result.stderr.isEmpty)
		return value
	}

	private func stage(payload: URL, format: String, digest: String, running: URL,
		expectedVersion: String, root: URL) throws -> (Receipt, URL, URL) {
		let stage = root.appendingPathComponent("stage-" + UUID().uuidString)
		let calls = root.appendingPathComponent("download-" + UUID().uuidString)
		let copier = root.appendingPathComponent("curl-" + UUID().uuidString)
		// The fixture seam accepts only the production download's exact argument
		// contract and URL. Digest/extraction/version/signature remain real tools.
		try """
		#!/bin/sh
		[ "$#" -eq 13 ] || exit 90
		[ "$1" = --fail ] && [ "$2" = --location ] && [ "$3" = --silent ] && [ "$4" = --show-error ] || exit 91
		[ "$5" = --proto ] && [ "$6" = '=https' ] && [ "$7" = --proto-redir ] && [ "$8" = '=https' ] || exit 92
		[ "$9" = --max-time ] && [ "${10}" = 900 ] && [ "${11}" = --output ] && [ "${13}" = \(quote(ownedURL)) ] || exit 93
		printf 'owned-download\\n' >> \(quote(calls.path))
		/bin/cp \(quote(payload.path)) "${12}"
		""".write(to: copier, atomically: true, encoding: .utf8)
		try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: copier.path)
		let owner = Self.repositoryURL.appendingPathComponent("static/ergopti_plus/macos/adapters/release_stage.sh")
		let original = try String(contentsOf: owner, encoding: .utf8)
		XCTAssertEqual(original.components(separatedBy: "/usr/bin/curl").count, 2, "Only the owned network call is replaced")
		let script = original.replacingOccurrences(of: "/usr/bin/curl", with: quote(copier.path))
		let result = try child("/bin/sh", ["-c", script, "stage", ownedURL, digest, stage.path,
			expectedVersion, running.path, format, bundleName], root: root)
		return (result, stage, calls)
	}

	func testBothNativeArchivesKeepSignedBundleBytesModesSymlinksAndMetadata() throws {
		let root = try scratch()
		defer { retire(root) }
		let app = try signedBundle(root: root)
		for format in ["zip", "tar.xz"] {
			let payload = try archive(format, app: app, root: root)
			let (result, directory, calls) = try stage(payload: payload, format: format,
				digest: digest(payload, root: root), running: app, expectedVersion: version, root: root)
			let extracted = directory.appendingPathComponent("app/" + bundleName)
			XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
			XCTAssertEqual(result.stdout, "READY " + extracted.path + "\n")
			XCTAssertTrue(result.stderr.isEmpty, result.stderr)
			XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "owned-download\n")
			XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("Contents/Resources/données.txt")),
				Data("Independent Unicode bytes: café 😀\n".utf8))
			let attributes = try manager.attributesOfItem(atPath: extracted.appendingPathComponent("Contents/MacOS/OwnedFixture").path)
			XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o751)
			XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: extracted.appendingPathComponent("Contents/Resources/owned-link").path), "données.txt")
			let metadata = try successful("/usr/bin/xattr", ["-p", "com.ergopti.owned-fixture", extracted.appendingPathComponent("Contents/Resources/données.txt").path], root: root)
			XCTAssertEqual(metadata.stdout, "owned-metadata\n")
			XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Contents/Resources/données.txt")),
				Data("Independent Unicode bytes: café 😀\n".utf8), "Staging leaves the running source untouched")
		}
	}

	func testPreferredArchiveChecksRejectDigestVersionCorruptionAndUnknownFormat() throws {
		let root = try scratch()
		defer { retire(root) }
		let app = try signedBundle(root: root)
		let payload = try archive("tar.xz", app: app, root: root)
		let checksum = try digest(payload, root: root)
		let (badDigest, rejected, _) = try stage(payload: payload, format: "tar.xz",
			digest: String(repeating: "0", count: 64), running: app, expectedVersion: version, root: root)
		XCTAssertEqual(badDigest.status, 21)
		XCTAssertFalse(manager.fileExists(atPath: rejected.appendingPathComponent("app").path))
		XCTAssertFalse(badDigest.stdout.contains("READY"))
		let (badVersion, _, _) = try stage(payload: payload, format: "tar.xz",
			digest: checksum, running: app, expectedVersion: "9.9.9", root: root)
		XCTAssertEqual(badVersion.status, 25)
		XCTAssertFalse(badVersion.stdout.contains("READY"))
		let (unknown, _, calls) = try stage(payload: payload, format: "unowned",
			digest: checksum, running: app, expectedVersion: version, root: root)
		XCTAssertEqual(unknown.status, 20)
		XCTAssertTrue(unknown.stdout.isEmpty)
		XCTAssertTrue(unknown.stderr.isEmpty)
		XCTAssertFalse(manager.fileExists(atPath: calls.path), "Unknown formats do not acquire download work")
		let foreignRoot = root.appendingPathComponent("foreign-identity")
		try manager.createDirectory(at: foreignRoot, withIntermediateDirectories: false)
		let foreign = try signedBundle(root: foreignRoot, identifier: "com.ergopti.foreign-staging-fixture")
		let foreignPayload = try archive("tar.xz", app: foreign, root: foreignRoot)
		let (foreignIdentity, _, _) = try stage(payload: foreignPayload, format: "tar.xz",
			digest: digest(foreignPayload, root: root), running: app, expectedVersion: version, root: root)
		XCTAssertEqual(foreignIdentity.status, 27, "A valid foreign signature cannot replace the running identity")
		XCTAssertFalse(foreignIdentity.stdout.contains("READY"))
		try Data("Corrupted signed resource\n".utf8).write(to: app.appendingPathComponent("Contents/Resources/données.txt"))
		let broken = root.appendingPathComponent("corrupted-resource.tar.xz")
		_ = try successful("/usr/bin/tar", ["-cJf", broken.path, "-C", app.deletingLastPathComponent().path, app.lastPathComponent], root: root)
		let (signature, _, _) = try stage(payload: broken, format: "tar.xz",
			digest: digest(broken, root: root), running: app, expectedVersion: version, root: root)
		XCTAssertEqual(signature.status, 27)
		XCTAssertFalse(signature.stdout.contains("READY"))
		let malformed = root.appendingPathComponent("malformed.tar.xz")
		try Data("Not an XZ archive\n".utf8).write(to: malformed)
		let (extract, _, _) = try stage(payload: malformed, format: "tar.xz",
			digest: digest(malformed, root: root), running: app, expectedVersion: version, root: root)
		XCTAssertEqual(extract.status, 22)
		XCTAssertFalse(extract.stdout.contains("READY"))
	}
	func testPrivateArchiveChildEnvironmentPreservesParentAndExecutableSearchPath() throws {
		let inherited = ProcessInfo.processInfo.environment
		let inheritedPath = try XCTUnwrap(inherited["PATH"])
		let root = try scratch()
		defer { retire(root) }
		let backtrace = try successful("/usr/bin/printenv", ["SWIFT_BACKTRACE"], root: root)
		XCTAssertEqual(backtrace.stdout, "enable=no\n")
		XCTAssertTrue(backtrace.stderr.isEmpty)
		let path = try successful("/usr/bin/printenv", ["PATH"], root: root)
		XCTAssertEqual(path.stdout, inheritedPath + "\n")
		XCTAssertTrue(path.stderr.isEmpty)
		XCTAssertEqual(ProcessInfo.processInfo.environment["SWIFT_BACKTRACE"], inherited["SWIFT_BACKTRACE"])
	}

	func testRequirementDisplayEvidenceRetainsBoundedEscapedOwnedStreams() {
		let exact = requirementDisplayEvidence(Receipt(status: 26,
			stdout: "Owned output\n\"quoted\"", stderr: "Owned error\tpacket"))
		XCTAssertTrue(exact.hasPrefix("native_requirement_display status=26 "))
		XCTAssertTrue(exact.contains("stdout_bytes=21 stdout_truncated=false"))
		XCTAssertTrue(exact.contains("stderr_bytes=18 stderr_truncated=false"))
		XCTAssertTrue(exact.contains("Owned output\\n\\\"quoted\\\""))
		XCTAssertTrue(exact.contains("Owned error\\tpacket"))
		XCTAssertFalse(exact.contains("\n"))
		XCTAssertFalse(exact.contains("\t"))
		let bounded = requirementDisplayEvidence(Receipt(status: 0,
			stdout: String(repeating: "a", count: 2048) + "STDOUT_AFTER_BOUND",
			stderr: String(repeating: "b", count: 2048) + "STDERR_AFTER_BOUND"))
		XCTAssertTrue(bounded.contains("stdout_bytes=2066 stdout_truncated=true"))
		XCTAssertTrue(bounded.contains("stderr_bytes=2066 stderr_truncated=true"))
		XCTAssertTrue(bounded.contains(String(repeating: "a", count: 2048)))
		XCTAssertTrue(bounded.contains(String(repeating: "b", count: 2048)))
		XCTAssertFalse(bounded.contains("STDOUT_AFTER_BOUND"))
		XCTAssertFalse(bounded.contains("STDERR_AFTER_BOUND"))
	}

	func testActualNativeRequirementDisplayKeepsBothStreamsAndExitStatus() throws {
		let root = try scratch()
		defer { retire(root) }
		let app = try signedBundle(root: root)
		let display = try child("/usr/bin/codesign", ["-d", "-r-", app.path], root: root)
		let evidence = requirementDisplayEvidence(display)
		XCTAssertEqual(display.status, 0, evidence)
		let declarations = (display.stdout + "\n" + display.stderr)
			.split(separator: "\n").map { line in
				line.hasPrefix("# designated => ") ? line.dropFirst(2) : line
			}.filter { $0.hasPrefix("designated => ") }
		XCTAssertEqual(declarations.count, 1, "The actual running signature owns one designated requirement; " + evidence)
		XCTAssertFalse(try XCTUnwrap(declarations.first).dropFirst("designated => ".count).isEmpty)
		let ownedRequirement = String(try XCTUnwrap(declarations.first).dropFirst("designated => ".count))
		let verifiedOwner = try child("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R",
			"=" + ownedRequirement, app.path], root: root)
		XCTAssertEqual(verifiedOwner.status, 0, "The parsed native requirement must match its actual signed source")
		XCTAssertTrue(verifiedOwner.stdout.isEmpty)
		XCTAssertTrue(verifiedOwner.stderr.isEmpty)
		let missing = root.appendingPathComponent("unsigned-source.app")
		try manager.createDirectory(at: missing, withIntermediateDirectories: false)
		let refused = try child("/usr/bin/codesign", ["-d", "-r-", missing.path], root: root)
		XCTAssertNotEqual(refused.status, 0, "A display failure cannot authorize staged verification")
	}


	func testCIInstallSelectsDeclaredArchiveAndPreservesIndependentSignedSource() throws {
		let root = try scratch()
		defer { retire(root) }
		let app = try signedBundle(root: root)
		let owner = Self.repositoryURL.appendingPathComponent("tools/build/macos-release-archives.cjs")
		for format in ["tar.xz", "zip"] {
			let payload = try archive(format, app: app, root: root)
			let input = payload.deletingLastPathComponent()
			if format == "zip" {
				try manager.removeItem(at: input.appendingPathComponent("ErgoptiPlus.app.tar.xz"))
			}
			let source = try successful("/usr/bin/env", ["node", owner.path, "--ci-receipt", app.path, input.path], root: root)
			XCTAssertTrue(source.stdout.isEmpty)
			XCTAssertTrue(source.stderr.isEmpty)
			let sourcePacket = try XCTUnwrap(try JSONSerialization.jsonObject(with:
				Data(contentsOf: input.appendingPathComponent("ErgoptiPlus.app.ci-receipt.json"))) as? [String: Any])
			let requirement = try XCTUnwrap(sourcePacket["requirement"] as? String)
			XCTAssertFalse(requirement.isEmpty)
			let output = root.appendingPathComponent("ci-install-" + UUID().uuidString)
			try manager.createDirectory(at: output, withIntermediateDirectories: false)
			let result = try successful("/usr/bin/env", ["node", owner.path, "--ci-install", input.path, output.path], root: root)
			XCTAssertTrue(result.stderr.isEmpty)
			let packet = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
			XCTAssertEqual(packet["format"] as? String, format)
			let retained = URL(fileURLWithPath: try XCTUnwrap(packet["archive"] as? String))
			XCTAssertEqual(try Data(contentsOf: retained), try Data(contentsOf: payload))
			XCTAssertEqual(packet["sha256"] as? String, try digest(retained, root: root))
			let installed = output.appendingPathComponent(bundleName)
			let verification = try successful("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + requirement, installed.path], root: root)
			XCTAssertTrue(verification.stdout.isEmpty)
			XCTAssertTrue(verification.stderr.isEmpty)
			XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("Contents/Resources/données.txt")),
				Data("Independent Unicode bytes: café 😀\n".utf8))
			let attributes = try manager.attributesOfItem(atPath: installed.appendingPathComponent("Contents/MacOS/OwnedFixture").path)
			XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o751)
			XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: installed.appendingPathComponent("Contents/Resources/owned-link").path), "données.txt")
			let metadata = try successful("/usr/bin/xattr", ["-p", "com.ergopti.owned-fixture", installed.appendingPathComponent("Contents/Resources/données.txt").path], root: root)
			XCTAssertEqual(metadata.stdout, "owned-metadata\n")
			XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Contents/Resources/données.txt")),
				Data("Independent Unicode bytes: café 😀\n".utf8))
		}
	}

	func testCIPreferredArchiveNeverFallsBackAfterDigestExtractionOrSignatureRefusal() throws {
		let root = try scratch()
		defer { retire(root) }
		let app = try signedBundle(root: root)
		let owner = Self.repositoryURL.appendingPathComponent("tools/build/macos-release-archives.cjs")
		for refusal in ["digest", "extract", "signature"] {
			let payload = try archive("tar.xz", app: app, root: root)
			let input = payload.deletingLastPathComponent()
			if refusal == "extract" { try Data("Not a native XZ archive\n".utf8).write(to: payload) }
			_ = try successful("/usr/bin/env", ["node", owner.path, "--ci-receipt", app.path, input.path], root: root)
			if refusal == "digest" { try Data("Different archive bytes\n".utf8).write(to: payload) }
			if refusal == "signature" {
				let receipt = input.appendingPathComponent("ErgoptiPlus.app.ci-receipt.json")
				var packet = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
				packet["requirement"] = "identifier \"com.ergopti.foreign-staging-fixture\""
				try JSONSerialization.data(withJSONObject: packet).write(to: receipt)
			}
			let output = root.appendingPathComponent("ci-refusal-" + UUID().uuidString)
			try manager.createDirectory(at: output, withIntermediateDirectories: false)
			let result = try child("/usr/bin/env", ["node", owner.path, "--ci-install", input.path, output.path], root: root)
			XCTAssertNotEqual(result.status, 0)
			XCTAssertTrue(result.stdout.isEmpty)
			XCTAssertFalse(manager.fileExists(atPath: output.appendingPathComponent(bundleName).path))
			XCTAssertTrue(manager.fileExists(atPath: input.appendingPathComponent("ErgoptiPlus.app.zip").path),
				"A usable compatibility ZIP cannot turn a refused preferred archive into success")
			XCTAssertFalse(try manager.contentsOfDirectory(atPath: input.path).contains { $0.hasPrefix(".ci-install-") })
		}
	}
}
