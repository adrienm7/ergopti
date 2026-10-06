// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274AtomicRegistryCompatibilityTests.swift
// Actual C++23 registry atomics; Darwin watch/publication/dispatch leaves are modeled.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testRegistryAtomicBookkeepingCompilesWithActualCxx23ProductionWarnings() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/test_remap_runtime_atomic_shared_ptr.py")
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", script.path,
					"RegistryAtomicCompatibility.test_actual_registry_with_host_shared_ptr_atomics"], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertTrue(receipt.stdout.isEmpty)
			XCTAssertTrue(receipt.stderr.contains("Ran 1 test in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}
}
