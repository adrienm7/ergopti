// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift
//
// Actual Sparkle updates target a separately compiled private application.
// XCTest, product installations, public feeds and the login Keychain stay outside
// the fixture. No native prerequisite is replaced with a stub or a skip.

import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Sparkle
import XCTest

final class SparkleArchiveUpdateAcceptanceTests: XCTestCase {
	private enum NativeCommandPhase: String {
		case nativeTool = "native-tool"
		case archiveBuild = "archive-build"
		case archiveSign = "archive-sign"
		case archiveSignForeign = "archive-sign-foreign"
		case generatedAppcast = "generated-appcast"
		case nativeProcessCensus = "native-process-census"
	}

	private enum Failure: Error {
		case prerequisite(String)
		case command(NativeCommandPhase, Int32)
		case deadline(String)
		case evidence(String)
	}

	private var phaseEvidence: ArchiveAcceptanceEvidence?
	private var evidenceRefused = false
	private func checkpoint(_ phase: String, status: String = "pending", closed: Bool = false, pids: [Int32] = []) {
		if let phaseEvidence, !phaseEvidence.record(phase, status: status, closed: closed, ownedPIDs: pids), !evidenceRefused {
			evidenceRefused = true
			XCTFail("Safe Sparkle phase evidence publication refused")
		}
	}

	private struct Receipt {
		let status: Int32
		let stdout: String
		let stderr: String
	}

	private final class OwnedProcess {
		let process = Process()
		let completed = DispatchSemaphore(value: 0)
		let stdout: URL
		let stderr: URL
		let streams: [FileHandle]
		let guardianReceipt: URL?
		let originalExecutable: String
		private var launched = false
		private var startRequested = false
		private var observedExit = false
		private var closedStreams: Set<Int> = []
		private var cachedReceipt: Receipt?

		init(_ executable: String, _ arguments: [String], root: URL,
			guarded: Bool = false, workerTimeout: Double = 60) throws {
			let identity = UUID().uuidString
			originalExecutable = executable
			stdout = root.appendingPathComponent(identity + ".stdout")
			stderr = root.appendingPathComponent(identity + ".stderr")
			guardianReceipt = guarded ? root.appendingPathComponent(identity + ".group.json") : nil
			func capture(_ url: URL) throws -> FileHandle {
				let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
				guard descriptor >= 0 else { throw Failure.evidence("child-capture") }
				return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
			}
			let output = try capture(stdout)
			do { streams = [output, try capture(stderr)] }
			catch { try? output.close(); throw error }
			if let guardianReceipt {
				var owner = URL(fileURLWithPath: #filePath)
				for _ in 0..<7 { owner.deleteLastPathComponent() }
				owner.appendPathComponent("tools/diagnostics/macos_owned_process.py")
				process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
				process.arguments = ["python3", owner.path, "run", guardianReceipt.path,
					String(workerTimeout), "--", executable] + arguments
			} else {
				process.executableURL = URL(fileURLWithPath: executable)
				process.arguments = arguments
			}
			process.environment = NativeFixtureChildEnvironment.make()
			process.standardOutput = streams[0]
			process.standardError = streams[1]
			process.terminationHandler = { [completed] _ in completed.signal() }
		}

		/// The caller registers this owner before attempting a native launch.
		/// Even a partially successful Foundation launch remains eligible for retry.
		func start() throws {
			guard !startRequested else { throw Failure.evidence("duplicate-native-launch") }
			startRequested = true
			do {
				try process.run()
				launched = true
			} catch {
				// A failed launch still owns both descriptors, and any native PID
				// acquired before Foundation reported the failure.
				launched = process.processIdentifier > 0
				try? retire()
				throw error
			}
		}

		private func observeExit(_ seconds: Double) -> Bool {
			if observedExit { return !process.isRunning }
			guard completed.wait(timeout: .now() + seconds) == .success else { return false }
			observedExit = true
			return !process.isRunning
		}

		private func closeCaptures() throws {
			var refused = false
			for (index, stream) in streams.enumerated() where !closedStreams.contains(index) {
				do { try stream.close(); closedStreams.insert(index) }
				catch { refused = true }
			}
			guard !refused, closedStreams.count == streams.count else {
				throw Failure.evidence("native-capture-retirement")
			}
		}

		/// The shared native guardian keeps WNOWAIT's leader reservation through
		/// PGID signals/census and reaps last. Its terminal ACK covers descendants
		/// that use system executable paths outside this fixture's path census.
		private func admitGuardRetirement() throws {
			guard let guardianReceipt else { return }
			let descriptor = open(guardianReceipt.path, O_RDONLY | O_NOFOLLOW)
			guard descriptor >= 0 else { throw Failure.evidence("owned-process-group-terminal") }
			let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
			let data: Data
			do {
				data = try stream.readToEnd() ?? Data()
				try stream.close()
			} catch { try? stream.close(); throw error }
			guard data.count < 16_384,
				let packet = try JSONSerialization.jsonObject(with: data) as? [String: Any],
				Set(packet.keys) == Set(["schema", "guardian_pid", "worker_pid", "group_id", "closed", "exit_status"]),
				packet["schema"] as? Int == 1,
				(packet["guardian_pid"] as? NSNumber)?.int32Value == process.processIdentifier,
				let worker = packet["worker_pid"] as? Int, worker > 0,
				packet["group_id"] as? Int == worker, packet["closed"] as? Bool == true else {
				throw Failure.evidence("owned-process-group-terminal")
			}
			let status = process.terminationReason == .exit ? process.terminationStatus : -process.terminationStatus
			guard (packet["exit_status"] as? NSNumber)?.int32Value == status else {
				throw Failure.evidence("owned-process-group-status")
			}
		}

		/// Retirement can be retried after any failure. It only signals this
		/// unreaped direct child; the private launchd installer has a separate owner.
		func retire() throws {
			if !launched { try closeCaptures(); return }
			if !observedExit, !observeExit(0) {
				if process.isRunning { process.terminate() }
				if !observeExit(guardianReceipt == nil ? 5 : 10) {
					// Hard-killing a guardian would discard the still-reserved leader's
					// group identity. Keep that owner alive and retry it independently.
					guard guardianReceipt == nil else { throw Failure.evidence("owned-process-group-retirement-debt") }
					if process.isRunning {
						guard kill(process.processIdentifier, SIGKILL) == 0 || errno == ESRCH else {
							throw Failure.evidence("exact-native-child-kill")
						}
					}
					guard observeExit(5) else { throw Failure.evidence("native-child-reap") }
				}
			}
			guard observedExit, !process.isRunning else {
				throw Failure.evidence("native-child-retirement")
			}
			try closeCaptures()
			try admitGuardRetirement()
		}

		/// Repeated observations reuse the physical exit ACK and immutable receipt;
		/// consuming the semaphore once can never turn an exited child into a timeout.
		func finish(_ seconds: Double) throws -> Receipt {
			if let cachedReceipt { return cachedReceipt }
			guard launched else { throw Failure.evidence("unlaunched-native-child") }
			guard observeExit(seconds) else {
				let primary = Failure.deadline(URL(fileURLWithPath: originalExecutable).lastPathComponent)
				try? retire()
				throw primary
			}
			try closeCaptures()
			try admitGuardRetirement()
			guard process.terminationReason == .exit else { throw Failure.evidence("native-child-signal") }
			let output = try Data(contentsOf: stdout)
			let errors = try Data(contentsOf: stderr)
			guard output.count < 4_000_000, errors.count < 4_000_000,
				let outputText = String(data: output, encoding: .utf8),
				let errorText = String(data: errors, encoding: .utf8) else {
				throw Failure.evidence("native-child-capture")
			}
			let receipt = Receipt(status: process.terminationStatus, stdout: outputText, stderr: errorText)
			cachedReceipt = receipt
			return receipt
		}
	}

