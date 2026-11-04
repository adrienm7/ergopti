// Tests/ErgoptiPlusTests/OwnedRuntimeInstalledPeerOwnerTests.swift
// Native namespace/FD controls grant no production signer, installed peer, child or physical-source readiness.
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeInstalledPeerOwnerTests: XCTestCase {
	func testXCTestCannotAcquireInstalledPeer() { XCTAssertNil(OwnedRuntimeInstalledPeerOwner.acquire()) }
	func testXCTestCannotAcquireProductionLifecycleLocks() {
		XCTAssertNil(OwnedRuntimeServiceLifecycleLock.acquireShared())
		XCTAssertNil(OwnedRuntimeServiceLifecycleLock.acquireExclusive())
	}
	func testOuterPeerCurrentAPIAcceptsNoCallerAuthorityArguments() {
		let _: (OwnedRuntimeInstalledPeerOwner) -> () -> Bool = OwnedRuntimeInstalledPeerOwner.current
	}
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	private func fixture(_ body: (URL) throws -> Void) throws {
		let parent = try OwnedRuntimeFixtureDirectory.create()
		defer { try? FileManager.default.removeItem(at: parent) }
		try body(parent)
	}
	func testPersistentInstallLedgerBlocksImageAdmissionAfterOwnerDeath() throws {
		try fixture { parent in
			let reader = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: false, create: true)
			defer { _ = reader.retire() }
			XCTAssertTrue(reader.permitsInstalledImages())
			let ledger = parent.appendingPathComponent(".runtime-install-journal")
			try Data("durable unfinished transaction".utf8).write(to: ledger)
			XCTAssertTrue(reader.current())
			XCTAssertFalse(reader.permitsInstalledImages())
			try FileManager.default.removeItem(at: ledger)
			XCTAssertTrue(reader.permitsInstalledImages())
			XCTAssertTrue(reader.retire()); XCTAssertFalse(reader.permitsInstalledImages())
		}
	}
	func testActualSharedNamespaceLocksRefuseExclusiveMutation() throws {
		try fixture { parent in
			let first = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: false, create: true)
			let second = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: false)
			XCTAssertThrowsError(try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true))
			XCTAssertTrue(first.retire()); XCTAssertTrue(second.retire())
			let writer = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true)
			XCTAssertTrue(writer.retire())
		}
	}
	func testActualExclusiveNamespaceLockRefusesSecondOwner() throws {
		try fixture { parent in
			let first = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true, create: true)
			XCTAssertThrowsError(try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true))
			XCTAssertThrowsError(try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: false))
			XCTAssertTrue(first.retire())
		}
	}
	func testLifecycleLockRefusesPathReplacementAndPreservesIt() throws {
		try fixture { parent in
			let held = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true, create: true)
			let path = parent.appendingPathComponent(".runtime-service-lifecycle-lock")
			try FileManager.default.moveItem(at: path, to: parent.appendingPathComponent("old-lock"))
			try Data("foreign".utf8).write(to: path)
			XCTAssertFalse(held.current())
			XCTAssertTrue(held.retire())
			XCTAssertEqual(try Data(contentsOf: path), Data("foreign".utf8))
		}
	}
	func testLifecycleLockRejectsSymlink() throws {
		try fixture { parent in
			let foreign = parent.appendingPathComponent("foreign"); try Data().write(to: foreign)
			try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent(".runtime-service-lifecycle-lock"), withDestinationURL: foreign)
			XCTAssertThrowsError(try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: false))
		}
	}
	func testNativeTreeCloseRevokesAllFurtherDescriptorAccess() throws {
		try fixture { parent in
			let tree = try OwnedRuntimeInstallTree(root: parent, protected: false)
			XCTAssertTrue(tree.releaseOwnedDescriptors())
			XCTAssertThrowsError(try tree.verify())
			XCTAssertThrowsError(try tree.verifyAnchor())
			XCTAssertThrowsError(try tree.duplicateRootDescriptor())
			XCTAssertTrue(tree.releaseOwnedDescriptors())
		}
	}
	func testLifecycleLockRejectsWritableOrNonemptyLedger() throws {
		try fixture { parent in
			let held = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true, create: true)
			XCTAssertTrue(held.retire())
			let path = parent.appendingPathComponent(".runtime-service-lifecycle-lock")
			XCTAssertEqual(chmod(path.path, 0o666), 0)
			XCTAssertThrowsError(try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: false))
			XCTAssertEqual(chmod(path.path, 0o644), 0)
			try Data("not-a-lock".utf8).write(to: path)
			XCTAssertThrowsError(try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: false))
		}
	}
	func testSurvivingNativeChildRetainsNamespaceAfterParentClose() throws {
		try fixture { parent in
			let held = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: false, create: true)
			defer { _ = held.retire() }
			var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
			XCTAssertEqual(posix_spawn_file_actions_init(&actions), 0)
			defer { posix_spawn_file_actions_destroy(&actions) }
			XCTAssertEqual(posix_spawnattr_init(&attributes), 0)
			defer { posix_spawnattr_destroy(&attributes) }
			XCTAssertEqual(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)), 0)
			try held.installInheritance(actions: &actions)
			let arguments = ["/bin/sleep", "2"].map { value in value.withCString { strdup($0) } } + [nil]
			let environment = ["PATH=/usr/bin:/bin"].map { value in value.withCString { strdup($0) } } + [nil]
			defer { arguments.compactMap { $0 }.forEach { free($0) }; environment.compactMap { $0 }.forEach { free($0) } }
			var child: pid_t = 0
			let status = arguments.withUnsafeBufferPointer { argv in
				environment.withUnsafeBufferPointer { envp in
					posix_spawn(&child, "/bin/sleep", &actions, &attributes,
						UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
				}
			}
			XCTAssertEqual(status, 0); guard status == 0, child > 0 else { throw OwnedRuntimeInstallFailure.source }
			var reaped = false
			defer { if !reaped { var status: Int32 = 0; while waitpid(child, &status, 0) < 0 && errno == EINTR {} } }
			var childStatus: Int32 = 0
			XCTAssertEqual(waitpid(child, &childStatus, WNOHANG), 0)
			XCTAssertTrue(held.retire())
			XCTAssertThrowsError(try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true))
			var waited: pid_t
			repeat { waited = waitpid(child, &childStatus, 0) } while waited < 0 && errno == EINTR
			XCTAssertEqual(waited, child); reaped = waited == child
			XCTAssertEqual(childStatus, 0)
			let writer = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true)
			XCTAssertTrue(writer.retire())
		}
	}
	func testDuplicatedNativeTreeDescriptorDoesNotSurviveExec() throws {
		try fixture { parent in
			let tree = try OwnedRuntimeInstallTree(root: parent, protected: false)
			let descriptor = try tree.duplicateRootDescriptor(); defer { close(descriptor) }
			let flags = fcntl(descriptor, F_GETFD)
			XCTAssertGreaterThanOrEqual(flags, 0); XCTAssertNotEqual(flags & FD_CLOEXEC, 0)
		}
	}
	#endif
}
