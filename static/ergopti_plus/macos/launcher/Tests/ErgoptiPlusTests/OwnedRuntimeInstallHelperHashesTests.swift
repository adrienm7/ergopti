// Tests/ErgoptiPlusTests/OwnedRuntimeInstallHelperHashesTests.swift
// The published installer helper carries one SHA-256 code directory per slice; the install must admit it.
import CryptoKit
import Foundation
import Security
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeInstallHelperHashesTests: XCTestCase {
	private func fields(_ hashes: [Data]) -> [String: Any] { [kSecCodeInfoCdHashes as String: hashes] }

	func testTheSingleSha256DirectoryOfThePublishedHelperIsAdmitted() {
		// remap-runtime-v16.3.0-ergopti.3: one CodeDirectory (SHA-256) per slice; two were demanded and every install refused
		let sha256 = Data(repeating: 0xab, count: 32)
		XCTAssertEqual(OwnedRuntimeInstallMainOperation.codeDirectoryHashes(fields([sha256])), [sha256])
	}

	func testBothHashTypesStayAdmitted() {
		let pair = [Data(repeating: 1, count: 20), Data(repeating: 2, count: 32)]
		XCTAssertEqual(OwnedRuntimeInstallMainOperation.codeDirectoryHashes(fields(pair)), pair)
	}

	func testEverySliceOfAUniversalBinaryGivesItsTwentyByteCdhash() throws {
		// codesign --all-architectures checks each slice: the requirement must name a cdhash for every one
		let slices = try XCTUnwrap(OwnedRuntimeInstallMainOperation.sliceCodeHashes(URL(fileURLWithPath: "/usr/bin/true")))
		XCTAssertFalse(slices.isEmpty)
		XCTAssertTrue(slices.allSatisfy { $0.count == 20 }, "the requirement language reads the truncated hash")
		XCTAssertEqual(Set(slices).count, slices.count)
	}

	func testTheStagedRequirementNamesEachSliceAndTheLeaf() {
		let leaf = Data("leaf".utf8)
		let requirement = OwnedRuntimeInstallMainOperation.stagedRequirement(
			leaf: leaf, slices: [Data(repeating: 0xbb, count: 20), Data(repeating: 0xaa, count: 20)])
		XCTAssertEqual(requirement, "identifier \"" + Identifiers.SigningIds.runtimeInstaller + "\" and certificate leaf = H\""
			+ Insecure.SHA1.hash(data: leaf).map { String(format: "%02x", $0) }.joined() + "\" and (cdhash H\""
			+ String(repeating: "aa", count: 20) + "\" or cdhash H\"" + String(repeating: "bb", count: 20) + "\")")
	}

	func testAbsentDuplicatedOversizedOrMalformedHashesAreRefused() {
		let hash = Data(repeating: 3, count: 32)
		XCTAssertNil(OwnedRuntimeInstallMainOperation.codeDirectoryHashes([:]))
		XCTAssertNil(OwnedRuntimeInstallMainOperation.codeDirectoryHashes(fields([])))
		XCTAssertNil(OwnedRuntimeInstallMainOperation.codeDirectoryHashes(fields([hash, hash])))
		XCTAssertNil(OwnedRuntimeInstallMainOperation.codeDirectoryHashes(fields([hash, Data(count: 20), Data(count: 48)])))
		XCTAssertNil(OwnedRuntimeInstallMainOperation.codeDirectoryHashes(fields([Data(count: 16)])))
	}
}