	private let manager = FileManager.default
	private var commands: [OwnedProcess] = []
	private var retirementDebt = false

	private var repository: URL {
		var result = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { result.deleteLastPathComponent() }
		return result
	}

	private func run(_ executable: String, _ arguments: [String], root: URL,
		expecting status: Int32 = 0, timeout: Double = 60, phase: NativeCommandPhase = .nativeTool) throws -> Receipt {
		checkpoint("command." + phase.rawValue + ".begin")
		let child = try OwnedProcess(executable, arguments, root: root, guarded: true, workerTimeout: timeout)
		commands.append(child)
		try child.start()
		let receipt: Receipt
		do { receipt = try child.finish(timeout + 10) }
		catch { retirementDebt = true; throw error }
		checkpoint("command." + phase.rawValue + ".end", status: receipt.status == status ? "accepted" : "refused")
		guard receipt.status == status else {
			// Compiler diagnostics concern only this checked-in fixture source.
			// Signing children keep their captured output private.
			if executable == "/usr/bin/xcrun" {
				XCTFail("Private Sparkle child compilation refused: "
					+ String(reflecting: String((receipt.stdout + receipt.stderr).prefix(6000))))
			}
			if phase == .nativeProcessCensus, !annotateCensusRefusal(receipt.stdout) {
				XCTFail("Native Sparkle census refusal: code=diagnostic-unavailable")
			}
			throw Failure.command(phase, receipt.status)
		}
		return receipt
	}

