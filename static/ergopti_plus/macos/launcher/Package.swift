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
// 2. Sparkle via SPM: the official channel; locks Sparkle to a known-good
//    minor so a Sparkle 2.x → 3.x bump cannot land silently via tag drift.
// 3. ErgoptiPlusTests: covers bundle validation, exact child environment, and
//    adversarial lease loss/process-isolation behavior.

import PackageDescription

let package = Package(
	name: "ErgoptiPlus",
	platforms: [
		.macOS(.v11) // Sparkle 2.x baseline; matches Hammerspoon’s own floor.
	],
	products: [
		.executable(name: "ErgoptiPlus", targets: ["ErgoptiPlus"])
	],
	dependencies: [
		.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
	],
	targets: [
		.executableTarget(
			name: "ErgoptiPlus",
			dependencies: [
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
			path: "Tests/ErgoptiPlusTests",
			swiftSettings: [
				.define("ERGOPTI_GUARDIAN_TEST_SUPPORT", .when(configuration: .debug))
			]
		)
	]
)
