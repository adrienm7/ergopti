// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NativeAppClonerBundleOwnershipTests.swift
//
// Executes the shipped ownership helper with actual Darwin zsh and BSD stat.
// Shortcut icon tools are controlled; no generated application is launched.

import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class NativeAppClonerBundleOwnershipTests: XCTestCase {
	private static let operationDeadline: DispatchTimeInterval = .seconds(15)
	private static let retirementDeadline: DispatchTimeInterval = .seconds(5)
	private var fixtureCanRetire = true

	private static var repositoryURL: URL {
		var root = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { root.deleteLastPathComponent() }
		return root
	}

	private static var resourcesURL: URL {
		Self.repositoryURL.appendingPathComponent("static/ergopti_plus/macos/apps/App Cloner.app/Contents/Resources")
	}

	private struct Result {
		let status: Int32
		let output: String
		let stderr: String
	}

	private func retire(_ handle: FileHandle) {
		do { try handle.close() }
		catch {
			fixtureCanRetire = false
			XCTFail("The exact bundle ownership fixture handle did not retire")
		}
	}

	private func run(_ arguments: [String], root: URL, environment: [String: String] = [:]) throws -> Result {
		let outputURL = root.appendingPathComponent(UUID().uuidString + ".stdout")
		let errorURL = root.appendingPathComponent(UUID().uuidString + ".stderr")
		for file in [outputURL, errorURL] {
			XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]))
		}
		let output = try FileHandle(forWritingTo: outputURL)
		defer { retire(output) }
		let errors = try FileHandle(forWritingTo: errorURL)
		defer { retire(errors) }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/zsh")
		process.arguments = arguments
		var child = NativeFixtureChildEnvironment.make()
		child["LC_ALL"] = "C"
		for (key, value) in environment { child[key] = value }
		process.environment = child
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = errors
		let completed = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in completed.signal() }
		try process.run()
		guard completed.wait(timeout: .now() + Self.operationDeadline) == .success else {
			fixtureCanRetire = false
			if process.isRunning { process.terminate() }
			if completed.wait(timeout: .now() + Self.retirementDeadline) != .success {
				fixtureCanRetire = false
				XCTFail("The exact bundle ownership fixture child did not retire")
			}
			throw CocoaError(.executableRuntimeMismatch)
		}
		XCTAssertEqual(process.terminationReason, .exit)
		guard process.terminationReason == .exit else {
			fixtureCanRetire = false
			throw CocoaError(.executableRuntimeMismatch)
		}
		return Result(status: process.terminationStatus, output: try String(contentsOf: outputURL, encoding: .utf8),
			stderr: try String(contentsOf: errorURL, encoding: .utf8))
	}

	private func fixture(_ body: (URL) throws -> Void) throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiBundleOwnership-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact bundle ownership fixture did not retire") }
			}
		}
		try body(root)
	}

	private func writeExecutable(_ url: URL, _ source: String) throws {
		try Data(source.utf8).write(to: url)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
	}

	func testActualNativeOwnershipPreservesCompletedAndForeignBundles() throws {
		try fixture { root in
			let original = root.appendingPathComponent("Reserved.app")
			try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
			try Data("existing".utf8).write(to: original.appendingPathComponent("marker"))
			let originalLink = root.appendingPathComponent("Reserved_1.app")
			try FileManager.default.createSymbolicLink(at: originalLink, withDestinationURL: original)
			let script = #"""
			set -euo pipefail
			source "$1"
			initialize_bundle_creation
			trap cleanup_bundle_creation EXIT
			reserve_owned_bundle_directory "$2"
			mkdir -p "$DEST/Contents"
			TMPDIR_WORK="$(mktemp -d "$3/workspace.XXXXXX")"
			printf '%s\0%s\0' "$DEST" "$TMPDIR_WORK"
			case "$4" in
				failure) exit 74 ;;
				term) kill -TERM $$; printf unexpected-success ;;
				replacement) mv "$DEST" "$DEST.held"; mkdir "$DEST"; printf foreign > "$DEST/marker"; exit 75 ;;
				symlink) mv "$DEST" "$DEST.held"; ln -s "$DEST.held" "$DEST"; exit 76 ;;
				completed) CLONE_COMPLETE=1 ;;
				receipt) CLONE_COMPLETE=1; exec 1>&-; /usr/bin/printf '%s' unavailable-output ;;
			esac
			"""#
			for mode in ["failure", "term", "replacement", "symlink", "completed", "receipt"] {
				let result = try run(["-c", script, "ownership", Self.resourcesURL.appendingPathComponent("reserve_bundle.sh").path,
					original.path, root.path, mode], root: root)
				let fields = result.output.components(separatedBy: "\0")
				XCTAssertEqual(fields.count, 3, "The actual native helper must report both owned paths for \(mode): \(result.stderr)")
				guard fields.count == 3 else { throw CocoaError(.fileReadCorruptFile) }
				let destination = fields[0]
				XCTAssertFalse(destination.isEmpty)
				XCTAssertFalse(fields[1].isEmpty)
				XCTAssertFalse(FileManager.default.fileExists(atPath: fields[1]), "Retire the actual workspace for \(mode)")
				switch mode {
				case "failure":
					XCTAssertEqual(result.status, 74)
					XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
					XCTAssertTrue(result.stderr.isEmpty)
				case "term":
					XCTAssertEqual(result.status, 143)
					XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
					XCTAssertTrue(result.stderr.isEmpty)
				case "replacement":
					XCTAssertEqual(result.status, 75)
					XCTAssertEqual(try String(contentsOfFile: destination + "/marker", encoding: .utf8), "foreign")
					XCTAssertTrue(FileManager.default.fileExists(atPath: destination + ".held"))
					XCTAssertTrue(result.stderr.contains("reserved bundle ownership changed; refusing cleanup"))
				case "symlink":
					XCTAssertEqual(result.status, 76)
					XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination), destination + ".held")
					XCTAssertTrue(result.stderr.contains("reserved bundle ownership changed; refusing cleanup"))
				case "completed":
					XCTAssertEqual(result.status, 0)
					XCTAssertTrue(FileManager.default.fileExists(atPath: destination + "/Contents"))
					XCTAssertTrue(result.stderr.isEmpty)
				case "receipt":
					XCTAssertNotEqual(result.status, 0)
					XCTAssertTrue(FileManager.default.fileExists(atPath: destination + "/Contents"))
				default: XCTFail("Unexpected owned fixture mode")
				}
			}
			XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("marker"), encoding: .utf8), "existing")
			XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: originalLink.path), original.path)
		}
	}

	func testActualCloneLogFailureRetiresItsReservedBundleAndWorkspace() throws {
		try fixture { root in
			XCTAssertNotEqual(geteuid(), 0, "The real log EACCES requires a non-root fixture")
			guard geteuid() != 0 else { throw CocoaError(.executableRuntimeMismatch) }
			let source = try String(contentsOf: Self.resourcesURL.appendingPathComponent("clone_app.sh"), encoding: .utf8)
			let boundary = #"log "SRC_EXE=$SRC_EXE""#
			let parts = source.components(separatedBy: boundary)
			XCTAssertEqual(parts.count, 2, "The actual first post-reservation log boundary must be unique")
			guard parts.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
			let prefix = parts[0] + boundary
			XCTAssertEqual(prefix.components(separatedBy: "/usr/libexec/PlistBuddy").count, 2)
			let resources = root.appendingPathComponent("resources")
			let bin = root.appendingPathComponent("bin")
			let home = root.appendingPathComponent("home")
			let app = root.appendingPathComponent("Source.app")
			for directory in [resources, bin, home, app.appendingPathComponent("Contents/MacOS")] {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			}
			try Data("inert".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Source"))
			for name in ["reserve_bundle.sh", "quote_launcher_values.py"] {
				try FileManager.default.copyItem(at: Self.resourcesURL.appendingPathComponent(name), to: resources.appendingPathComponent(name))
			}
			let buddy = bin.appendingPathComponent("PlistBuddy")
			try writeExecutable(buddy, #"""
			#!/bin/sh
			[ "$#" = 3 ] && [ "$1" = -c ] && [ "$2" = 'Print :CFBundleExecutable' ] && [ "$3" = "$OWNED_SOURCE/Contents/Info.plist" ] || exit 91
			if [ "$OWNED_LOG_FAULT" = failure ]; then chmod 400 "$OWNED_LOG"; fi
			printf '%s\n' Source
			"""#)
			try writeExecutable(bin.appendingPathComponent("python3"), #"""
			#!/bin/sh
			[ "$#" = 2 ] && [ "$1" = -c ] && [ "$2" = 'import sys' ] || exit 92
			"""#)
			try writeExecutable(bin.appendingPathComponent("mktemp"), #"""
			#!/bin/sh
			[ "$#" = 2 ] && [ "$1" = -d ] && [ "$2" = /tmp/appcloner.XXXXXX ] || exit 93
			exec /usr/bin/mktemp -d "$OWNED_TMP_TEMPLATE"
			"""#)
			try writeExecutable(bin.appendingPathComponent("tee"), #"""
			#!/bin/sh
			[ "$#" = 2 ] && [ "$1" = -a ] && [ "$2" = "$OWNED_LOG" ] || exit 94
			printf '%s' "$$" > "$OWNED_TEE_RECEIPT.tmp" || exit $?
			/bin/mv "$OWNED_TEE_RECEIPT.tmp" "$OWNED_TEE_RECEIPT" || exit $?
			exec /usr/bin/tee "$@"
			"""#)
			let quotedBuddy = "'" + buddy.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
			let script = resources.appendingPathComponent("clone_app.sh")
			try writeExecutable(script, prefix.replacingOccurrences(of: "/usr/libexec/PlistBuddy", with: quotedBuddy) + "\nprintf '%s\\n' owned-tee-stream\nexit 0\n")
			for mode in ["healthy", "failure"] {
				let log = root.appendingPathComponent(mode + ".log")
				let teeReceipt = root.appendingPathComponent(mode + ".tee-pid")
				try Data().write(to: log)
				let result = try run([script.path, app.path, "Log " + mode, "", "", "tint", "", "0", log.path], root: root,
					environment: ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin", "OWNED_SOURCE": app.path,
						"OWNED_LOG": log.path, "OWNED_LOG_FAULT": mode, "OWNED_TEE_RECEIPT": teeReceipt.path,
						"OWNED_TMP_TEMPLATE": root.appendingPathComponent("workspace.XXXXXX").path])
				let deadline = DispatchTime.now() + Self.retirementDeadline
				var teePID: pid_t?
				var teeRetired = false
				while DispatchTime.now() < deadline {
					if teePID == nil, FileManager.default.fileExists(atPath: teeReceipt.path) {
						do {
							let text = try String(contentsOf: teeReceipt, encoding: .utf8)
							guard let pid = pid_t(text), pid > 1, String(pid) == text else { throw CocoaError(.fileReadCorruptFile) }
							teePID = pid
						} catch {
							fixtureCanRetire = false
							throw error
						}
					}
					if let pid = teePID, Darwin.kill(pid, 0) == -1 {
						if errno == ESRCH { teeRetired = true; break }
						fixtureCanRetire = false
						throw CocoaError(.executableRuntimeMismatch)
					}
					usleep(10_000)
				}
				guard teeRetired else {
					fixtureCanRetire = false
					XCTFail("The exact clone log tee did not retire; retain its fixture")
					throw CocoaError(.executableRuntimeMismatch)
				}
				XCTAssertEqual(result.status, mode == "failure" ? 1 : 0)
				XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Applications").path), [])
				XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("workspace.") })
				let diagnostic = try String(contentsOf: log, encoding: .utf8)
				XCTAssertEqual(result.output.contains("owned-tee-stream\n"), mode == "healthy", "The actual tee must forward the owned output stream")
				XCTAssertEqual(result.output.contains("permission denied: " + log.path), mode == "failure")
				XCTAssertEqual(diagnostic.contains("SRC_EXE=" + app.appendingPathComponent("Contents/MacOS/Source").path), mode == "healthy")
				try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
			}
		}
	}

	func testActualNativeCliLogLimitsRetireOwnedResourcesAndPreserveRawPaths() throws {
		try fixture { root in
			let probe = Self.repositoryURL.appendingPathComponent("tools/test/lib/app-cloner-log-cleanup-probe.py")
			fixtureCanRetire = false
			let result = try run(["-c", #"exec /usr/bin/env python3 "$1" --resources "$2" --shell /bin/zsh --fixture "$3" --palette "$4""#,
				"native-cli-log-cleanup", probe.path, Self.resourcesURL.path, root.appendingPathComponent("physical-cases").path, Self.repositoryURL.appendingPathComponent("static/ergopti_plus/_shared/data/native_theme.toml").path], root: root)
			let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
			fixtureCanRetire = report["ownership_closed"] as? Bool == true
			XCTAssertTrue(fixtureCanRetire, "Retain the exact native CLI fixture if any child retirement is unknown")
			XCTAssertEqual(result.status, 0, "The actual native CLI probe failed: \(result.output); \(result.stderr)")
			XCTAssertEqual(report["state"] as? String, "PASSED")
			XCTAssertEqual(report["source_kind"] as? String, "actual-cli-source-with-explicit-prefix-scopes")
			XCTAssertEqual(report["shell"] as? String, "/bin/zsh")
			let signalStatus = 128 + Int(SIGXFSZ)
			let expected = ["clone:healthy": 0, "clone:finite": signalStatus, "clone:foreign": signalStatus,
				"clone:refusal": signalStatus, "clone:deadpipe": signalStatus, "clone:deadpipe-foreign": signalStatus,
				"clone:deadpipe-refusal": signalStatus, "clone:child-default": signalStatus,
				"clone:backslash-c": 0, "clone:backslash-t": 0, "clone:result-backslash-c": 0, "clone:result-backslash-t": 0, "shortcut:healthy": 0,
				"shortcut:finite": signalStatus, "shortcut:result-backslash-c": 0, "shortcut:result-backslash-t": 0,
				"clone:result-closed-fd": 1, "clone:result-closed-pipe": 128 + Int(SIGPIPE),
				"shortcut:result-closed-fd": 1, "shortcut:result-closed-pipe": 128 + Int(SIGPIPE),
				"owner:refusal-zero": 1, "owner:refusal-primary": 74]
			let cases = try XCTUnwrap(report["cases"] as? [[String: Any]])
			let keys = cases.compactMap { row -> String? in
				guard let caller = row["caller"] as? String, let mode = row["mode"] as? String else { return nil }
				return caller + ":" + mode
			}
			XCTAssertEqual(cases.count, expected.count)
			XCTAssertEqual(keys.count, cases.count)
			XCTAssertEqual(Set(keys), Set(expected.keys), "Every native case must execute exactly once")
			XCTAssertEqual(Set(keys).count, cases.count)
			for row in cases {
				let caller = try XCTUnwrap(row["caller"] as? String)
				let mode = try XCTUnwrap(row["mode"] as? String)
				let raw = try XCTUnwrap(row["status"] as? Int)
				let normalized = raw < 0 ? 128 - raw : raw
				XCTAssertEqual(normalized, try XCTUnwrap(expected[caller + ":" + mode]))
				XCTAssertEqual(row["normalized_status"] as? Int, normalized)
				XCTAssertEqual(row["ownership_closed"] as? Bool, true)
				XCTAssertEqual(row["workspace_created"] as? Bool, true)
				XCTAssertEqual(row["workspace_exists"] as? Bool, caller == "owner")
				let foreign = mode.hasSuffix("foreign")
				let refusal = mode.hasSuffix("refusal") || caller == "owner" || mode.hasPrefix("result-")
				XCTAssertEqual(row["destination_exists"] as? Bool, foreign || refusal)
				if foreign { XCTAssertEqual(row["foreign_marker"] as? String, "foreign") }
				XCTAssertEqual(row["child_survived"] as? Bool, false)
				if mode.hasPrefix("result-closed-") {
					XCTAssertEqual(row["termination_kind"] as? String, "exit", "Only the final writer may receive SIGPIPE; its shell must retire its workspace")
					XCTAssertEqual(row["result_path_exact"] as? Bool, false)
					XCTAssertEqual(row["execution_scope"] as? String, caller == "clone" ? "actual-clone-prefix-and-success-tail" : "actual-full-shortcut-generator")
				}
				if mode.hasPrefix("result-backslash-") {
					let destination = try XCTUnwrap(row["result_path"] as? String)
					XCTAssertTrue(destination.contains(mode.hasSuffix("-c") ? "home\\c" : "home\\t"))
					XCTAssertEqual(row["result_path_exact"] as? Bool, true)
					XCTAssertEqual(row["output"] as? String, destination + "\n")
					XCTAssertEqual(row["execution_scope"] as? String, caller == "clone" ? "actual-clone-prefix-and-success-tail" : "actual-full-shortcut-generator")
				}
				if caller == "clone" {
					let app = try XCTUnwrap(row["source_app"] as? String)
					let name = mode == "backslash-c" ? "Source\\c.app" : (mode == "backslash-t" ? "Source\\t.app" : "Source.app")
					XCTAssertEqual(URL(fileURLWithPath: app).lastPathComponent, name)
					let expectedHex = Data(("=== SOURCE=" + app).utf8).map { String(format: "%02x", $0) }.joined()
					XCTAssertEqual(row["source_line_hex"] as? String, expectedHex)
					if let limit = row["limit"] as? Int {
						XCTAssertGreaterThan(limit, 0)
						XCTAssertEqual(row["actual_log_bytes"] as? Int, limit)
						XCTAssertEqual(limit, try XCTUnwrap(row["healthy_prefix_bytes"] as? Int) + 1)
					}
				}
			}
		}
	}

	func testActualShortcutRollsBackFailuresAndStillRunsWithoutPythonCommands() throws {
		try fixture { root in
			let paletteURL = Self.resourcesURL.appendingPathComponent("../../../../../_shared/data/native_theme.toml").standardizedFileURL
			let palette = try String(contentsOf: paletteURL, encoding: .utf8)
			let expression = try NSRegularExpression(pattern: #"(?m)^hex = "(#[0-9a-fA-F]{6})"$"#)
			let match = try XCTUnwrap(expression.firstMatch(in: palette, range: NSRange(palette.startIndex..<palette.endIndex, in: palette)),
				"The canonical native palette must supply the fixture color")
			let colorRange = try XCTUnwrap(Range(match.range(at: 1), in: palette))
			let fixtureColor = String(palette[colorRange])
			let home = root.appendingPathComponent("home")
			let bin = root.appendingPathComponent("bin")
			try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
			try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
			for name in ["python", "python3"] {
				try writeExecutable(bin.appendingPathComponent(name), "#!/bin/sh\necho unexpected-Python-invocation >&2\nexit 127\n")
			}
			try writeExecutable(bin.appendingPathComponent("mktemp"), "#!/bin/sh\nexec /usr/bin/mktemp -d \"$OWNED_TMP_TEMPLATE\"\n")
			try writeExecutable(bin.appendingPathComponent("qlmanage"), #"""
			#!/bin/sh
			set -eu
			out=''
			while [ "$#" -gt 0 ]; do if [ "$1" = '-o' ]; then shift; out="$1"; fi; shift; done
			mkdir -p "$out"; printf png > "$out/preview.png"
			"""#)
			for tool in ["sips", "iconutil"] {
				try writeExecutable(bin.appendingPathComponent(tool), #"""
				#!/bin/sh
				set -eu
				out=''
				while [ "$#" -gt 0 ]; do if [ "$1" = '-o' ] || [ "$1" = '--out' ]; then shift; out="$1"; fi; shift; done
				mkdir -p "$(dirname "$out")"; printf icon > "$out"
				"""#)
			}
			for mode in ["allocation", "write", "healthy"] {
				let faults = root.appendingPathComponent(mode)
				try FileManager.default.createDirectory(at: faults, withIntermediateDirectories: false)
				if mode == "allocation" { try writeExecutable(faults.appendingPathComponent("mktemp"), "#!/bin/sh\necho owned-allocation-failure >&2\nexit 73\n") }
				if mode == "write" { try writeExecutable(faults.appendingPathComponent("cat"), "#!/bin/sh\necho owned-write-failure >&2\nexit 79\n") }
				let result = try run([Self.resourcesURL.appendingPathComponent("make_shortcut.sh").path, "Standalone", "target",
					"/Applications/Unused.app", fixtureColor, "S"], root: root,
					environment: ["HOME": home.path, "PATH": faults.path + ":" + bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin",
						"OWNED_TMP_TEMPLATE": root.appendingPathComponent("workspace.XXXXXX").path])
				let bundles = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Desktop").path)
				XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("workspace.") })
				if mode == "healthy" {
					XCTAssertEqual(result.status, 0, result.stderr)
					XCTAssertEqual(bundles, ["Standalone.app"])
					XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Desktop/Standalone.app/Contents/Info.plist").path))
					XCTAssertTrue(result.stderr.isEmpty)
				} else {
					XCTAssertEqual(result.status, mode == "allocation" ? 73 : 79)
					XCTAssertTrue(result.stderr.contains(mode == "allocation" ? "owned-allocation-failure" : "owned-write-failure"))
					XCTAssertTrue(bundles.isEmpty)
				}
			}
		}
	}

	func testActualNativeReservationUsesKernelErrnoDuringOwnerRetirement() throws {
		try fixture { root in
			XCTAssertNotEqual(geteuid(), 0, "Physical EACCES evidence requires the actual non-root runner")
			guard geteuid() != 0 else { throw CocoaError(.executableRuntimeMismatch) }
			let helper = Self.resourcesURL.appendingPathComponent("reserve_bundle.sh")
			let raceRoot = root.appendingPathComponent("race")
			try FileManager.default.createDirectory(at: raceRoot, withIntermediateDirectories: false)
			let probe = Self.repositoryURL.appendingPathComponent("tools/test/lib/app-cloner-reservation-race.sh")
			let race = try run([probe.path, helper.path, raceRoot.path], root: root)
			XCTAssertEqual(race.status, 0, "The actual native Perl must retain the kernel EEXIST: \(race.stderr)")
			XCTAssertEqual(race.output, raceRoot.appendingPathComponent("Contended_1.app").path + "\0")
			XCTAssertTrue(race.stderr.isEmpty)
			XCTAssertTrue(FileManager.default.fileExists(atPath: raceRoot.appendingPathComponent("Contended_1.app").path))
			XCTAssertFalse(FileManager.default.fileExists(atPath: raceRoot.appendingPathComponent("Contended.app").path))

			let reserve = #"""
			set -euo pipefail
			umask 077
			source "$1"
			reserve_bundle_directory "$2"
			"""#
			let occupied = root.appendingPathComponent("Occupied.app")
			try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
			let stable = try run(["-c", reserve, "reservation", helper.path, occupied.path], root: root)
			let suffixed = root.appendingPathComponent("Occupied_1.app")
			XCTAssertEqual(stable.status, 0, stable.stderr)
			XCTAssertEqual(stable.output, suffixed.path + "\n")
			let attributes = try FileManager.default.attributesOfItem(atPath: suffixed.path)
			let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
			XCTAssertEqual(mode.intValue & 0o777, 0o700, "Native mkdir must preserve the caller's umask")

			let literal = root.appendingPathComponent("Équipe ' \"$HOME `not-executed`\\\nName.app")
			let data = try run(["-c", reserve, "reservation", helper.path, literal.path], root: root)
			XCTAssertEqual(data.status, 0, data.stderr)
			XCTAssertEqual(Array(data.output.utf8), Array((literal.path + "\n").utf8), "Quotes, backslashes and newlines remain exact path data")
			XCTAssertTrue(FileManager.default.fileExists(atPath: literal.path))

			let missing = root.appendingPathComponent("missing-parent/Refused.app")
			let absent = try run(["-c", reserve, "reservation", helper.path, missing.path], root: root)
			XCTAssertEqual(absent.status, 1)
			XCTAssertTrue(absent.output.isEmpty)
			XCTAssertTrue(absent.stderr.contains("errno=\(ENOENT)"), absent.stderr)
			XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))

			let denied = root.appendingPathComponent("denied-parent")
			try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o555])
			defer {
				do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
				catch {
					fixtureCanRetire = false
					XCTFail("The exact permission-refusal fixture did not regain owned cleanup access")
				}
			}
			let permission = try run(["-c", reserve, "reservation", helper.path, denied.appendingPathComponent("Refused.app").path], root: root)
			XCTAssertEqual(permission.status, 1)
			XCTAssertTrue(permission.output.isEmpty)
			XCTAssertTrue(permission.stderr.contains("errno=\(EACCES)"), permission.stderr)
			XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: denied.path).isEmpty)
		}
	}

	func testActualZshDispatchesTheTeamsURIsAcceptedByTheActualUIHandler() throws {
		try fixture { root in
			let probe = Self.repositoryURL.appendingPathComponent("tools/test/lib/app-cloner-url-routing-probe.py")
			let source = Self.resourcesURL.appendingPathComponent("clone_app.sh")
			let wizard = Self.resourcesURL.appendingPathComponent("ShortcutBuilder.applescript")
			let result = try run(["-c", #"exec /usr/bin/env python3 "$1" "$2" "$3" /bin/zsh "$3" "$4""#,
				"native-url-routing", probe.path, source.path, root.path, wizard.path], root: root)
			XCTAssertEqual(result.status, 0, result.stderr)
			XCTAssertTrue(result.stderr.isEmpty)
			let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
			let validation = try XCTUnwrap(receipt["ui_validation"] as? [String: String])
			XCTAssertEqual(validation, ["teams-chat": "", "teams-calendar": ""], "The actual AppleScript handler admits both single-slash forms")
			let cases = try XCTUnwrap(receipt["cases"] as? [[String: Any]])
			XCTAssertEqual(cases.count, 36)
			XCTAssertEqual(Set(cases.compactMap { row -> String? in
				guard let family = row["family"] as? String, let name = row["name"] as? String else { return nil }
				return family + ":" + name
			}).count, 36, "Every native app-family case must execute exactly once")
			let expectedInputs = [
				"empty": "", "folder": "/fixture/project", "colon-file": "/fixture/report:2026.txt",
				"tilde-file": "~/Documents", "https": "https://example.invalid/path?q=1", "http": "http://example.invalid/",
				"teams-double": "msteams://l/chat/0", "teams-chat": "msteams:/l/chat/0", "teams-calendar": "msteams:/calendar",
				"opaque": "mailto:fixture@example.invalid", "custom": "A+B.C-1:opaque", "non-scheme": "1invalid:filename"
			]
			let expectedFamilies: Set<String> = ["native", "electron", "vscode"]
			let expectedCases = Set(expectedFamilies.flatMap { family in expectedInputs.keys.map { family + ":" + $0 } })
			var actualCases = Set<String>()
			for entry in cases {
				let family = try XCTUnwrap(entry["family"] as? String)
				let name = try XCTUnwrap(entry["name"] as? String)
				let input = try XCTUnwrap(entry["input"] as? String)
				XCTAssertTrue(expectedFamilies.contains(family))
				let expectedInput = try XCTUnwrap(expectedInputs[name], "Every native input must belong to the exact fixture census")
				XCTAssertEqual(input, expectedInput)
				actualCases.insert(family + ":" + name)
			}
			XCTAssertEqual(actualCases, expectedCases, "Native routing must execute the exact twelve inputs in all three app families")
			let uriNames: Set<String> = ["https", "http", "teams-double", "teams-chat", "teams-calendar", "opaque", "custom"]
			for entry in cases {
				let name = try XCTUnwrap(entry["name"] as? String)
				let family = try XCTUnwrap(entry["family"] as? String)
				let input = try XCTUnwrap(entry["input"] as? String)
				let owned = try XCTUnwrap(entry["owned_shell"] as? String)
				XCTAssertEqual(entry["status"] as? Int, 0, "Actual zsh routing must complete for \(family):\(name)")
				XCTAssertEqual(entry["stdout"] as? String, "")
				XCTAssertEqual(entry["stderr"] as? String, "")
				let executions = try XCTUnwrap(entry["executions"] as? [[String]])
				let opens = try XCTUnwrap(entry["opens"] as? [[String]])
				let sleeps = try XCTUnwrap(entry["sleeps"] as? [[String]])
				XCTAssertEqual(executions.count, 1)
				guard executions.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
				XCTAssertGreaterThanOrEqual(executions[0].count, 2)
				let architecture = try XCTUnwrap(executions[0].first)
				let executable = try XCTUnwrap(executions[0].dropFirst().first)
				XCTAssertTrue(["-arm64", "-x86_64"].contains(architecture))
				XCTAssertEqual(executable, "fixture-executable")
				var arguments: [String]
				switch family {
				case "native": arguments = []
				case "electron": arguments = ["--user-data-dir", owned + "/profile"]
				case "vscode": arguments = ["--user-data-dir", owned + "/profile", "--extensions-dir", owned + "/extensions", "--new-window"]
				default: throw CocoaError(.fileReadCorruptFile)
				}
				if uriNames.contains(name) {
					XCTAssertEqual(opens, [["-a", "fixture-application", input]])
					XCTAssertEqual(sleeps, [["1"]])
				} else {
					if !input.isEmpty { arguments.append(input) }
					XCTAssertTrue(opens.isEmpty)
					XCTAssertTrue(sleeps.isEmpty)
				}
				XCTAssertEqual(Array(executions[0].dropFirst(2)), arguments)
			}
		}
	}

	func testActualNativeUUIDsKeepSameSecondBundlesAndCloneConsumersDistinct() throws {
		try fixture { root in
			let probe = Self.repositoryURL.appendingPathComponent("tools/test/lib/app-cloner-identity-probe.py")
			let palette = Self.repositoryURL.appendingPathComponent("static/ergopti_plus/_shared/data/native_theme.toml")
			fixtureCanRetire = false
			let result = try run(["-c", #"exec /usr/bin/env python3 "$1" --resources "$2" --shell /bin/zsh --fixture "$3" --palette "$4""#,
				"native-bundle-identity", probe.path, Self.resourcesURL.path,
				root.appendingPathComponent("identity").path, palette.path], root: root)
			let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
			let owned = receipt["ownership_closed"] as? Bool == true
			fixtureCanRetire = owned
			XCTAssertTrue(owned, "Unknown native identity custody retains the exact fixture")
			guard owned else { throw CocoaError(.executableRuntimeMismatch) }
			XCTAssertEqual(result.status, 0, result.output + result.stderr)
			XCTAssertTrue(result.stderr.isEmpty)
			XCTAssertEqual(receipt["state"] as? String, "PASSED")
			XCTAssertEqual(receipt["native_uuidgen"] as? String, "/usr/bin/uuidgen")
			XCTAssertEqual(receipt["native_clone_scope"] as? String, "actual-zsh-profile-and-writers")
			XCTAssertEqual(receipt["failures"] as? [String], [])
			let pattern = #"\Afr\.b519hs\.(clone|shortcut)\.[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z"#
			let positive = try XCTUnwrap(receipt["positive"] as? [[String: Any]])
			XCTAssertEqual(positive.count, 2)
			XCTAssertEqual(Set(positive.compactMap { $0["caller"] as? String }), Set(["clone", "shortcut"]))
			for row in positive {
				let caller = try XCTUnwrap(row["caller"] as? String)
				XCTAssertEqual(row["distinct_destinations"] as? Bool, true)
				XCTAssertEqual(row["distinct_identifiers"] as? Bool, true)
				XCTAssertEqual(row["distinct_profiles"] as? Bool, true)
				let creations = try XCTUnwrap(row["creations"] as? [[String: Any]])
				XCTAssertEqual(creations.count, 2)
				let identifiers = try creations.map { try XCTUnwrap($0["identifier"] as? String) }
				XCTAssertEqual(Set(identifiers).count, 2)
				for creation in creations {
					let identifier = try XCTUnwrap(creation["identifier"] as? String)
					XCTAssertNotNil(identifier.range(of: pattern, options: .regularExpression))
					XCTAssertTrue(identifier.hasPrefix("fr.b519hs." + caller + "."))
					XCTAssertEqual(creation["uuid_calls"] as? Int, 1)
					XCTAssertEqual(creation["workspace_retired"] as? Bool, true)
					if caller == "clone" { XCTAssertEqual(creation["launcher_identifier"] as? String, identifier) }
				}
				if caller == "clone" {
					XCTAssertEqual(Set(creations.compactMap { $0["profile"] as? String }).count, 2)
					XCTAssertEqual(row["execution_scope"] as? String, "actual-zsh-clone-family/profile-prefix-and-actual-Info.plist/launcher-writers")
				} else { XCTAssertEqual(row["execution_scope"] as? String, "actual-full-shortcut-generator") }
			}
			let kinds = try XCTUnwrap(receipt["helper_generations"] as? [String: [String]])
			XCTAssertEqual(Set(kinds.keys), Set(["clone", "shortcut"]))
			for (kind, identifiers) in kinds {
				XCTAssertEqual(identifiers.count, 2)
				XCTAssertEqual(Set(identifiers).count, 2)
				for identifier in identifiers {
					XCTAssertNotNil(identifier.range(of: pattern, options: .regularExpression))
					XCTAssertTrue(identifier.hasPrefix("fr.b519hs." + kind + "."))
				}
			}
			let admission = try XCTUnwrap(receipt["admission"] as? [[String: Any]])
			XCTAssertEqual(admission.count, 3)
			XCTAssertEqual(try admission.map { try XCTUnwrap($0["arguments"] as? [String]) }, [[], ["unknown"], ["clone", "extra"]])
			for entry in admission {
				XCTAssertEqual(entry["status"] as? Int, 1)
				XCTAssertEqual(entry["uuid_calls"] as? Int, 0)
			}
			let modes = ["nonzero", "valid-nonzero", "empty", "malformed", "missing-newline", "extra-newline", "multiple-records", "nul"]
			let expected = Set(["clone", "shortcut"].flatMap { caller in modes.map { caller + ":" + $0 } })
			let faults = try XCTUnwrap(receipt["faults"] as? [[String: Any]])
			let actual = try faults.map { try XCTUnwrap($0["caller"] as? String) + ":" + XCTUnwrap($0["mode"] as? String) }
			XCTAssertEqual(faults.count, expected.count)
			XCTAssertEqual(Set(actual), expected)
			for fault in faults {
				let mode = try XCTUnwrap(fault["mode"] as? String)
				XCTAssertEqual(fault["status"] as? Int, ["nonzero", "valid-nonzero"].contains(mode) ? 73 : 1)
				XCTAssertEqual(fault["uuid_calls"] as? Int, 1)
				XCTAssertEqual(fault["bundle_parent_created"] as? Bool, false)
				XCTAssertEqual(fault["workspace_created"] as? Bool, false)
				XCTAssertEqual(fault["owned_group_retired"] as? Bool, true)
			}
		}
	}
}
