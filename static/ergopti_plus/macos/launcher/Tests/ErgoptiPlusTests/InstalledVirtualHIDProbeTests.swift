// Tests/ErgoptiPlusTests/InstalledVirtualHIDProbeTests.swift
// Native fixed-artifact expectations frozen before the production probe.
import CryptoKit
import Darwin
import Foundation
import Security
import XCTest
@testable import ErgoptiPlus

final class InstalledVirtualHIDProbeTests: XCTestCase {
	private func fixture(_ name: String) throws -> InstalledVHDProbeLocations {
		let environment = ProcessInfo.processInfo.environment
		try XCTSkipUnless(environment["CI"] == "true", "Disposable native fixture only")
		guard let root = environment["ERGOPTI_TEST_VHD_ROOT"] else { throw XCTSkip("Native fixed official artifact fixture is unprovisioned") }
		try XCTSkipUnless(root.hasPrefix("/Library/ErgoptiPlusNativeFixture-"), "Root-protected fixture ancestry required")
		let base = URL(fileURLWithPath: root).appendingPathComponent(name)
		try XCTSkipUnless(FileManager.default.fileExists(atPath: base.path), "Native case fixture missing: \(name)")
		return InstalledVHDProbeLocations(daemon: base.appendingPathComponent("daemon.app"), dext: base.appendingPathComponent("driver.dext"))
	}
	private func observed(_ name: String) throws -> InstalledVHDProbeReceipt {
		InstalledVirtualHIDProbe.observeTestFixture(locations: try fixture(name))
	}
	private func component(_ receipt: InstalledVHDProbeReceipt, _ role: String) throws -> InstalledVHDComponentObservation {
		try XCTUnwrap(receipt.components.first { $0.role == role })
	}
	private func assertDenied(_ receipt: InstalledVHDProbeReceipt, file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertFalse(receipt.referenceQualified, file: file, line: line)
		XCTAssertNotEqual(receipt.status, "observed", file: file, line: line)
		XCTAssertNotNil(receipt.reason, file: file, line: line)
	}
	func testActualOfficialDaemonBothArchitecturesUseFrozenHashes() throws {
		let r = try observed("official")
		let d = try component(r, "daemon")
		XCTAssertEqual(d.status, "observed"); XCTAssertEqual(d.ordinaryRootOwned, true)
		XCTAssertEqual(d.signatureValid, true); XCTAssertEqual(d.bundleIdentityValid, true); XCTAssertEqual(d.matchesFixedBytes, true)
		XCTAssertEqual(d.architectures.map(\.architecture), ["x86_64", "arm64"])
		XCTAssertEqual(d.architectures.map(\.cdhash), ["3736778029bc84c96bf1af782f81b86bb164bb3f", "c10ecd105806ecfc53c3c71b9b49affbe7a369f2"])
		XCTAssertEqual(d.architectures.map(\.securityStatus), [0, 0])
		XCTAssertFalse(r.referenceQualified, "Actual package trust remains a separate native prerequisite")
	}
	func testActualOfficialDEXTIsStaticReferenceNotApprovedDriver() throws {
		let r = try observed("official"), d = try component(r, "dext")
		XCTAssertEqual(d.status, "observed"); XCTAssertEqual(d.signatureValid, true)
		XCTAssertEqual(d.matchesFixedBytes, true); XCTAssertEqual(d.bundleIdentityValid, true)
		XCTAssertEqual(d.architectures.map(\.architecture), ["x86_64", "arm64"])
		XCTAssertTrue(d.architectures.allSatisfy { $0.securityStatus == 0 && $0.cdhash?.count == 40 })
		XCTAssertFalse(r.referenceQualified)
		let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
		for key in ["extension_approved", "active_extension", "broker", "client", "ready", "history"] { XCTAssertFalse(json.contains("\"" + key + "\"")) }
	}
	func testUnsupportedNewerOfficialFilesRemainUnverified() throws { assertDenied(try observed("newer-reference")) }
	func testEachMissingBundleOrExecutableRemainsMissing() throws {
		for name in ["missing-daemon", "missing-dext", "missing-executable"] {
			let r = try observed(name); assertDenied(r); XCTAssertTrue(r.components.contains { $0.status == "missing" })
		}
	}
	func testSameSignerOtherBuildCannotMatchFixedBytes() throws { assertDenied(try observed("same-signer-other-build")) }
	func testUnsignedAndAdHocCannotBecomeReference() throws {
		for name in ["unsigned", "adhoc"] { assertDenied(try observed(name)) }
	}
	func testBadOtherUniversalSliceIsNotHiddenByHostSlice() throws { assertDenied(try observed("bad-other-slice")) }
	func testChangedSealedPlistAndResourceAreRefused() throws {
		for name in ["changed-plist", "changed-resource"] { assertDenied(try observed(name)) }
	}
	func testActualSymlinkAliasesCannotReplaceOrdinaryReference() throws {
		for name in ["symlink-ancestor", "symlink-plist", "symlink-executable"] { assertDenied(try observed(name)) }
	}
	func testNonregularReferencesRefuseWithoutBlocking() throws {
		for name in ["fifo-executable", "directory-executable"] { assertDenied(try observed(name)) }
	}
	func testUserOwnedWritableFilesAndACLNeverBecomeRootProtected() throws {
		for name in ["user-owned", "writable-file", "nonempty-acl"] {
			let r = try observed(name); assertDenied(r)
			XCTAssertNotEqual(try component(r, "daemon").ordinaryRootOwned, true)
		}
	}
	func test0775AncestorReportsOnlyPartialStaticObservations() throws {
		let r = try observed("writable-ancestor"), d = try component(r, "daemon")
		assertDenied(r); XCTAssertEqual(d.status, "unverified"); XCTAssertEqual(d.reason, "writable_ancestor")
		XCTAssertEqual(d.ordinaryRootOwned, false); XCTAssertEqual(d.matchesFixedBytes, true); XCTAssertEqual(d.signatureValid, true)
	}
	func testBeforePublicationThrowCannotBecomeSuccessfulObservation() throws {
		enum Refusal: Error { case actualBoundary }
		let r = InstalledVirtualHIDProbe.observeTestFixture(locations: try fixture("official"),
			hooks: InstalledVHDProbeTestHooks(boundary: { _ in throw Refusal.actualBoundary }))
		assertDenied(r); XCTAssertEqual(r.status, "refused")
	}
	func testActualReplacementAndSameInodeMutationAfterPinRefuse() throws {
		try XCTSkipUnless(geteuid() == 0, "Actual mutation requires externally provisioned root XCTest; no elevation in test")
		for mutation in ["replace", "same-inode", "chmod"] {
			let locations = try fixture("mutation-" + mutation)
			var changed = false
			let binary = locations.daemon.appendingPathComponent("Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon")
			let r = InstalledVirtualHIDProbe.observeTestFixture(locations: locations, hooks: InstalledVHDProbeTestHooks(boundary: { b in
				guard b.role == "daemon", b.stage == "afterFilesPinned", !changed else { return }
				changed = true
				if mutation == "chmod" { XCTAssertEqual(chmod(binary.path, 0o666), 0) }
				else if mutation == "replace" {
					let replacement = binary.appendingPathExtension("replacement")
					try Data("changed image".utf8).write(to: replacement)
					XCTAssertEqual(rename(replacement.path, binary.path), 0)
				} else {
					let file = try FileHandle(forWritingTo: binary)
					try file.seek(toOffset: 0); try file.write(contentsOf: Data([0])); try file.close()
				}
			}))
			XCTAssertTrue(changed); assertDenied(r); XCTAssertEqual(r.status, "changed")
		}
	}
	func testEncodedObservationMutationCannotChangeNativeValue() throws {
		let r = try observed("official")
		var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
		value["reference_qualified"] = true; value["ready"] = true
		XCTAssertFalse(r.referenceQualified)
		let again = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
		XCTAssertEqual(again["reference_qualified"] as? Bool, false); XCTAssertNil(again["ready"])
	}
}

