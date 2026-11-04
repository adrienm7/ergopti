import CPOSIXCompatibility
import Foundation
import XCTest
@testable import ErgoptiPlus
final class OwnedRuntimeConsoleConfigurationTests: XCTestCase {
 func testOrdinaryXCTestCannotAcquireLauncherConfigurationToken() {
  let token = ergopti_owned_configuration_acquire()
  XCTAssertNil(token)
  if let token { _ = ergopti_owned_configuration_release(token); _ = ergopti_owned_configuration_destroy(token) }
 }
 func testMissingConfigurationTokenCannotGrantCurrentnessOrCleanup() {
  XCTAssertEqual(ergopti_owned_configuration_capture(nil), 0)
  XCTAssertEqual(ergopti_owned_configuration_current(nil), 0)
  XCTAssertEqual(ergopti_owned_configuration_namespace_current(nil), 0)
  XCTAssertEqual(ergopti_owned_configuration_release(nil), 0)
  XCTAssertEqual(ergopti_owned_configuration_destroy(nil), 0)
 }
 func testForeignOpaquePointerCannotGrantNativeConfiguration() {
  let foreign = OpaquePointer(bitPattern: 1)
  XCTAssertEqual(ergopti_owned_configuration_capture(foreign), 0)
  XCTAssertEqual(ergopti_owned_configuration_current(foreign), 0)
  XCTAssertEqual(ergopti_owned_configuration_namespace_current(foreign), 0)
  XCTAssertEqual(ergopti_owned_configuration_release(foreign), 0)
  XCTAssertEqual(ergopti_owned_configuration_destroy(foreign), 0)
 }
}
