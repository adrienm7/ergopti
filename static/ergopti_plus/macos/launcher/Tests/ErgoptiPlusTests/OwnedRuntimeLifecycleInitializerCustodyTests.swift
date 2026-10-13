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
#endif
}
