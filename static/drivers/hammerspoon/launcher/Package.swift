// swift-tools-version:5.9
// static/drivers/hammerspoon/launcher/Package.swift
//
// MODULE: Ergopti launcher Swift package
// DESCRIPTION:
// Builds the tiny native binary that lives at Ergopti.app/Contents/MacOS/Ergopti.
// Its only jobs are to host Sparkle (so the in-app updater works) and to spawn
// the embedded Hammerspoon binary with our config-dir override. Hammerspoon
// itself stays untouched as a vendored .app inside Contents/Frameworks.
//
// FEATURES & RATIONALE:
// 1. Single-target executable: keeps the launcher trivially auditable and
//    free of test boilerplate that would never run in production.
// 2. Sparkle via SPM: the official channel; locks Sparkle to a known-good
//    minor so a Sparkle 2.x → 3.x bump cannot land silently via tag drift.

import PackageDescription

let package = Package(
	name: "Ergopti",
	platforms: [
		.macOS(.v11) // Sparkle 2.x baseline; matches Hammerspoon's own floor.
	],
	products: [
		.executable(name: "Ergopti", targets: ["Ergopti"])
	],
	dependencies: [
		.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
	],
	targets: [
		.executableTarget(
			name: "Ergopti",
			dependencies: [
				.product(name: "Sparkle", package: "Sparkle")
			],
			path: "Sources/Ergopti"
		)
	]
)
