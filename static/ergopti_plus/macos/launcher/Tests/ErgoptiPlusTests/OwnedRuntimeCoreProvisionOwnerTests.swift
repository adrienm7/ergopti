// Native fixed-plist custody controls. Disposable filesystem fixtures never grant administrator/service authority.
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus
final class OwnedRuntimeCoreProvisionOwnerTests: XCTestCase {
	func testOrdinaryTestProcessCannotConstructServiceProvisionAuthority() { XCTAssertNil(OwnedRuntimeCoreProvisionOwner.acquire()) }
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	private func fixture() throws -> URL {
		let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
		return parent
	}
	func testCanonicalPlistNeverStartsOrKeepsServiceAliveAutomatically() throws {
		let fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: OwnedRuntimeCoreProvisionOwner.fixturePlist(), format: nil) as? [String: Any])
		XCTAssertEqual(Set(fields.keys), ["Label", "ProgramArguments", "UserName", "KeepAlive", "RunAtLoad"])
		XCTAssertEqual(fields["Label"] as? String, "com.ergoptiplus.runtime.core")
		XCTAssertEqual(fields["ProgramArguments"] as? [String], ["/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core"])
		XCTAssertEqual(fields["UserName"] as? String, "root")
		XCTAssertEqual(fields["RunAtLoad"] as? Bool, false); XCTAssertEqual(fields["KeepAlive"] as? Bool, false)
	}
	func testExclusiveCreatePreservesForeignPlistAndLedger() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let file = parent.appendingPathComponent("com.ergoptiplus.runtime.core.plist")
		let bytes = Data("foreign-plist".utf8); try bytes.write(to: file)
		XCTAssertFalse(try OwnedRuntimeCoreProvisionOwner.fixtureRollback(parent: parent))
		XCTAssertEqual(try Data(contentsOf: file), bytes)
	}
	func testUnpublishedCreatedPlistAndLedgerRetireExactly() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let foreign = parent.appendingPathComponent("unrelated.plist"); try Data([42]).write(to: foreign)
		XCTAssertTrue(try OwnedRuntimeCoreProvisionOwner.fixtureRollback(parent: parent))
		XCTAssertEqual(try Data(contentsOf: foreign), Data([42]))
		XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("com.ergoptiplus.runtime.core.plist").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".runtime-service-journal").path))
	}
	func testReplacedCreatedPlistSurvivesRefusedRollback() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let file = parent.appendingPathComponent("com.ergoptiplus.runtime.core.plist")
		var replacementEntered = false
		XCTAssertFalse(try OwnedRuntimeCoreProvisionOwner.fixtureRollback(parent: parent, afterPin: {
			try FileManager.default.removeItem(at: file); try Data("replacement".utf8).write(to: file); replacementEntered = true
		}))
		XCTAssertTrue(replacementEntered); XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
		XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".runtime-service-journal").path))
	}
	func testSymlinkPlistDoesNotModifyItsTarget() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let target = parent.appendingPathComponent("personal"); try Data([7]).write(to: target)
		try FileManager.default.createSymbolicLink(atPath: parent.appendingPathComponent("com.ergoptiplus.runtime.core.plist").path, withDestinationPath: target.path)
		XCTAssertFalse(try OwnedRuntimeCoreProvisionOwner.fixtureRollback(parent: parent))
		XCTAssertEqual(try Data(contentsOf: target), Data([7]))
	}
	func testRestartRetirementRequiresOriginalRecordedVnodeAndBytes() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		XCTAssertTrue(try OwnedRuntimeCoreProvisionOwner.fixtureRestartRollback(parent: parent))
		XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("com.ergoptiplus.runtime.core.plist").path))
	}
	func testModifiedRecordedPlistIsNotRemovedAfterRestart() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let file = parent.appendingPathComponent("com.ergoptiplus.runtime.core.plist")
		var mutationEntered = false
		XCTAssertFalse(try OwnedRuntimeCoreProvisionOwner.fixtureRestartRollback(parent: parent, afterPin: {
			try Data("changed".utf8).write(to: file); mutationEntered = true
		}))
		XCTAssertTrue(mutationEntered); XCTAssertEqual(try Data(contentsOf: file), Data("changed".utf8))
	}
	func testMalformedLedgerIsRetainedAndNeverStartsOrCleansPlist() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let file = parent.appendingPathComponent(".runtime-service-journal"); let bytes = Data("CORE_PLIST|1|owned|1|2|extra".utf8); try bytes.write(to: file)
		XCTAssertFalse(try OwnedRuntimeCoreProvisionOwner.fixtureRollback(parent: parent)); XCTAssertEqual(try Data(contentsOf: file), bytes)
	}
	func testExistingOwnedSystemConfigurationRefusesFirstStart() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		XCTAssertTrue(try OwnedRuntimeCoreProvisionOwner.fixtureConfigurationAbsent(parent: parent))
		try Data("{}".utf8).write(to: parent.appendingPathComponent("core.json"))
		XCTAssertFalse(try OwnedRuntimeCoreProvisionOwner.fixtureConfigurationAbsent(parent: parent))
	}
	func testServiceDebtBlocksImageLeasesWhileRecoveryNamespaceRemainsObservable() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let held = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true, create: true)
		defer { _ = held.retire() }
		XCTAssertTrue(held.permitsInstalledImages()); XCTAssertTrue(held.permitsServiceProvision())
		let journal = parent.appendingPathComponent(".runtime-service-journal"); try Data().write(to: journal)
		XCTAssertFalse(held.permitsInstalledImages()); XCTAssertTrue(held.permitsServiceProvision())
		try FileManager.default.removeItem(at: journal); XCTAssertTrue(held.permitsInstalledImages())
	}
	func testOwnedDataDirectoryPreparationDoesNotReplaceFilesOrProfiles() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let foreign = parent.appendingPathComponent("RemapRuntime"); let bytes = Data("foreign".utf8); try bytes.write(to: foreign)
		XCTAssertThrowsError(try OwnedRuntimeCoreProvisionOwner.fixturePrepareDirectories(parent: parent))
		XCTAssertEqual(try Data(contentsOf: foreign), bytes)
	}
	func testOwnedDirectoryPreparationCreatesOnlyClosedDataScope() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		try OwnedRuntimeCoreProvisionOwner.fixturePrepareDirectories(parent: parent)
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["RemapRuntime"])
		XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent("RemapRuntime").path)), ["config", "tmp", "log"])
	}
	func testMissingOlderOrBooleanIdleRevisionCannotAuthorizeInstalledPolicy() throws {
		for fields: [String: Any] in [[:], ["ErgoptiOwnedCoreIdleAdmissionRevision": true], ["ErgoptiOwnedCoreIdleAdmissionRevision": 2], ["ErgoptiOwnedCoreIdleAdmissionRevision": 1], ["ErgoptiOwnedCoreIdleAdmissionRevision": "2"]] {
			let bytes = try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
			XCTAssertFalse(OwnedRuntimeCoreProvisionOwner.fixtureIdleRevision(bytes))
		}
	}
	func testExactIdleRevisionIsOnlyMetadataAndCannotConstructRootOwner() throws {
		let bytes = try PropertyListSerialization.data(fromPropertyList: ["ErgoptiOwnedCoreIdleAdmissionRevision": "1"], format: .xml, options: 0)
		XCTAssertTrue(OwnedRuntimeCoreProvisionOwner.fixtureIdleRevision(bytes)); XCTAssertNil(OwnedRuntimeCoreProvisionOwner.acquire())
	}
	func testForeignPlistRefusalCreatesNoTransactionDebt() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let file = parent.appendingPathComponent("com.ergoptiplus.runtime.core.plist")
		let foreign = Data("existing-foreign-plist".utf8); try foreign.write(to: file)
		XCTAssertEqual(try Data(contentsOf: file), foreign)
		XCTAssertFalse(try OwnedRuntimeCoreProvisionOwner.fixtureRollback(parent: parent))
		XCTAssertEqual(try Data(contentsOf: file), foreign)
		XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".runtime-service-journal").path))
	}

	func testServicePlistEarlyRefusalDoesNotRunInitializedSelfRetirement() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let file = parent.appendingPathComponent("empty.plist"); try Data().write(to: file)
		XCTAssertNil(try OwnedRuntimeCoreServiceOwner.fixtureRejectedServicePlistInitialization(file: file))
	}
	func testServicePlistLateProtectionRefusalRetiresInitializedSelfExactlyOnce() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let file = parent.appendingPathComponent("unprotected.plist"); try Data("not-protected".utf8).write(to: file)
		XCTAssertEqual(chmod(file.path, 0o666), 0)
		XCTAssertEqual(try OwnedRuntimeCoreServiceOwner.fixtureRejectedServicePlistInitialization(file: file), true)
		XCTAssertEqual(try Data(contentsOf: file), Data("not-protected".utf8))
	}
	func testCustodyEarlyAdmissionRefusalDoesNotRunInitializedSelfRetirement() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		XCTAssertNil(try OwnedRuntimeCorePlistCustody.fixtureRejectedInitializerRetirement(parent: parent, rejectAt: 1))
		XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".runtime-service-journal").path))
	}
	func testCustodyFirstWriteRefusalRetiresInitializedSelfAndReleasesOriginalFlock() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		XCTAssertEqual(try OwnedRuntimeCorePlistCustody.fixtureRejectedInitializerRetirement(parent: parent, rejectAt: 2), true)
		let journal = parent.appendingPathComponent(".runtime-service-journal")
		let descriptor = open(journal.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
		XCTAssertGreaterThanOrEqual(descriptor, 0); guard descriptor >= 0 else { return }
		defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
		XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
		XCTAssertEqual(try Data(contentsOf: journal), Data())
	}
	func testCustodyExistingMalformedLedgerRefusalRetiresInitializedSelfAndPreservesDebt() throws {
		let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
		let journal = parent.appendingPathComponent(".runtime-service-journal"), bytes = Data("malformed".utf8)
		try bytes.write(to: journal); XCTAssertEqual(chmod(journal.path, 0o600), 0)
		XCTAssertEqual(try OwnedRuntimeCorePlistCustody.fixtureRejectedInitializerRetirement(parent: parent, rejectAt: 0), true)
		XCTAssertEqual(try Data(contentsOf: journal), bytes)
	}
	#endif
}