	/// Admit only fixed native facts, never arbitrary child diagnostics or paths.
	private func annotateCensusRefusal(_ stdout: String) -> Bool {
		guard stdout.utf8.count <= 512,
			let packet = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] else { return false }
		func integer(_ key: String, maximum: Int64) -> Int64? {
			guard let value = packet[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
				value.doubleValue >= 0, value.doubleValue <= Double(maximum),
				value.doubleValue == Double(value.int64Value) else { return nil }
			return value.int64Value
		}
		if packet["code"] as? String == "directory-refused" {
			let reasons: Set<String> = ["metadata", "missing", "not-absolute", "not-directory", "mode", "owner", "canonical"]
			guard integer("schema", maximum: 4) == 4,
				Set(packet.keys) == Set(["schema", "code", "helper_pid", "reason"]),
				let helperPID = integer("helper_pid", maximum: Int64(Int32.max)), helperPID > 0,
				let reason = packet["reason"] as? String, reasons.contains(reason) else { return false }
			XCTFail("Native Sparkle census refusal: code=directory-refused helper_pid=\(helperPID) reason=\(reason)")
			return true
		}
		if packet["code"] as? String == "stage-refused" {
			let stages: Set<String> = ["private-root", "library", "inventory", "unexpected"]
			guard integer("schema", maximum: 3) == 3,
				Set(packet.keys) == Set(["schema", "code", "helper_pid", "stage"]),
				let helperPID = integer("helper_pid", maximum: Int64(Int32.max)), helperPID > 0,
				let stage = packet["stage"] as? String, stages.contains(stage) else { return false }
			XCTFail("Native Sparkle census refusal: code=stage-refused helper_pid=\(helperPID) stage=\(stage)")
			return true
		}
		guard packet["code"] as? String == "path-unavailable" else { return false }
		guard let schema = integer("schema", maximum: 2), schema == 1 || schema == 2,
			let helperPID = integer("helper_pid", maximum: Int64(Int32.max)), helperPID > 0,
			let pathErrno = integer("path_errno", maximum: 4095) else { return false }
		var summary = "Native Sparkle census refusal: code=path-unavailable helper_pid=\(helperPID) path_errno=\(pathErrno)"
		if schema == 1 {
			guard Set(packet.keys) == Set(["schema", "code", "helper_pid", "path_errno"]) else { return false }
		} else {
			let states: Set<String> = ["creating", "runnable", "sleeping", "stopped", "zombie",
				"unavailable", "identity-refused", "state-refused", "abi-refused", "diagnostic-refused"]
			guard Set(packet.keys) == Set(["schema", "code", "helper_pid", "path_errno",
				"bsd_bytes", "bsd_errno", "bsd_state"]),
				let bytes = integer("bsd_bytes", maximum: 4095),
				let nativeErrno = integer("bsd_errno", maximum: 4095),
				let state = packet["bsd_state"] as? String, states.contains(state) else { return false }
			if ["creating", "runnable", "sleeping", "stopped", "zombie"].contains(state) {
				guard bytes == 136, nativeErrno == 0 else { return false }
			}
			summary += " bsd_bytes=\(bytes) bsd_errno=\(nativeErrno) bsd_state=\(state)"
		}
		// These are snapshot facts, never an ownership-closure ACK or PID skip.
		// XCTest evidence must carry them even when raw CI logs are unavailable.
		XCTFail(summary)
		return true
	}

	private func privateDirectory(_ url: URL) throws {
		guard !manager.fileExists(atPath: url.path) else { throw Failure.prerequisite("private-directory-already-exists") }
		try manager.createDirectory(at: url, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
	}

	private func waitFor(_ name: String, root: URL, seconds: Double = 45) throws -> [String: Any] {
		checkpoint("wait." + name)
		let target = root.appendingPathComponent(name + ".json")
		let deadline = Date().addingTimeInterval(seconds)
		while !manager.fileExists(atPath: target.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
		guard manager.fileExists(atPath: target.path),
			let packet = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any] else {
			throw Failure.deadline(name)
		}
		checkpoint("observed." + name, status: "accepted")
		return packet
	}

	/// Polling children may admit only a complete, exclusive control record.
	/// Opening the final file before writing would briefly expose empty bytes.
	private func publishControl(_ name: String, nonce: String, root: URL) throws {
		let stage = root.appendingPathComponent("." + UUID().uuidString + ".control")
		let descriptor = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
		guard descriptor >= 0 else { throw Failure.evidence("private-control-acquisition") }
		let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		do {
			try stream.write(contentsOf: Data(nonce.utf8))
			try stream.synchronize()
			try stream.close()
		} catch { try? stream.close(); throw error }
		let target = root.appendingPathComponent(name)
		guard link(stage.path, target.path) == 0 else { throw Failure.evidence("private-control-publication") }
		guard unlink(stage.path) == 0 else { throw Failure.evidence("private-control-stage-retirement") }
	}

	/// Expectations come from the independent signed source, not the producer's
	/// snapshot implementation or a corpus regenerated from installed output.
	private func snapshot(_ app: URL) throws -> [String: [String]] {
		var result: [String: [String]] = [:]
		func visit(_ relative: String) throws {
			let target = relative.isEmpty ? app : app.appendingPathComponent(relative)
			let attributes = try manager.attributesOfItem(atPath: target.path)
			let type = attributes[.type] as? FileAttributeType
			let mode = String(try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue)
			if type == .typeSymbolicLink {
				result[relative] = ["link", try manager.destinationOfSymbolicLink(atPath: target.path)]
			} else if type == .typeDirectory {
				result[relative] = ["directory", mode]
				for name in try manager.contentsOfDirectory(atPath: target.path).sorted() {
					try visit(relative.isEmpty ? name : relative + "/" + name)
				}
			} else if type == .typeRegular {
				result[relative] = ["file", mode, hash(try Data(contentsOf: target))]
			} else { throw Failure.evidence("unsupported-source-file") }
		}
		try visit("")
		return result
	}

	private func hash(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	private func requirement(_ app: URL, root: URL) throws -> String {
		let display = try run("/usr/bin/codesign", ["-d", "-r-", app.path], root: root)
		let lines = (display.stdout + "\n" + display.stderr).components(separatedBy: .newlines)
			.map { $0.hasPrefix("# designated => ") ? String($0.dropFirst(2)) : $0 }
			.filter { $0.hasPrefix("designated => ") }
		guard lines.count == 1, !String(lines[0].dropFirst(14)).isEmpty else {
			throw Failure.evidence("unique-native-signing-requirement")
		}
		return String(lines[0].dropFirst(14))
	}

	private struct ReleaseRepository {
		let owner: String
		let name: String
		var archiveOrigin: String {
			"https://github.com/" + owner + "/" + name + "/releases/download/v2.0.0/ErgoptiPlus.app.tar.xz"
		}
	}

	/// Read the canonical checkout data, while keeping fixture tag/artifact expectations independent.
	private func releaseRepository() throws -> ReleaseRepository {
		let source = repository.appendingPathComponent("static/ergopti_plus/_shared/modules/updater/defaults.json")
		let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
		guard descriptor >= 0 else { throw Failure.prerequisite("canonical-release-repository") }
		let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		defer { try? stream.close() }
		var info = stat()
		guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
			info.st_size > 0, info.st_size <= 65536,
			let bytes = try stream.read(upToCount: 65537), Int64(bytes.count) == info.st_size, bytes.count <= 65536,
			let defaults = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
			let github = defaults["github"] as? [String: Any],
			let owner = github["owner"] as? String, let name = github["repo"] as? String else {
			throw Failure.prerequisite("canonical-release-repository")
		}
		let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
		guard [owner, name].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100 && $0.utf8.allSatisfy({ allowed.contains($0) }) }) else {
			throw Failure.prerequisite("canonical-release-repository-components")
		}
		return ReleaseRepository(owner: owner, name: name)
	}