import XCTest
import Darwin
import Foundation
@testable import ErgoptiPlus

final class IndependentInstalledVHDControls: XCTestCase {
    private let role = "--installed-virtual-hid-probe"
    private let expectedCommit = "bdfcb459b2eaca8ccda680a73b0dc898f330f4bb"

    private func json(_ receipt: InstalledVHDProbeReceipt) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))
        return try XCTUnwrap(value as? [String: Any])
    }

    private func assertStaticScope(_ value: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(value["schema"] as? Int, 1, file: file, line: line)
        XCTAssertEqual(value["source_commit"] as? String, expectedCommit, file: file, line: line)
        XCTAssertEqual(value["reference_qualified"] as? Bool, false, file: file, line: line)
        let statuses: Set<String> = ["observed", "missing", "unverified", "changed", "refused"]
        XCTAssertTrue(statuses.contains(try XCTUnwrap(value["status"] as? String)), file: file, line: line)
        let components = try XCTUnwrap(value["components"] as? [[String: Any]])
        XCTAssertEqual(components.compactMap { $0["role"] as? String }, ["daemon", "dext"], file: file, line: line)
        let prohibited: Set<String> = ["broker", "client", "intent", "ready", "extension_approved", "history", "allowed", "active_extension"]
        func inspect(_ object: Any) {
            if let dictionary = object as? [String: Any] {
                XCTAssertTrue(prohibited.isDisjoint(with: Set(dictionary.keys)), file: file, line: line)
                for child in dictionary.values { inspect(child) }
            } else if let list = object as? [Any] {
                for child in list { inspect(child) }
            }
        }
        inspect(value)
    }

    func testRolePrefixRoutesMalformedArgumentsToRefusal() {
        XCTAssertTrue(InstalledVirtualHIDProbeWorker.handles(arguments: ["fixture", role]))
        XCTAssertTrue(InstalledVirtualHIDProbeWorker.handles(arguments: ["fixture", role, "--reference-verified=true"]))
        XCTAssertFalse(InstalledVirtualHIDProbeWorker.handles(arguments: []))
        XCTAssertFalse(InstalledVirtualHIDProbeWorker.handles(arguments: ["fixture"]))
        XCTAssertFalse(InstalledVirtualHIDProbeWorker.handles(arguments: ["fixture", "--other", role]))
    }

    func testInvalidArgumentsAcquireNeitherFilesNorOutput() {
        let cases: [[String]] = [[], ["fixture"], ["fixture", "--other"],
            ["fixture", role, "--reference-verified=true"],
            ["fixture", role, "/tmp/other-reference"],
            ["fixture", role, "--cdhash", "3736778029bc84c96bf1af782f81b86bb164bb3f"],
            ["fixture", role, "--team-id", "caller-selected"],
            ["fixture", role, "--ready"], ["fixture", role, role]]
        for arguments in cases {
            var probes = 0
            var writes = 0
            let status = InstalledVirtualHIDProbeWorker.run(arguments: arguments, probe: {
                probes += 1
                return InstalledVirtualHIDProbe.observe()
            }, writeOutput: { _ in
                writes += 1
                return true
            })
            XCTAssertEqual(status, 64)
            XCTAssertEqual(probes, 0)
            XCTAssertEqual(writes, 0)
        }
    }

    func testActualPartialObservationCannotBecomeReferenceOrLiveAuthority() throws {
        let value = try json(InstalledVirtualHIDProbe.observe())
        try assertStaticScope(value)
    }

    func testFailedWriterPreservesActualClosedStaticReceiptAndReturns74() throws {
        var probes = 0
        var writes = 0
        var published: Data?
        let status = InstalledVirtualHIDProbeWorker.run(arguments: ["fixture", role], probe: {
            probes += 1
            return InstalledVirtualHIDProbe.observe()
        }, writeOutput: { data in
            writes += 1
            published = data
            return false
        })
        XCTAssertEqual(status, 74)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(writes, 1)
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(published))
        try assertStaticScope(XCTUnwrap(object as? [String: Any]))
    }

    func testAcquiredEmptyNativeACLIsExplicitlyEmpty() throws {
        let acl = try XCTUnwrap(acl_init(0))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(acl_valid(acl), 0)
        var entry: acl_entry_t?
        errno = 0
        let raw = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        let actualError = errno
        XCTAssertEqual(raw, -1)
        XCTAssertEqual(actualError, EINVAL)
        XCTAssertTrue(try InstalledVHDProbeNative.aclIsEmpty(acl))
    }

    func testNativeZeroReturnMeansAnEntryExistsAndMustRefuse() throws {
        var acl: acl_t? = try XCTUnwrap(acl_init(1))
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
        let owned = try XCTUnwrap(acl)
        XCTAssertEqual(acl_valid(owned), 0)
        var retrieved: acl_entry_t?
        XCTAssertEqual(acl_get_entry(owned, Int32(ACL_FIRST_ENTRY.rawValue), &retrieved), 0)
        XCTAssertNotNil(retrieved)
        XCTAssertFalse(try InstalledVHDProbeNative.aclIsEmpty(owned))
    }
}

import XCTest
import Foundation
@testable import ErgoptiPlus

final class IndependentInstalledVHDMalformedComponentControl: XCTestCase {
    func testWorkerRefusesEachUnknownComponentStatusBeforeWriting() {
        for invalid in ["ready", "", "OBSERVED", "observed "] {
            for role in ["daemon", "dext"] {
                let components = [
                    InstalledVHDComponentObservation(role: "daemon", status: role == "daemon" ? invalid : "unverified"),
                    InstalledVHDComponentObservation(role: "dext", status: role == "dext" ? invalid : "unverified")
                ]
                let receipt = InstalledVHDProbeReceipt(status: "unverified", components: components, reason: "missing_path")
                var probes = 0
                var writes = 0
                let status = InstalledVirtualHIDProbeWorker.run(arguments: ["fixture", "--installed-virtual-hid-probe"], probe: {
                    probes += 1
                    return receipt
                }, writeOutput: { _ in
                    writes += 1
                    return true
                })
                XCTAssertEqual(status, 70)
                XCTAssertEqual(probes, 1)
                XCTAssertEqual(writes, 0)
            }
        }
    }
}
