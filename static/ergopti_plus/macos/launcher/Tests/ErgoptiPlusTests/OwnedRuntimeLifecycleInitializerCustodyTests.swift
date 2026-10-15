// Real temporary native namespace cleanup; no installed publisher/service/capture authority.
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeLifecycleInitializerCustodyTests: XCTestCase {
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
 private func fixture() throws -> URL {
  let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
  return parent
 }
 func testEarlyRefusalDoesNotInvokeInitializedSelfRetirement() throws {
  let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
  XCTAssertNil(try OwnedRuntimeServiceLifecycleLock.fixtureRejectedInitializerRetirement(parent: parent, rejectAt: 1))
 }
 func testLateRefusalRetiresInitializedSelfWithoutDuplicateCloseDebt() throws {
  let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
  XCTAssertEqual(try OwnedRuntimeServiceLifecycleLock.fixtureRejectedInitializerRetirement(parent: parent, rejectAt: 2), true)
 }
 func testLateRefusalReleasesActualNamespaceBeforeSuccessor() throws {
  let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
  XCTAssertEqual(try OwnedRuntimeServiceLifecycleLock.fixtureRejectedInitializerRetirement(parent: parent, rejectAt: 2), true)
  let successor = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true)
  XCTAssertTrue(successor.current()); XCTAssertTrue(successor.retire())
 }
 func testBootstrapStageLateRefusalRetiresInitializedSelfWithoutDuplicateCloseDebt() throws {
  let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
  let stage = parent.appendingPathComponent("stage", isDirectory: true)
  try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
  XCTAssertNil(try OwnedRuntimeBootstrapStageOwner.fixtureRejectedInitializerRetirement(stage: stage.appendingPathComponent("missing")))
  let closed = try XCTUnwrap(OwnedRuntimeBootstrapStageOwner.fixtureRejectedInitializerRetirement(stage: stage))
  XCTAssertEqual(closed, [.init(status: 0, error: 0)], "The initialized parent descriptor must close once; duplicate closure reports EBADF")
  XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), [])
 }
#endif
}