	private func makeBundle(_ app: URL, compiled: URL, framework: URL, root: URL,
		nonce: String, port: Int, publicKey: String, version: String, identity: ReleaseRepository) throws {
		try privateDirectory(app)
		for relative in ["Contents", "Contents/MacOS", "Contents/Resources", "Contents/Frameworks"] {
			try privateDirectory(app.appendingPathComponent(relative))
		}
		let executable = app.appendingPathComponent("Contents/MacOS/PrivateSparkleChild")
		try manager.copyItem(at: compiled, to: executable)
		try manager.setAttributes([.posixPermissions: 0o751], ofItemAtPath: executable.path)
		_ = try run("/usr/bin/ditto", [framework.path, app.appendingPathComponent("Contents/Frameworks/Sparkle.framework").path], root: root)
		let plist: [String: Any] = [
			"CFBundleIdentifier": "org.ergoptiplus.archive-acceptance." + nonce,
			"CFBundleName": "ErgoptiPlus", "CFBundleExecutable": "PrivateSparkleChild",
			"CFBundlePackageType": "APPL", "CFBundleVersion": version,
			"CFBundleShortVersionString": version + ".0",
			"FixtureRoot": root.path, "FixtureNonce": nonce,
			"FixtureGitHubOwner": identity.owner, "FixtureGitHubRepo": identity.name,
			"FixtureArchiveOrigin": identity.archiveOrigin,
			"FixtureArchiveTransport": "http://localhost:" + String(port) + "/archive.tar.xz",
			"SUFeedURL": "http://localhost:" + String(port) + "/feed.xml",
			"SUEdPublicKey": publicKey, "SUVerifyUpdateBeforeExtraction": true,
			"SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false,
			"SUAllowsAutomaticUpdates": false, "SUEnableDownloaderService": false,
			"SUEnableInstallerLauncherService": false,
			"NSAppTransportSecurity": ["NSAllowsLocalNetworking": true]
		]
		try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
			.write(to: app.appendingPathComponent("Contents/Info.plist"))
		let resource = app.appendingPathComponent("Contents/Resources/independent.txt")
		try Data((version == "1" ? "Before update: café 😀\n" : "After update: café 😀\n").utf8).write(to: resource)
		try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: resource.path)
		try manager.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Resources/independent-link").path,
			withDestinationPath: "independent.txt")
		_ = try run("/usr/bin/xattr", ["-w", "com.ergopti.sparkle-fixture", "retained-fixture-metadata", resource.path], root: root)
		_ = try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path], root: root)
		_ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], root: root)
	}

	/// Preserve the production generator's exact XML and canonical HTTPS origin.
	/// Only the signed disposable child's download request routes to loopback.
	private func generatedFeed(_ archives: URL, destination: URL, root: URL, identity: ReleaseRepository) throws -> Data {
		let generated = root.appendingPathComponent("generated-appcast-" + UUID().uuidString + ".xml")
		_ = try run("/usr/bin/env", ["ERGOPTI_VERSION=2.0.0", "ERGOPTI_BUILD=2", "ERGOPTI_CHANNEL=dev",
			"GH_OWNER=" + identity.owner, "GH_REPO=" + identity.name, "ARCHIVE_DIR=" + archives.path,
			"OUTPUT_PATH=" + generated.path, "node", repository.appendingPathComponent(
				"tools/build/macos-release-publication.cjs").path, "appcast"], root: root, phase: .generatedAppcast)
		let bytes = try Data(contentsOf: generated)
		let xml = try XCTUnwrap(String(data: bytes, encoding: .utf8))
		XCTAssertTrue(xml.contains("url=\"" + identity.archiveOrigin + "\""))
		XCTAssertFalse(xml.contains("http://localhost:"), "The producer's XML is never rewritten for fixture transport")
		XCTAssertTrue(xml.contains("<sparkle:version>2</sparkle:version>"))
		XCTAssertTrue(xml.contains("<sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>"))
		try bytes.write(to: destination, options: .atomic)
		XCTAssertTrue(try Data(contentsOf: destination) == bytes, "The served appcast must retain exact generated bytes")
		return bytes
	}

	private func census(_ roots: [URL], root: URL) throws -> [[String: Any]] {
		let helper = repository.appendingPathComponent("tools/diagnostics/macos_sparkle_archive_fixture.py")
		let response = try run("/usr/bin/env", ["python3", helper.path, "census"] + roots.map(\.path), root: root, phase: .nativeProcessCensus)
		guard let records = try JSONSerialization.jsonObject(with: Data(response.stdout.utf8)) as? [[String: Any]] else {
			throw Failure.evidence("native-process-census")
		}
		return records
	}

	/// A unique initially absent job label is the native installer's identity.
	/// Removal never targets a product updater or another fixture's job.
	private func removeInstallerJob(_ target: String, root: URL) throws {
		let query = try OwnedProcess("/bin/launchctl", ["print", target], root: root, guarded: true, workerTimeout: 10)
		commands.append(query)
		try query.start()
		let receipt = try query.finish(20)
		if receipt.status == 0 {
			guard receipt.stdout.contains(root.path) else { throw Failure.evidence("foreign-installer-job") }
			_ = try run("/bin/launchctl", ["bootout", target], root: root)
			let observation = try OwnedProcess("/bin/launchctl", ["print", target], root: root, guarded: true, workerTimeout: 10)
			commands.append(observation)
			try observation.start()
			let retired = try observation.finish(20)
			guard retired.status != 0,
				(retired.stdout + retired.stderr).contains("Could not find service") else {
				throw Failure.evidence("installer-job-retirement")
			}
		} else if !(receipt.stdout + receipt.stderr).contains("Could not find service") {
			throw Failure.evidence("installer-job-observation")
		}
	}

	func testDirectNativeChildExitACKAndCaptureRetirementAreIdempotent() throws {
		let root = manager.temporaryDirectory.resolvingSymlinksInPath()
			.appendingPathComponent("ErgoptiSparkleChildACK-" + UUID().uuidString)
		try privateDirectory(root)
		var child: OwnedProcess?
		var passed = false
		let failuresBefore = try XCTUnwrap(testRun?.failureCount)
		defer {
			do {
				try child?.retire()
				if passed { try manager.removeItem(at: root) }
				else { XCTFail("Native child ACK control retained at " + root.path) }
			} catch { XCTFail("Native child ACK retirement refused; inputs retained at " + root.path) }
		}
		child = try OwnedProcess("/usr/bin/true", [], root: root)
		let owner = try XCTUnwrap(child)
		try owner.start()
		let first = try owner.finish(5)
		let second = try owner.finish(0)
		XCTAssertEqual(first.status, 0)
		XCTAssertEqual(second.status, first.status)
		XCTAssertEqual(second.stdout, first.stdout)
		XCTAssertEqual(second.stderr, first.stderr)
		XCTAssertFalse(owner.process.isRunning)
		try owner.retire()
		try owner.retire()
		passed = testRun?.failureCount == failuresBefore
	}

	func testActualSparkleTarXZUpdateRefusesWrongKeyPreservesOldAppAndRetriesThroughRelaunch() throws {
		phaseEvidence = try ArchiveAcceptanceEvidence(owner: .sparkle)
		evidenceRefused = false
		checkpoint("candidate.begin")
		guard getuid() != 0 else { throw Failure.prerequisite("nonroot-aqua-user-session") }
		let identity = try releaseRepository()
		let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
		let bundleID = "org.ergoptiplus.archive-acceptance." + nonce
		let root = manager.temporaryDirectory.resolvingSymlinksInPath()
			.appendingPathComponent("ErgoptiSparkleArchive-" + nonce)
		try privateDirectory(root)
		let cache = try manager.url(for: .cachesDirectory, in: .userDomainMask,
			appropriateFor: nil, create: false).resolvingSymlinksInPath().appendingPathComponent(bundleID)
		let job = "gui/" + String(getuid()) + "/" + bundleID + "-sparkle-updater"
		var cacheOwned = false
		var jobOwned = false
		var server: OwnedProcess?
		var application: OwnedProcess?
		let failuresBefore = try XCTUnwrap(testRun?.failureCount)
		var passed = false
		defer {
			checkpoint("cleanup.begin", pids: [application, server].compactMap { $0?.process.processIdentifier }.filter { $0 > 0 })
			func attempt(_ label: String, _ action: () throws -> Void) {
				do { try action() }
				catch {
					retirementDebt = true
					checkpoint("cleanup.debt-" + label, status: "cleanup-debt")
					XCTFail("Private Sparkle retirement refused (" + label + "); fixture retained at " + root.path)
				}
			}
			if application != nil {
				attempt("application-control") {
					try publishControl("retire", nonce: nonce, root: root)
				}
				if let application, application.process.processIdentifier > 0 {
					attempt("application-exit") {
						let retired = try application.finish(15)
						guard retired.status == 0 else { throw Failure.evidence("application-retirement") }
					}
				}
			}
			if let server, server.process.processIdentifier > 0 {
				attempt("server-exit") {
					if server.process.isRunning { server.process.terminate() }
					let retired = try server.finish(10)
					guard retired.status == 0 else { throw Failure.evidence("server-retirement") }
				}
				attempt("server-terminal") {
					let terminal = try waitFor("server-retired", root: root.appendingPathComponent("www"), seconds: 2)
					guard terminal["nonce"] as? String == nonce,
						(terminal["pid"] as? NSNumber)?.int32Value == server.process.processIdentifier else {
						throw Failure.evidence("server-retirement-receipt")
					}
				}
			}
			// Each owner gets an independent retry even when a different owner's
			// control, capture, exit or terminal receipt already refused.
			for command in commands { attempt("acquired-child") { try command.retire() } }
			if jobOwned { attempt("installer-job") { try removeInstallerJob(job, root: root) } }
			attempt("kernel-process-census") {
				let deadline = Date().addingTimeInterval(15)
				let roots = cacheOwned ? [root, cache] : [root]
				while !(try census(roots, root: root)).isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
				guard try census(roots, root: root).isEmpty else { throw Failure.evidence("installer-or-relaunch-retirement") }
				Thread.sleep(forTimeInterval: 0.25)
				guard try census(roots, root: root).isEmpty else { throw Failure.evidence("late-native-relaunch") }
			}
			// Job and census commands were acquired during cleanup and retain the
			// same idempotent physical-retirement obligation as earlier children.
			for command in commands { attempt("cleanup-child") { try command.retire() } }
			if !retirementDebt {
				checkpoint("cleanup.closed", status: "accepted", closed: true,
					pids: [application, server].compactMap { $0?.process.processIdentifier }.filter { $0 > 0 })
			}
			if !retirementDebt, !evidenceRefused, passed, testRun?.failureCount == failuresBefore {
				attempt("private-inputs") {
					UserDefaults.standard.removePersistentDomain(forName: bundleID)
					guard UserDefaults.standard.synchronize() else { throw Failure.evidence("private-defaults-retirement") }
					if cacheOwned { try manager.removeItem(at: cache) }
					try manager.removeItem(at: root)
					XCTAssertFalse(manager.fileExists(atPath: root.path))
					XCTAssertFalse(manager.fileExists(atPath: cache.path))
				}
			} else { XCTFail("Private Sparkle fixture retained for inspection at " + root.path) }
		}

		_ = try run("/bin/launchctl", ["print", "gui/" + String(getuid())], root: root)
		let absent = try OwnedProcess("/bin/launchctl", ["print", job], root: root, guarded: true, workerTimeout: 10)
		commands.append(absent)
		try absent.start()
		let absence = try absent.finish(20)
		guard absence.status != 0, (absence.stdout + absence.stderr).contains("Could not find service"),
			UserDefaults.standard.persistentDomain(forName: bundleID) == nil else {
			throw Failure.prerequisite("private-installer-identity-already-exists")
		}
		jobOwned = true
		try privateDirectory(cache)
		cacheOwned = true
		let framework = Bundle(for: SPUUpdater.self)
		guard framework.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "2.9.2",
			let signer = ProcessInfo.processInfo.environment["SIGN_UPDATE"], manager.isExecutableFile(atPath: signer) else {
			throw Failure.prerequisite("pinned-native-sparkle-tools")
		}
		let helper = repository.appendingPathComponent("tools/diagnostics/macos_sparkle_archive_fixture.py")
		let www = root.appendingPathComponent("www")
		try privateDirectory(www)
		server = try OwnedProcess("/usr/bin/env", ["python3", helper.path, "serve", www.path, nonce], root: root)
		commands.append(try XCTUnwrap(server))
		try server?.start()
		let listening = try waitFor("server-start", root: www, seconds: 10)
		let port = try XCTUnwrap(listening["port"] as? Int)
		guard listening["nonce"] as? String == nonce,
			(listening["pid"] as? NSNumber)?.int32Value == server?.process.processIdentifier,
			(1...65535).contains(port) else { throw Failure.evidence("private-loopback-server") }

		let compiled = root.appendingPathComponent("compiled-child")
		let childSource = repository.appendingPathComponent("tools/diagnostics/macos_sparkle_archive_child.swift")
		_ = try run("/usr/bin/xcrun", ["swiftc", childSource.path, "-F", framework.bundleURL.deletingLastPathComponent().path,
			"-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
			"-o", compiled.path], root: root)
		let key = Curve25519.Signing.PrivateKey()
		let foreignKey = Curve25519.Signing.PrivateKey()
		let keyFile = root.appendingPathComponent("private-file-key")
		try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyFile, options: .withoutOverwriting)
		try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
		for directory in ["installed", "source", "archives"] { try privateDirectory(root.appendingPathComponent(directory)) }
		let installed = root.appendingPathComponent("installed/ErgoptiPlus.app")
		let source = root.appendingPathComponent("source/ErgoptiPlus.app")
		for (app, version) in [(installed, "1"), (source, "2")] {
			try makeBundle(app, compiled: compiled, framework: framework.bundleURL, root: root,
				nonce: nonce, port: port, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), version: version, identity: identity)
		}
		let oldSnapshot = try snapshot(installed)
		let newSnapshot = try snapshot(source)
		let newRequirement = try requirement(source, root: root)
		let archives = root.appendingPathComponent("archives")
		_ = try run("/usr/bin/env", ["node", repository.appendingPathComponent("tools/build/macos-release-archives.cjs").path,
			source.path, archives.path], root: root, phase: .archiveBuild)
		_ = try run("/usr/bin/env", ["node", repository.appendingPathComponent("tools/build/macos-release-publication.cjs").path,
			"sign", archives.path, signer, keyFile.path], root: root, phase: .archiveSign)
		let payload = try Data(contentsOf: archives.appendingPathComponent("ErgoptiPlus.app.tar.xz"))
		let fragment = try String(contentsOf: archives.appendingPathComponent("_ErgoptiPlus.app.tar.xz.sig"), encoding: .utf8)
		let expression = try NSRegularExpression(pattern: #"^sparkle:edSignature="([A-Za-z0-9+/]{86}==)" length="([1-9][0-9]*)"\n$"#)
		let match = try XCTUnwrap(expression.firstMatch(in: fragment, range: NSRange(fragment.startIndex..., in: fragment)))
		let signature = String(fragment[try XCTUnwrap(Range(match.range(at: 1), in: fragment))])
		let signatureBytes = try XCTUnwrap(Data(base64Encoded: signature))
		XCTAssertEqual(Int(fragment[try XCTUnwrap(Range(match.range(at: 2), in: fragment))]), payload.count)
		XCTAssertTrue(key.publicKey.isValidSignature(signatureBytes, for: payload), "The native signer and independent Ed25519 public key must agree")
		let wrongSignature = try foreignKey.signature(for: payload)
		XCTAssertTrue(foreignKey.publicKey.isValidSignature(wrongSignature, for: payload))
		XCTAssertFalse(key.publicKey.isValidSignature(wrongSignature, for: payload))
		let foreignArchives = root.appendingPathComponent("foreign-key-archives")
		try privateDirectory(foreignArchives)
		for name in ["ErgoptiPlus.app.tar.xz", "ErgoptiPlus.app.zip"] {
			try manager.copyItem(at: archives.appendingPathComponent(name), to: foreignArchives.appendingPathComponent(name))
		}
		let foreignKeyFile = root.appendingPathComponent("foreign-file-key")
		try Data(foreignKey.rawRepresentation.base64EncodedString().utf8).write(to: foreignKeyFile, options: .withoutOverwriting)
		try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: foreignKeyFile.path)
		_ = try run("/usr/bin/env", ["node", repository.appendingPathComponent("tools/build/macos-release-publication.cjs").path,
			"sign", foreignArchives.path, signer, foreignKeyFile.path], root: root, phase: .archiveSignForeign)
		let foreignFragment = try String(contentsOf: foreignArchives.appendingPathComponent("_ErgoptiPlus.app.tar.xz.sig"), encoding: .utf8)
		let foreignMatch = try XCTUnwrap(expression.firstMatch(in: foreignFragment, range: NSRange(foreignFragment.startIndex..., in: foreignFragment)))
		let foreignSignature = String(foreignFragment[try XCTUnwrap(Range(foreignMatch.range(at: 1), in: foreignFragment))])
		XCTAssertTrue(Data(base64Encoded: foreignSignature) == wrongSignature, "The official signer must agree with the independent foreign Ed25519 key")
		XCTAssertEqual(Int(foreignFragment[try XCTUnwrap(Range(foreignMatch.range(at: 2), in: foreignFragment))]), payload.count)
		try payload.write(to: www.appendingPathComponent("archive.tar.xz"), options: .withoutOverwriting)
		let refusedFeed = try generatedFeed(foreignArchives, destination: www.appendingPathComponent("feed.xml"), root: root, identity: identity)

		application = try OwnedProcess(installed.appendingPathComponent("Contents/MacOS/PrivateSparkleChild").path, [], root: root)
		commands.append(try XCTUnwrap(application))
		try application?.start()
		checkpoint("application.started", pids: application.map { [$0.process.processIdentifier] } ?? [])
		let started = try waitFor("started-1", root: root)
		XCTAssertEqual((started["pid"] as? NSNumber)?.int32Value, application?.process.processIdentifier)
		XCTAssertEqual(started["nonce"] as? String, nonce)
		let actual = try census([root, cache], root: root)
		XCTAssertTrue(actual.contains { ($0["pid"] as? NSNumber)?.int32Value == application?.process.processIdentifier
			&& $0["executable"] as? String == installed.appendingPathComponent("Contents/MacOS/PrivateSparkleChild").path })
		let refusal = try waitFor("refused-1", root: root)
		_ = try waitFor("cycle-refused-1", root: root)
		let details = try XCTUnwrap(refusal["details"] as? [String: Any])
		let errors = try XCTUnwrap(details["errors"] as? [[String: Any]])
		XCTAssertTrue(errors.contains { $0["domain"] as? String == SUSparkleErrorDomain
			&& ($0["code"] as? NSNumber)?.intValue == 3001 }, "Wrong-key refusal must reach actual Sparkle signature validation")
		XCTAssertEqual(try snapshot(installed), oldSnapshot, "A refused archive cannot alter the installed signed source")
		XCTAssertTrue(try XCTUnwrap(application).process.isRunning)
		XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("ready-1.json").path))
		XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("installing-1.json").path))
		XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("started-2.json").path))

		let acceptedFeed = try generatedFeed(archives, destination: www.appendingPathComponent("feed.xml"), root: root, identity: identity)
		try publishControl("retry", nonce: nonce, root: root)
		_ = try waitFor("retry-accepted", root: root)
		_ = try waitFor("ready-2", root: root)
		_ = try waitFor("installing-2", root: root)
		_ = try waitFor("relaunch-requested-2", root: root)
		let relaunched = try waitFor("started-2", root: root)
		XCTAssertEqual(relaunched["nonce"] as? String, nonce)
		XCTAssertEqual(relaunched["version"] as? String, "2")
		XCTAssertEqual((try waitFor("terminated-1", root: root))["version"] as? String, "1")
		let replacementPID = try XCTUnwrap((relaunched["pid"] as? NSNumber)?.int32Value)
		XCTAssertNotEqual(replacementPID, application?.process.processIdentifier)
		XCTAssertTrue(try census([root, cache], root: root).contains { ($0["pid"] as? NSNumber)?.int32Value == replacementPID
			&& $0["executable"] as? String == installed.appendingPathComponent("Contents/MacOS/PrivateSparkleChild").path })
		XCTAssertEqual(try snapshot(installed), newSnapshot, "Actual Sparkle installation must retain all source bytes, modes and relative links")
		XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("Contents/Resources/independent.txt")),
			Data("After update: café 😀\n".utf8))
		XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: installed.appendingPathComponent("Contents/Resources/independent-link").path),
			"independent.txt")
		_ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + newRequirement, installed.path], root: root)
		XCTAssertEqual(try run("/usr/bin/xattr", ["-p", "com.ergopti.sparkle-fixture",
			installed.appendingPathComponent("Contents/Resources/independent.txt").path], root: root).stdout.trimmingCharacters(in: .newlines),
			"retained-fixture-metadata")
		let requests = try manager.contentsOfDirectory(at: www, includingPropertiesForKeys: nil)
			.filter { $0.lastPathComponent.hasPrefix("request-") }
		let downloaded = try requests.compactMap { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
			.filter { $0["path"] as? String == "/archive.tar.xz" }
		XCTAssertEqual(downloaded.count, 2, "Refusal and retry must both fetch the real tar.xz archive")
		let fetchedFeeds = try requests.compactMap { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
			.filter { $0["path"] as? String == "/feed.xml" }
		XCTAssertEqual(fetchedFeeds.count, 2, "Both native update cycles must consume the actual generated feed")
		XCTAssertEqual(Set(fetchedFeeds.compactMap { $0["sha256"] as? String }), Set([hash(refusedFeed), hash(acceptedFeed)]))
		for cycle in [1, 2] {
			let routing = try waitFor("routed-" + String(cycle), root: root)
			XCTAssertEqual(routing["nonce"] as? String, nonce)
			XCTAssertEqual((routing["pid"] as? NSNumber)?.int32Value, application?.process.processIdentifier)
			let details = try XCTUnwrap(routing["details"] as? [String: Any])
			XCTAssertEqual(details["origin"] as? String, identity.archiveOrigin)
			XCTAssertEqual(details["transport"] as? String, "http://localhost:" + String(port) + "/archive.tar.xz")
		}
		for receipt in downloaded {
			XCTAssertEqual(receipt["nonce"] as? String, nonce)
			XCTAssertEqual(receipt["sha256"] as? String, hash(payload))
			XCTAssertEqual(receipt["bytes"] as? Int, payload.count)
		}
		checkpoint("receipt.checked", status: testRun?.failureCount == failuresBefore ? "accepted" : "refused")
		passed = testRun?.failureCount == failuresBefore
	}
}
