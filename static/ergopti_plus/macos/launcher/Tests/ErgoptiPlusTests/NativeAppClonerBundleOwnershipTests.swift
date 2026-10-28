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
				receipt) CLONE_COMPLETE=1; exec 1>&-; printf unavailable-output ;;
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
}
