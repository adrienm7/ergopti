// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/WindowTitlePolicyTests.swift
//
// Executes the actual generator's private Swift outputs with the native compiler.
// Independent expected strings detect interpolation, quoting and removal defects.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class WindowTitlePolicyTests: XCTestCase {
	private struct PolicyCase {
		let prefix: String
		let separator: String
		let expected: String
	}

	private enum ProbeFailure: Error {
		case timedOut(String)
		case failed(String, Int32, String)
	}

	private var fixtureCanRetire = true

	private static var repositoryURL: URL {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { url.deleteLastPathComponent() }
		return url
	}

	/// File-backed capture avoids pipe deadlocks and retains exact child receipts.
	private func runChild(_ executable: String, arguments: [String], root: URL) throws -> String {
		let identity = UUID().uuidString
		let outputURL = root.appendingPathComponent(identity + ".stdout")
		let errorURL = root.appendingPathComponent(identity + ".stderr")
		XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
		XCTAssertTrue(FileManager.default.createFile(atPath: errorURL.path, contents: nil))
		let output = try FileHandle(forWritingTo: outputURL)
		let errors = try FileHandle(forWritingTo: errorURL)
		defer {
			try? output.close()
			try? errors.close()
		}
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
			if process.isRunning { process.terminate() }
			if completed.wait(timeout: .now() + 5) != .success {
				fixtureCanRetire = false
				XCTFail("The exact policy child did not retire; its private fixture remains owned at \(root.path)")
			}
			throw ProbeFailure.timedOut(executable)
		}
		let stdout = try String(contentsOf: outputURL, encoding: .utf8)
		let stderr = try String(contentsOf: errorURL, encoding: .utf8)
		guard process.terminationReason == .exit, process.terminationStatus == 0 else {
			throw ProbeFailure.failed(executable, process.terminationStatus, stdout + stderr)
		}
		XCTAssertTrue(stderr.isEmpty, "A generated native policy must emit no errors: \(stderr)")
		return stdout
	}

	func testPrivateProbeEnvironmentPreservesParentAndExecutableSearchPath() throws {
		let inherited = ProcessInfo.processInfo.environment
		let inheritedPath = try XCTUnwrap(inherited["PATH"], "Native policy generation requires the inherited executable search path")
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiPolicyEnvironment-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The private policy environment fixture did not retire: \(error)") }
			}
		}
		// BSD printenv reads one variable per invocation, unlike GNU printenv.
		XCTAssertEqual(try runChild("/usr/bin/printenv", arguments: ["SWIFT_BACKTRACE"], root: root),
			"enable=no\n", "The actual private child disables unsupported crash backtracing")
		XCTAssertEqual(try runChild("/usr/bin/printenv", arguments: ["PATH"], root: root),
			inheritedPath + "\n", "The actual private child preserves executable lookup")
		XCTAssertEqual(ProcessInfo.processInfo.environment["SWIFT_BACKTRACE"], inherited["SWIFT_BACKTRACE"],
			"Parent XCTest retains its own crash backtrace setting")
	}

	func testPrivateGeneratedPoliciesCompileAndExecuteWithoutInterpolationOrDuplicateBranding() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiWindowTitles-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The private native title fixture did not retire: \(error)") }
			}
		}
		let cases = [
			PolicyCase(prefix: "ErgoptiPlus", separator: " — ", expected: "ErgoptiPlus — Navigation layer"),
			PolicyCase(prefix: "", separator: " — ", expected: "Navigation layer"),
			PolicyCase(prefix: "Other product", separator: ": ", expected: "Other product: Navigation layer"),
			PolicyCase(prefix: "Quoted \"product\" `name`", separator: "", expected: "Quoted \"product\" `name`Navigation layer"),
			PolicyCase(prefix: "Other ; product", separator: " ; ", expected: "Other ; product ; Navigation layer"),
			PolicyCase(prefix: "Literal \\(1 + 1)", separator: " / ", expected: "Literal \\(1 + 1) / Navigation layer"),
			PolicyCase(prefix: "Émoji 😀", separator: " / ", expected: "Émoji 😀 / Navigation layer"),
		]
		let policies = cases.map { ["prefix": $0.prefix, "separator": $0.separator] }
		try JSONSerialization.data(withJSONObject: policies).write(to: root.appendingPathComponent("policies.json"))
		let bootstrap = root.appendingPathComponent("generate.cjs")
		try """
		const fs = require('node:fs');
		const path = require('node:path');
		const generator = require(process.argv[2]);
		const root = process.argv[3];
		const policies = require(path.join(root, 'policies.json'));
		for (const [index, policy] of policies.entries()) {
			const target = path.join(root, String(index));
			const source = path.join(target, generator.SOURCE);
			fs.mkdirSync(path.dirname(source), {recursive:true});
			fs.writeFileSync(source, JSON.stringify({window_title:policy, apps:{}}));
			generator.main(target);
		}
		process.stdout.write(String(policies.length));
		""".write(to: bootstrap, atomically: true, encoding: .utf8)
		let generator = Self.repositoryURL.appendingPathComponent("tools/codegen/codegen-window-titles.cjs")
		XCTAssertEqual(try runChild("/usr/bin/env", arguments: ["node", bootstrap.path, generator.path, root.path], root: root),
			"7", "The real generator must emit every private policy")
		for (index, policy) in cases.enumerated() {
			let fixture = root.appendingPathComponent(String(index))
			let artifact = fixture.appendingPathComponent("static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/WindowTitles.generated.swift")
			XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path), "The generator owns the actual Swift artifact")
			let main = fixture.appendingPathComponent("main.swift")
			try """
			print(WindowTitles.compose(CommandLine.arguments[1]), terminator: "|")
			print(WindowTitles.compose(), terminator: "|")
			print(WindowTitles.compose(""), terminator: "")
			""".write(to: main, atomically: true, encoding: .utf8)
			let binary = fixture.appendingPathComponent("policy")
			XCTAssertEqual(try runChild("/usr/bin/xcrun",
				arguments: ["swiftc", artifact.path, main.path, "-o", binary.path], root: root), "")
			XCTAssertEqual(try runChild(binary.path, arguments: ["Navigation layer"], root: root),
				policy.expected + "|" + policy.prefix + "|" + policy.prefix,
				"The native Swift parser must keep customized title policy \(index) as data")
		}
	}
}
