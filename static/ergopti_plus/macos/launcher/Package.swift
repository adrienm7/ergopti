// swift-tools-version:5.9
// static/ergopti_plus/macos/launcher/Package.swift
//
// MODULE: ErgoptiPlus launcher Swift package
// DESCRIPTION:
// Builds the tiny native binary that lives at ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus.
// Its interactive role hosts Sparkle and spawns embedded Hammerspoon with our
// config-dir override. The same signed executable also provides exact headless
// lease, revocation, guardian, status, and explicit settings roles that guard
// only ErgoptiPlus Karabiner generation variables.
// Hammerspoon itself stays untouched as a vendored .app inside Contents/Frameworks.
//
// FEATURES & RATIONALE:
// 1. Single executable authority: GUI launch and headless lease roles cannot
//    drift between separately installed or unsigned helper artifacts.
// 2. Sparkle via SPM: the official channel; pins one reviewed release so a
//    clean checkout cannot resolve a different updater implementation.
// 3. ErgoptiPlusTests: covers bundle validation, exact child environment, and
//    adversarial lease loss/process-isolation behavior.

import Foundation
import CoreFoundation
import PackageDescription

let launcherTestTargetPath = "Tests/ErgoptiPlusTests"

// Default builds retain every test. Only the canonical, expiring prerelease
// policy can defer this one complete native Brew qualification file.
func deferredDevReleaseTestFiles() -> [String] {
	let environment = ProcessInfo.processInfo.environment
	guard let selected = environment["ERGOPTI_DEV_QUALIFICATION_PROFILE"], !selected.isEmpty else {
		return []
	}
	var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
	for _ in 0..<4 { repository.deleteLastPathComponent() }
	let policyURL = repository.appendingPathComponent(".github/ci/dev_release_qualification_exceptions.json")
	guard let data = try? Data(contentsOf: policyURL),
		let policy = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
		let schema = policy["schema"] as? NSNumber,
		CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
		let profile = policy["id"] as? String, profile == selected,
		let expiryText = policy["expires_at"] as? String,
		let expiry = ISO8601DateFormatter().date(from: expiryText), Date() < expiry,
		let release = policy["release"] as? NSNumber,
		CFGetTypeID(release) == CFBooleanGetTypeID(), release.boolValue,
		environment["GITHUB_ACTIONS"] == "true",
		environment["ERGOPTI_DEV_RELEASE_RELEASE"] == "true"
	else { fatalError("Temporary native qualification profile was not admitted.") }
	for (variable, field) in [
		("GITHUB_REPOSITORY", "repository"), ("GITHUB_EVENT_NAME", "event_name"),
		("GITHUB_REF", "ref"), ("ERGOPTI_DEV_RELEASE_PRERELEASE", "prerelease"),
		("ERGOPTI_DEV_RELEASE_CHANNEL", "channel"), ("ERGOPTI_DEV_RELEASE_TAG", "tag"),
		("ERGOPTI_DEV_RELEASE_VERSION", "version")
	] {
		guard let expected = policy[field] as? String, environment[variable] == expected else {
			fatalError("Temporary native qualification context was not admitted.")
		}
	}
	guard let scopes = policy["scopes"] as? [String: Any],
		let brew = scopes["macos-brew-archive"] as? [String: Any],
		brew["kind"] as? String == "swift_test_file",
		let path = brew["path"] as? String, let name = brew["name"] as? String,
		!path.hasPrefix("/"), !path.contains("\\"),
		path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
			!$0.isEmpty && $0 != "." && $0 != ".."
		}),
		let testSource = try? String(
			contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
				.appendingPathComponent(path), encoding: .utf8),
		testSource.components(separatedBy: "func " + name + "() throws").count == 2,
		testSource.components(separatedBy: "\n\tfunc test").count == 2
	else { fatalError("Temporary native Brew test-file scope was not admitted.") }
	let targetPrefix = launcherTestTargetPath + "/"
	guard path.hasPrefix(targetPrefix) else {
		fatalError("Temporary native Brew scope is outside the test target.")
	}
	let exclusion = String(path.dropFirst(targetPrefix.count))
	guard !exclusion.isEmpty, !exclusion.contains("/") else {
		fatalError("Temporary native Brew exclusion must be one target-relative file.")
	}
	return [exclusion]
}

let package = Package(
	name: "ErgoptiPlus",
	platforms: [
		.macOS(.v11) // Sparkle 2.x baseline; matches Hammerspoon’s own floor.
	],
	products: [
		.executable(name: "ErgoptiPlus", targets: ["ErgoptiPlus"])
	],
	dependencies: [
		.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")
	],
	targets: [
		.target(
			name: "CPOSIXCompatibility",
			path: "Sources/CPOSIXCompatibility",
			publicHeadersPath: "include"
		),
		.executableTarget(
			name: "ErgoptiPlus",
			dependencies: [
				"CPOSIXCompatibility",
				.product(name: "Sparkle", package: "Sparkle")
			],
			path: "Sources/ErgoptiPlus",
			swiftSettings: [
				.define("ERGOPTI_GUARDIAN_TEST_SUPPORT", .when(configuration: .debug))
			],
			linkerSettings: [
				.linkedFramework("Security"),
				// dyld resolves @rpath by walking each entry in LC_RPATH; without
				// this entry the loader cannot find Sparkle.framework at runtime
				// because SPM does not inject this path automatically for dynamic
				// frameworks that land in Contents/Frameworks/ (not next to the binary).
				.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
			]
		),
		.testTarget(
			name: "ErgoptiPlusTests",
			dependencies: ["ErgoptiPlus"],
			path: launcherTestTargetPath,
			exclude: deferredDevReleaseTestFiles(),
			swiftSettings: [
				.define("ERGOPTI_GUARDIAN_TEST_SUPPORT", .when(configuration: .debug))
			]
		)
	]
)
