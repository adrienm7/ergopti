// Tests/ErgoptiPlusTests/ReleaseRenameWorkerTests.swift
//
// Exercise actual Darwin exclusive renames without a Finder or app launch.

import Darwin
import Foundation
import Sparkle
import XCTest
@testable import ErgoptiPlus

final class ReleaseRenameWorkerTests: XCTestCase {
	private static let childDeadline: DispatchTimeInterval = .seconds(5)
	private static let maximumDiagnosticBytes = 4096
	private var fixtureCanRetire = true

	private final class LeaseChild {
		let process: Process
		let completed: DispatchSemaphore
		let input: Pipe
		let output: Pipe
		let errors: FileHandle
		private var inputClosed = false
		private(set) var inputCustodyKnown = true

		init(process: Process, completed: DispatchSemaphore, input: Pipe, output: Pipe, errors: FileHandle) {
			self.process = process; self.completed = completed
			self.input = input; self.output = output; self.errors = errors
		}

		func closeInput() throws {
			guard !inputClosed else { return }
			inputClosed = true
			do { try input.fileHandleForWriting.close() }
			catch { inputCustodyKnown = false; throw error }
		}
	}

	private func fixture(_ body: (URL) throws -> Void) throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseRename-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact release rename fixture did not retire: \(error)") }
			}
		}
		try body(root)
	}

	private func directory(_ url: URL, marker: String) throws {
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
		try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
	}

	func testExclusiveRenamePreservesTheExactDirectoryAndRawPathBytes() throws {
		try fixture { root in
			let source = root.appendingPathComponent("source ' \\t\n.app")
			let destination = root.appendingPathComponent("target ' \\c\n.app")
			try directory(source, marker: "original")
			var before = stat(), after = stat()
			XCTAssertEqual(lstat(source.path, &before), 0)
			XCTAssertEqual(ReleaseRenameWorker.move(source: source.path, destination: destination.path), 0)
			XCTAssertEqual(lstat(destination.path, &after), 0)
			XCTAssertEqual(before.st_dev, after.st_dev)
			XCTAssertEqual(before.st_ino, after.st_ino)
			XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
			XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("marker")), "original")
		}
	}

	func testExistingDirectoryFileAndSymlinkDestinationsRemainUntouched() throws {
		try fixture { root in
			for kind in ["directory", "file", "symlink"] {
				let source = root.appendingPathComponent("source-" + kind)
				let destination = root.appendingPathComponent("target-" + kind)
				try directory(source, marker: "original")
				if kind == "directory" { try directory(destination, marker: "foreign") }
				else if kind == "file" { try Data("foreign".utf8).write(to: destination) }
				else { try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "missing") }
				var before = stat(), after = stat()
				XCTAssertEqual(lstat(destination.path, &before), 0)
				XCTAssertEqual(ReleaseRenameWorker.move(source: source.path, destination: destination.path), 3)
				XCTAssertEqual(lstat(destination.path, &after), 0)
				XCTAssertEqual(before.st_dev, after.st_dev)
				XCTAssertEqual(before.st_ino, after.st_ino)
				XCTAssertEqual(before.st_mode, after.st_mode)
				XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("marker")), "original")
				XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(source.lastPathComponent).path))
			}
		}
	}

	func testSourceSymlinksAndRegularFilesNeverPublish() throws {
		try fixture { root in
			let actual = root.appendingPathComponent("actual")
			try directory(actual, marker: "original")
			let link = root.appendingPathComponent("link")
			try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
			let file = root.appendingPathComponent("file")
			try Data("original".utf8).write(to: file)
			for source in [link, file] {
				let destination = root.appendingPathComponent("destination")
				XCTAssertEqual(ReleaseRenameWorker.move(source: source.path, destination: destination.path), 2)
				XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
			}
			XCTAssertEqual(try String(contentsOf: actual.appendingPathComponent("marker")), "original")
		}
	}

	func testUnknownArgumentsAndInvalidNativePathsFailBeforeMutation() {
		for arguments in [[], ["launcher"], ["launcher", kReleaseRenameFlag],
			["launcher", kReleaseRenameFlag, "probe", "extra"],
			["launcher", kReleaseRenameFlag, "unknown"],
			["launcher", kReleaseRenameFlag, "move", "relative", "/absolute"]] {
			XCTAssertEqual(ReleaseRenameWorker.run(arguments: arguments), 1)
		}
		for source in ["relative", "/", "/path/", "/path/.", "/path/..", "/path\0suffix"] {
			XCTAssertEqual(ReleaseRenameWorker.move(source: source, destination: "/unused-destination"), 1)
		}
	}

	private func nativeExecutable() throws -> URL {
		let directory = Bundle(for: ReleaseRenameWorkerTests.self).bundleURL.deletingLastPathComponent()
		for candidate in [directory.appendingPathComponent("ErgoptiPlus"),
			directory.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")] {
			if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
		}
		XCTFail("The exact SwiftPM-built release lease launcher is unavailable")
		throw CocoaError(.executableNotLoadable)
	}

	private func shellQuote(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}

	private func startLease(script: String, root: URL, children: inout [LeaseChild]) throws -> LeaseChild {
		let executable = try nativeExecutable()
		let errorURL = root.appendingPathComponent(UUID().uuidString + ".stderr")
		guard FileManager.default.createFile(atPath: errorURL.path, contents: nil,
			attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
		let errors = try FileHandle(forWritingTo: errorURL)
		let input = Pipe(), output = Pipe()
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		let app = root.appendingPathComponent("app ' \\t.app").path
		process.arguments = ["-c", "exec 3>&1; exec \"$@\"", "lease", executable.path,
			kReleaseRenameFlag, "lock", app, script, String(getpid()),
			root.appendingPathComponent("staged.app").path, app + ".previous"]
		process.environment = NativeFixtureChildEnvironment.make()
		process.standardInput = input
		process.standardOutput = output
		process.standardError = errors
		let completed = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in completed.signal() }
		let child = LeaseChild(process: process, completed: completed, input: input, output: output, errors: errors)
		children.append(child)
		try process.run()
		return child
	}

	/// Poll the owned pipe before every byte: a missing readiness line fails within the child budget.
	private func ready(_ child: LeaseChild, line: String = "READY\n") throws {
		let deadline = DispatchTime.now() + Self.childDeadline
		for expected in Array(line.utf8) {
			var observation = pollfd(fd: child.output.fileHandleForReading.fileDescriptor,
				events: Int16(POLLIN), revents: 0)
			var status: Int32 = 0
			repeat {
				let now = DispatchTime.now().uptimeNanoseconds
				guard now < deadline.uptimeNanoseconds else {
					XCTFail("The owned native release lease did not reach readiness before its deadline")
					throw CocoaError(.executableRuntimeMismatch)
				}
				let milliseconds = (deadline.uptimeNanoseconds - now + 999_999) / 1_000_000
				status = poll(&observation, 1, Int32(milliseconds))
			} while status < 0 && errno == EINTR
			var byte: UInt8 = 0
			guard status > 0, observation.revents & Int16(POLLIN) != 0,
				Darwin.read(observation.fd, &byte, 1) == 1, byte == expected else {
				XCTFail("The owned native release lease did not publish its exact readiness line")
				throw CocoaError(.executableRuntimeMismatch)
			}
		}
	}

	private func finish(_ child: LeaseChild, status: Int32,
		reason: Process.TerminationReason = .exit) throws {
		try child.closeInput()
		guard child.completed.wait(timeout: .now() + Self.childDeadline) == .success else {
			fixtureCanRetire = false
			if child.process.isRunning { child.process.terminate() }
			_ = child.completed.wait(timeout: .now() + Self.childDeadline)
			throw CocoaError(.executableRuntimeMismatch)
		}
		XCTAssertEqual(child.process.terminationReason, reason)
		XCTAssertEqual(child.process.terminationStatus, status)
	}

	private func retire(_ children: [LeaseChild]) {
		for child in children {
			if child.process.isRunning {
				// EOF releases the fixture's synchronous shell reader before any signal.
				do { try child.closeInput() }
				catch { fixtureCanRetire = false; XCTFail("The owned release lease input did not close") }
				if child.completed.wait(timeout: .now() + Self.childDeadline) != .success {
					fixtureCanRetire = false
					child.process.terminate()
					_ = child.completed.wait(timeout: .now() + Self.childDeadline)
				}
			}
			do { try child.closeInput() }
			catch { fixtureCanRetire = false; XCTFail("The owned release lease input did not retire") }
			if !child.inputCustodyKnown { fixtureCanRetire = false }
			// Process owns the child-facing pipe ends; retire only our parent-facing handles.
			for handle in [child.output.fileHandleForReading, child.errors] {
				do { try handle.close() }
				catch { fixtureCanRetire = false; XCTFail("The owned release lease handle did not retire") }
			}
		}
	}

	func testNativeLeaseSurvivesArmingPipeClosureAndReleasesOnFailureOrDeath() throws {
		try fixture { root in
			var children: [LeaseChild] = []
			defer { retire(children) }
			let probe = shellQuote(try nativeExecutable().path) + " " + shellQuote(kReleaseRenameFlag) + " probe"
			// The role's synchronous native child inherits custody, then the shell blocks on our input.
			let script = "printf 'ARMED\\n' >&3; exec 3>&-; " + probe + " >/dev/null || exit 9; "
				+ "/bin/sh -c 'printf \"READY\\n\"; IFS= read -r done'; exit 7"
			let holder = try startLease(script: script, root: root, children: &children)
			try ready(holder, line: "ARMED\n")
			try ready(holder)
			let busy = try startLease(script: "printf 'UNEXPECTED\\n'; exit 0", root: root, children: &children)
			try finish(busy, status: 4)
			let descriptor = busy.output.fileHandleForReading.fileDescriptor
			let flags = fcntl(descriptor, F_GETFL)
			guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
				XCTFail("The exact owned release lease output could not become nonblocking")
				throw CocoaError(.executableRuntimeMismatch)
			}
			var byte: UInt8 = 0
			let deadline = DispatchTime.now() + Self.childDeadline
			var count = 0
			var readError: Int32 = 0
			repeat {
				count = Darwin.read(descriptor, &byte, 1)
				readError = errno
			} while count < 0 && readError == EINTR && DispatchTime.now() < deadline
			XCTAssertTrue(count == 0 || (count < 0 && (readError == EAGAIN || readError == EWOULDBLOCK)),
				"A refused lease cannot write script or ARMED output; read=\(count), errno=\(readError)")
			try holder.input.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
			try finish(holder, status: 7)
			let afterFailure = try startLease(script: "exit 0", root: root, children: &children)
			try finish(afterFailure, status: 0)
			// This holder uses shell builtins only, so killing it cannot orphan a descendant.
			let killed = try startLease(script: "exec 3>&-; printf 'READY\\n'; IFS= read -r done",
				root: root, children: &children)
			try ready(killed)
			XCTAssertEqual(Darwin.kill(killed.process.processIdentifier, SIGKILL), 0)
			try finish(killed, status: SIGKILL, reason: .uncaughtSignal)
			let afterDeath = try startLease(script: "exit 0", root: root, children: &children)
			try finish(afterDeath, status: 0)
			let app = root.appendingPathComponent("app ' \\t.app").path
			var held = stat()
			XCTAssertEqual(lstat(app + ".release-lock", &held), 0)
			XCTAssertEqual(held.st_size, 0)
			XCTAssertEqual(held.st_nlink, 1)
			XCTAssertEqual(held.st_mode & 0o7777, 0o600)
		}
	}

	private func closeRoleHandle(_ handle: FileHandle) {
		do { try handle.close() }
		catch { fixtureCanRetire = false; XCTFail("The owned relocated release role handle did not retire") }
	}

	/// File-backed output keeps native startup failure bounded without waiting for pipe EOF.
	private func runRole(_ executable: URL, arguments: [String], root: URL) throws -> (Int32, Data, String) {
		let outputURL = root.appendingPathComponent(UUID().uuidString + ".stdout")
		let errorURL = root.appendingPathComponent(UUID().uuidString + ".stderr")
		for path in [outputURL, errorURL] {
			guard FileManager.default.createFile(atPath: path.path, contents: nil,
				attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
		}
		let output = try FileHandle(forWritingTo: outputURL)
		defer { closeRoleHandle(output) }
		let errors = try FileHandle(forWritingTo: errorURL)
		defer { closeRoleHandle(errors) }
		let process = Process()
		process.executableURL = executable
		process.arguments = [kReleaseRenameFlag] + arguments
		process.environment = NativeFixtureChildEnvironment.make()
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = errors
		let completed = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in completed.signal() }
		try process.run()
		guard completed.wait(timeout: .now() + Self.childDeadline) == .success else {
			fixtureCanRetire = false
			if process.isRunning { process.terminate() }
			_ = completed.wait(timeout: .now() + Self.childDeadline)
			throw CocoaError(.executableRuntimeMismatch)
		}
		let diagnostics = try FileHandle(forReadingFrom: errorURL)
		defer { closeRoleHandle(diagnostics) }
		let diagnosticBytes = try diagnostics.read(upToCount: Self.maximumDiagnosticBytes + 1) ?? Data()
		let diagnosticText = String(decoding: diagnosticBytes.prefix(Self.maximumDiagnosticBytes), as: UTF8.self)
			+ (diagnosticBytes.count > Self.maximumDiagnosticBytes ? " [truncated]" : "")
		XCTAssertEqual(process.terminationReason, .exit, diagnosticText)
		let input = try FileHandle(forReadingFrom: outputURL)
		defer { closeRoleHandle(input) }
		// No successful command emits more than its single exact probe receipt.
		let maximumOutput = kReleaseRenameFlag.utf8.count + 1
		let bytes = try input.read(upToCount: maximumOutput + 1) ?? Data()
		guard bytes.count <= maximumOutput else { throw CocoaError(.fileReadCorruptFile) }
		return (process.terminationStatus, bytes, diagnosticText)
	}

	func testCopiedNativeLauncherAndSparkleKeepWorkingAcrossTheirOwnBundleMoves() throws {
		try fixture { root in
			let manager = FileManager.default
			let app = root.appendingPathComponent("Original ' \\t.app")
			let contents = app.appendingPathComponent("Contents")
			let executable = contents.appendingPathComponent("MacOS/ErgoptiPlus")
			try manager.createDirectory(at: executable.deletingLastPathComponent(),
				withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
			try manager.copyItem(at: try nativeExecutable(), to: executable)
			let frameworks = contents.appendingPathComponent("Frameworks")
			try manager.createDirectory(at: frameworks, withIntermediateDirectories: false)
			try manager.copyItem(at: Bundle(for: SPUUpdater.self).bundleURL,
				to: frameworks.appendingPathComponent("Sparkle.framework"))
			try PropertyListSerialization.data(fromPropertyList: [
				"CFBundleIdentifier": "org.ergoptiplus.release-rename." + UUID().uuidString,
				"CFBundleExecutable": "ErgoptiPlus", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
			], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
			try Data("original".utf8).write(to: app.appendingPathComponent("marker"))
			let previous = URL(fileURLWithPath: app.path + ".previous")
			let retainedExecutable = previous.appendingPathComponent("Contents/MacOS/ErgoptiPlus")
			var original = stat(), retained = stat(), restored = stat()
			XCTAssertEqual(lstat(executable.path, &original), 0)
			XCTAssertEqual(original.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
			XCTAssertGreaterThan(original.st_size, 0)
			let moved = try runRole(executable, arguments: ["move", app.path, previous.path], root: root)
			XCTAssertEqual(moved.0, 0, "The active Mach-O must move its own app and framework together: " + moved.2)
			XCTAssertTrue(moved.1.isEmpty)
			XCTAssertFalse(manager.fileExists(atPath: app.path))
			XCTAssertEqual(lstat(retainedExecutable.path, &retained), 0)
			XCTAssertEqual(retained.st_dev, original.st_dev)
			XCTAssertEqual(retained.st_ino, original.st_ino)
			let probe = try runRole(retainedExecutable, arguments: ["probe"], root: root)
			XCTAssertEqual(probe.0, 0)
			XCTAssertEqual(probe.1, Data((kReleaseRenameFlag + "\n").utf8))
			let staged = root.appendingPathComponent("Older.app")
			let olderExecutable = staged.appendingPathComponent("Contents/MacOS/ErgoptiPlus")
			try manager.createDirectory(at: olderExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data("#!/bin/sh\nexit 99\n".utf8).write(to: olderExecutable)
			try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: olderExecutable.path)
			try Data("chosen".utf8).write(to: staged.appendingPathComponent("marker"))
			let published = try runRole(retainedExecutable, arguments: ["move", staged.path, app.path], root: root)
			XCTAssertEqual(published.0, 0, "Publishing an older candidate must use the retained current launcher: " + published.2)
			XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("marker")), "chosen")
			let occupied = try runRole(retainedExecutable, arguments: ["move", previous.path, app.path], root: root)
			XCTAssertEqual(occupied.0, 3)
			XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("marker")), "chosen")
			XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("marker")), "original")
			// Retire only the exact older fixture we created, then exercise a real rollback.
			try manager.removeItem(at: app)
			let rollback = try runRole(retainedExecutable, arguments: ["move", previous.path, app.path], root: root)
			XCTAssertEqual(rollback.0, 0, "The retained Mach-O must also move itself back during rollback: " + rollback.2)
			XCTAssertEqual(lstat(executable.path, &restored), 0)
			XCTAssertEqual(restored.st_dev, original.st_dev)
			XCTAssertEqual(restored.st_ino, original.st_ino)
			XCTAssertFalse(manager.fileExists(atPath: previous.path))
			let restoredProbe = try runRole(executable, arguments: ["probe"], root: root)
			XCTAssertEqual(restoredProbe.0, 0)
			XCTAssertEqual(restoredProbe.1, Data((kReleaseRenameFlag + "\n").utf8))
		}
	}
}
